#!/usr/bin/env ruby
# frozen_string_literal: true

# tools/protect.rb — обфускация Ruby-логики при сборке .rbz («свой rbe»).
#
# Каждый защищаемый .rb в staging-копии заменяется на стаб: исходник сжимается
# (zlib), шифруется (AES-256-CBC, случайные key+IV при каждой сборке),
# кодируется в Base64, а при загрузке плагина стаб расшифровывает и выполняет
# исходник через eval с настоящим именем файла — поэтому __FILE__, __dir__,
# require_relative и стек-трейсы работают как в незашифрованном коде
# (проверяется test/protect_test.rb).
#
# Оригинальные исходники не изменяются: шифруется только staging-копия,
# которую tools/pack.rb собирает во временном каталоге. Повторное шифрование
# исключено: стаб начинается с маркера и пропускается при повторном проходе.
#
# Это защита «от любопытных»: ключ лежит внутри стаба, от реверс-инженера она
# не спасает. Настоящее шифрование — официальный .rbe через Trimble
# (https://extensions.sketchup.com/extension/sign): ключ хранится в самом
# SketchUp, но требует аккаунта разработчика и ручной подачи каждого релиза.

require 'base64'
require 'openssl'
require 'zlib'

module Dn1supPack
  module Protect
    # Маркер в первой строке стаба: по нему распознаются уже зашифрованные файлы.
    MARKER = '# dn1sup-protected-v1'

    # Файлы, которые остаются открытыми (пути относительно папки плагина).
    # config.rb оставляем читаемым — так проще разбирать жалобы пользователей.
    OPEN_FILES = %w[
      config.rb
    ].freeze

    DECODER = <<~'RUBY'
      # dn1sup-protected-v1 — зашифровано tools/protect.rb при сборке (zlib + AES-256-CBC).
      # Не редактируйте: при каждой сборке файл пересоздаётся из исходников (tools/pack.rb).
      require 'zlib'
      require 'base64'
      require 'openssl'

      module Dn1sup
        module Obf
          unless respond_to?(:unpack)
            def self.unpack(file, key, iv, data)
              cipher = OpenSSL::Cipher.new('aes-256-cbc').decrypt
              cipher.key = Base64.decode64(key)
              cipher.iv  = Base64.decode64(iv)
              blob = cipher.update(Base64.decode64(data)) + cipher.final
              source = Zlib::Inflate.inflate(blob)
              source.force_encoding(Encoding::UTF_8) if source.valid_encoding?
              eval(source, TOPLEVEL_BINDING, file)
            end
          end
        end
      end

      Dn1sup::Obf.unpack(
        __FILE__,
    RUBY

    class << self
      # Шифрует все .rb в папке плагина staging-копии. Корневой лоадер в эту
      # папку не входит (лежит в корне архива), поэтому остаётся открытым.
      # Возвращает количество зашифрованных файлов.
      def protect_plugin!(stage_dir)
        count = 0
        rb_files(stage_dir).each do |path|
          next if open_file?(stage_dir, path)
          next if protected?(path)

          protect_file!(path)
          count += 1
        end
        count
      end

      def protect_file!(path)
        key  = OpenSSL::Random.random_bytes(32)
        iv   = OpenSSL::Random.random_bytes(16)
        data = encode(encrypt(File.binread(path), key, iv))
        File.binwrite(path, stub(encode(key), encode(iv), data))
      end

      def protected?(path)
        File.open(path, 'rb') { |f| f.read(MARKER.bytesize) } == MARKER
      end

      private

      def rb_files(stage_dir)
        Dir.glob(File.join(stage_dir, '**', '*.rb')).sort
      end

      def open_file?(stage_dir, path)
        OPEN_FILES.include?(rel_path(stage_dir, path))
      end

      def rel_path(stage_dir, path)
        prefix = stage_dir.end_with?('/', '\\') ? stage_dir : stage_dir + '/'
        path.delete_prefix(prefix).tr('\\', '/')
      end

      def encrypt(source, key, iv)
        cipher = OpenSSL::Cipher.new('aes-256-cbc').encrypt
        cipher.key = key
        cipher.iv  = iv
        cipher.update(Zlib::Deflate.deflate(source)) + cipher.final
      end

      # strict_encode64 возвращает ASCII-8BIT, а декодер содержит UTF-8
      # комментарии — приводим, чтобы склейка стаба не падала.
      def encode(bytes)
        Base64.strict_encode64(bytes).force_encoding(Encoding::UTF_8)
      end

      def stub(key_b64, iv_b64, data_b64)
        data_lines = data_b64.scan(/.{1,60}/).map { |line| "  #{line}" }.join("\n")
        "#{DECODER}  #{key_b64.inspect},\n  #{iv_b64.inspect},\n" \
          "  <<~'DN1SUP_OBF_DATA'\n#{data_lines}\n  DN1SUP_OBF_DATA\n)\n"
      end
    end
  end
end
