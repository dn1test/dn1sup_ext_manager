# frozen_string_literal: true

$stdout.sync = true

# test/rbz_load_test.rb — офлайн-проверка собранных .rbz: для каждого пакета
# эмулируется окружение SketchUp (лоадер -> активация -> стаб -> eval) и
# проверяется, что расширение регистрируется и его код загружается.
#
#   ruby tools/pack.rb            # сначала собрать пакеты
#   ruby test/rbz_load_test.rb
#
# SketchUp не нужен: UI/Sketchup подменяются мягкими стабами. Стенд проверяет
# механизм доставки кода (обфускацию), а не логику плагинов — она покрыта
# smoke_test.rb и ручной проверкой в SketchUp.

require 'tmpdir'
require 'fileutils'
require 'zip'

require_relative '../tools/protect' # только для маркера (санити-проверка пакетов)

$failed = 0

def assert(label, cond, details = '')
  passed = !!cond
  puts(format('%s %s%s', passed ? 'PASS' : 'FAIL', label, details.to_s.empty? ? '' : " — #{details}"))
  $failed += 1 unless passed
end

# --- Мягкие стабы SketchUp API ------------------------------------------------

class Dn1supPermissive
  def initialize(name = 'fake')
    @name = name
  end

  def method_missing(m, *args, &block)
    m.to_s.end_with?('=') ? args.first : Dn1supPermissive.new("#{@name}.#{m}")
  end

  def respond_to_missing?(*)
    true
  end

  def to_s
    @name
  end
end

unless defined?(Sketchup)
  module Sketchup
    class FakeExtension
      attr_reader :name, :path

      def initialize(name, path = nil)
        @name = name
        @path = path
      end

      def description(*); self; end
      def version(*);     self; end
      def copyright(*);   self; end
      def creator(*);     self; end

      def description=(*); self; end
      def version=(*);     self; end
      def copyright=(*);   self; end
      def creator=(*);     self; end
    end

    def self.const_missing(name)
      const_set(name, Class.new)
    end

    def self.extensions
      @extensions ||= [] # в SketchUp — массив SketchupExtension
    end

    def self.register_extension(ext, _active)
      extensions << ext
    end

    def self.add_observer(*);     true; end
    def self.remove_observer(*);  true; end

    def self.require(path)
      Kernel.require(path)
    end

    def self.active_model
      @active_model ||= Dn1supPermissive.new('model')
    end

    def self.version
      '26.0'
    end

    def self.read_default(*);   nil;  end
    def self.write_default(*);  true; end
    def self.set_status_text(*); end
    def self.temp_dir;          Dir.tmpdir; end
  end

  # В реальном SketchUp класс приходит из extensions.rb
  SketchupExtension = Sketchup::FakeExtension

  module UI
    def self.const_missing(name)
      const_set(name, Class.new do
        def initialize(*); end

        def method_missing(m, *args, &block)
          m.to_s.end_with?('=') ? args.first : Dn1supPermissive.new(m.to_s)
        end

        def respond_to_missing?(*)
          true
        end
      end)
    end

    def self.menu(*)
      Dn1supPermissive.new('menu')
    end

    def self.start_timer(*);  0;    end
    def self.stop_timer(*);   true; end
    def self.messagebox(*);   0;    end
    def self.openURL(*);      nil;  end
    def self.show_notification?; false; end
  end

  SKETCHUP_CONSOLE = Dn1supPermissive.new('console')

  $dn1sup_loaded = {}
  def file_loaded?(key)
    $dn1sup_loaded.key?(key)
  end

  def file_loaded(key)
    $dn1sup_loaded[key] = true
  end
end

# --- Ожидания по пакетам ------------------------------------------------------

EXPECTED = {
  'dn1sup_ext_manager'    => ['Dn1sup::ExtManager::VERSION', '0.3.0'],
  'dn1sup_time_project2'  => ['Dn1supTimeProject2::VERSION', '2.4.0'],
  'dn1sup_autoselect_tag' => ['Dn1sup::AutoSelectTag::VERSION', '0.3.0'],
  'dn1sup_comp_add_view'  => ['CustomTools::ComponentAddViews', nil]
}.freeze

def const_value(path)
  parts = path.split('::')
  return nil unless Object.const_defined?(parts.first)

  parts.reduce(Object) do |memo, name|
    return nil unless memo.const_defined?(name)

    memo.const_get(name)
  end
end

# --- Тесты --------------------------------------------------------------------

packages = Dir.glob(File.expand_path('../packages/*.rbz', __dir__)).sort
assert 'найдены собранные пакеты', packages.size == 4, packages.map { |p| File.basename(p) }.join(', ')

Dir.mktmpdir do |tmp|
  # Фейковые sketchup.rb / extensions.rb — как настоящие, только со стабами выше
  fake_lib = File.join(tmp, 'fake_lib')
  FileUtils.mkdir_p(fake_lib)
  File.write(File.join(fake_lib, 'sketchup.rb'), "# fake sketchup.rb для офлайн-стенда\n")
  File.write(File.join(fake_lib, 'extensions.rb'), "# fake extensions.rb для офлайн-стенда\n")

  $LOAD_PATH.unshift(fake_lib)
  require File.join(fake_lib, 'sketchup.rb')

  packages.each do |rbz|
    id = File.basename(rbz, '.rbz')
    plugins = File.join(tmp, 'Plugins')
    FileUtils.mkdir_p(plugins)
    $LOAD_PATH.unshift(plugins) unless $LOAD_PATH.include?(plugins)

    puts "\n--- #{id}"

    begin
      Zip::File.open(rbz) do |z|
        z.entries.each do |e|
          next if e.name_is_directory?

          target = File.join(plugins, e.name)
          FileUtils.mkdir_p(File.dirname(target))
          File.binwrite(target, e.get_input_stream.read)
        end
      end

      # Санити: в пакете есть зашифрованные стабы
      stubs = Dir.glob(File.join(plugins, id, '**', '*.rb')).count { |f| Dn1supPack::Protect.protected?(f) }
      assert("#{id}: в пакете есть зашифрованные стабы", stubs.positive?, "#{stubs} шт.")

      # 1. Регистрация: SketchUp грузит лоадер из Plugins
      load File.join(plugins, "#{id}.rb")
      assert("#{id}: лоадер зарегистрировал расширение", Sketchup.extensions.any? { |e| e.name =~ /dn1sup/i }, Sketchup.extensions.map(&:name).join(', '))

      # 2. Активация: грузим main по пути из SketchupExtension
      ext = Sketchup.extensions.last
      require ext.path

      const_path, expected_version = EXPECTED[id]
      value = const_value(const_path)
      assert("#{id}: код загружен (#{const_path})", !value.nil?)
      if expected_version
        assert("#{id}: версия #{expected_version}", value == expected_version, value.to_s)
      end
    rescue StandardError, ScriptError => e
      assert("#{id}: загрузка без ошибок", false, "#{e.class}: #{e.message} @ #{e.backtrace&.first(3)&.join(' | ')}")
    end
  end
end

puts "\n#{$failed.zero? ? 'ALL TESTS PASSED' : "#{$failed} FAILED"}"
exit($failed.zero? ? 0 : 1)
