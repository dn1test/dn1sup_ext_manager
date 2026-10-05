# frozen_string_literal: true

$stdout.sync = true

# test/protect_test.rb — офлайн-тесты обфускации tools/protect.rb, SketchUp не нужен.
#
#   ruby test/protect_test.rb
#
# Ключевой риск обфускации — поведение __FILE__/__dir__/require_relative внутри
# eval с именем файла. Тесты прогоняют реальный стаб: шифрование -> загрузка ->
# проверка семантики.

require 'tmpdir'
require 'fileutils'

require_relative '../tools/protect'

$failed = 0

def assert(label, cond, details = '')
  passed = !!cond
  puts(format('%s %s%s', passed ? 'PASS' : 'FAIL', label, details.to_s.empty? ? '' : " — #{details}"))
  $failed += 1 unless passed
end

Dir.mktmpdir do |tmp|
  # === 1. Roundtrip: стаб не содержит исходника и исполняется ===
  alpha = File.join(tmp, 'alpha.rb')
  File.write(alpha, <<~'RUBY')
    module Dn1supProtectTest
      PING = 'pong-alpha'
      WHERE = __FILE__
      DIR = __dir__
    end
  RUBY

  Dn1supPack::Protect.protect_file!(alpha)
  stub = File.read(alpha)
  assert 'стаб начинается с маркера', stub.start_with?(Dn1supPack::Protect::MARKER)
  assert 'стаб не содержит исходника', !stub.include?('pong-alpha')
  assert 'protected? распознаёт стаб', Dn1supPack::Protect.protected?(alpha)

  load alpha
  assert 'код исполнился после расшифровки',
         defined?(Dn1supProtectTest::PING) && Dn1supProtectTest::PING == 'pong-alpha'
  assert '__FILE__ сохранён', Dn1supProtectTest::WHERE == alpha, Dn1supProtectTest::WHERE
  assert '__dir__ сохранён', Dn1supProtectTest::DIR == File.dirname(alpha), Dn1supProtectTest::DIR

  # === 2. require_relative внутри eval (главный риск) ===
  Dir.mktmpdir do |d2|
    File.write(File.join(d2, 'beta_b.rb'), "module Dn1supProtectReq\n  B = 'b-loaded'\nend\n")
    File.write(File.join(d2, 'beta_a.rb'), <<~'RUBY')
      require_relative 'beta_b'
      module Dn1supProtectReq
        A = B
      end
    RUBY
    Dn1supPack::Protect.protect_file!(File.join(d2, 'beta_a.rb'))
    Dn1supPack::Protect.protect_file!(File.join(d2, 'beta_b.rb'))
    load File.join(d2, 'beta_a.rb')
    assert 'require_relative внутри eval работает (оба файла зашифрованы)',
           Dn1supProtectReq::A == 'b-loaded'
  end

  # === 3. protect_plugin!: открытые файлы, вложенность, идемпотентность ===
  Dir.mktmpdir do |d3|
    plugin = File.join(d3, 'plugin')
    FileUtils.mkdir_p(File.join(plugin, 'sub'))
    File.write(File.join(plugin, 'config.rb'), "OPEN_FILE = true\n")
    File.write(File.join(plugin, 'secret.rb'), "module Dn1supProtectPlug\n  V = 'secret'\nend\n")
    File.write(File.join(plugin, 'sub', 'nested.rb'), "module Dn1supProtectNested\n  V = 'nested'\nend\n")

    count = Dn1supPack::Protect.protect_plugin!(plugin)
    assert 'config.rb остался открытым', !Dn1supPack::Protect.protected?(File.join(plugin, 'config.rb'))
    assert 'secret.rb зашифрован', Dn1supPack::Protect.protected?(File.join(plugin, 'secret.rb'))
    assert 'вложенные .rb зашифрованы', Dn1supPack::Protect.protected?(File.join(plugin, 'sub', 'nested.rb'))
    assert 'возвращает число зашифрованных', count == 2, count.to_s

    before = File.binread(File.join(plugin, 'secret.rb'))
    count2 = Dn1supPack::Protect.protect_plugin!(plugin)
    assert 'повторный вызов ничего не меняет',
           count2.zero? && File.binread(File.join(plugin, 'secret.rb')) == before

    load File.join(plugin, 'secret.rb')
    assert 'зашифрованный файл из папки загружается', Dn1supProtectPlug::V == 'secret'
  end

  # === 4. Повреждённые данные не исполняются молча ===
  gamma = File.join(tmp, 'gamma.rb')
  File.write(gamma, "module Dn1supProtectTamper\n  V = 'gamma'\nend\n")
  Dn1supPack::Protect.protect_file!(gamma)
  lines = File.readlines(gamma)
  data_idx = lines.index { |l| l.strip =~ %r{\A[A-Za-z0-9+/]{60}\z} }
  raise 'в стабе не найдена строка данных' unless data_idx

  lines[data_idx] = lines[data_idx].sub(/\A../, 'Zz')
  File.write(gamma, lines.join)
  raised = false
  begin
    load gamma
  rescue StandardError
    raised = true
  end
  assert 'повреждённые данные дают исключение', raised

  # === 5. UTF-8 строки не искажаются ===
  delta = File.join(tmp, 'delta.rb')
  File.write(delta, "module Dn1supProtectEnc\n  TEXT = 'Привет мир'\nend\n")
  Dn1supPack::Protect.protect_file!(delta)
  load delta
  assert 'UTF-8 строки не искажаются', Dn1supProtectEnc::TEXT == 'Привет мир'
  assert 'кодировка строк UTF-8', Dn1supProtectEnc::TEXT.encoding == Encoding::UTF_8
end

puts "\n#{$failed.zero? ? 'ALL TESTS PASSED' : "#{$failed} FAILED"}"
exit($failed.zero? ? 0 : 1)
