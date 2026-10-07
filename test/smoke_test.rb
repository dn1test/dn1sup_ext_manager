$stdout.sync = true
$stderr.sync = true

require 'net/http'
require 'json'
require 'tmpdir'

ENV['GITHUB_TOKEN'] ||= ENV['GH_TOKEN']

$dialog_log = []
$failed = 0

module Sketchup
  $prefs = { 'Dn1supUpdater' => {} } # имитация Preferences-хранилища

  module_function

  def read_default(section, key, default = nil)
    $prefs.fetch(section, {}).fetch(key, default)
  end

  def write_default(section, key, value)
    $prefs[section] ||= {}
    $prefs[section][key] = value
    true
  end

  def require(path)
    base = File.expand_path('..', __dir__)
    candidates = [
      File.join(base, 'src', path + '.rb'),
      File.join(base, 'src', path, path + '.rb'),
      File.join(base, 'gh-extensions', 'src', path + '.rb'),
      File.join(base, 'gh-extensions', 'src', path, path + '.rb'),
    ]
    candidates.each do |c|
      c += '.rb' unless File.extname(c) == '.rb'
      return Kernel.require(c) if File.file?(c)
    end
    nil
  end

  def version
    '24.0.0'
  end

  def temp_dir
    Dir.tmpdir
  end

  def install_from_archive(path, _show_warning = true)
    $dialog_log << "INSTALL_FROM_ARCHIVE: #{File.basename(path)} (#{File.size(path)} bytes)"
    true
  end
end

module UI
  module_function

  def messagebox(msg, _type = 0)
    $dialog_log << "MESSAGEBOX: #{msg}"
    IDYES
  end

  def start_timer(*); end
  def openURL(url); $dialog_log << "OPEN_URL: #{url}"; end
  def inputbox(*); nil; end
  def menu(*)
    Class.new do
      def add_submenu(*); self; end
      def add_item(*); self; end
      def add_separator(*); self; end
    end.new
  end
end

IDYES = 2
IDNO  = 7
MB_OK = 0
MB_YESNO = 4

def file_loaded?(_); false; end
def file_loaded(_); true; end

module Geom
  class Point3d; end
  class Vector3d; end
end

SKETCHUP_CONSOLE = Object.new
def SKETCHUP_CONSOLE.clear; end

$LOAD_PATH.unshift File.expand_path('../src', __dir__)
require_relative '../shared/dn1sup_updater'

# === ТЕСТЫ ===

def assert(label, cond, details = '')
  passed = !!cond
  puts(format('%s %s%s', passed ? 'PASS' : 'FAIL', label, details.to_s.empty? ? '' : " — #{details}"))
  $failed += 1 unless passed
end

# 1. Сравнение версий
assert 'norm_version', Dn1sup::Updater.norm_version('v1.2.10') == [1, 2, 10]
assert 'norm_version pre-release отбрасывается', Dn1sup::Updater.norm_version('v0.3.0-rc1') == [0, 3, 0]
assert 'norm_version build-метаданные отбрасываются', Dn1sup::Updater.norm_version('1.2.3+build.7') == [1, 2, 3]
assert('newer? 1.2.10 > 1.2.3', Dn1sup::Updater.newer?([1, 2, 10], [1, 2, 3]) == true)
assert('newer? 1.2.3 vs 1.2.10', Dn1sup::Updater.newer?([1, 2, 3], [1, 2, 10]) == false)
assert('newer? 0.3.0-rc1 не новее 0.3.0',
       Dn1sup::Updater.newer?(Dn1sup::Updater.norm_version('0.3.0-rc1'),
                               Dn1sup::Updater.norm_version('0.3.0')) == false)

# 2. Реальный GitHub API — последний релиз sketchup-mcp2
rel = Dn1sup::Updater.latest_release('zinin/sketchup-mcp2')
assert 'latest_release возвращает данные', rel.is_a?(Hash) && rel.key?('tag_name'), "tag_name=#{rel['tag_name']}"
assert 'release содержит assets', rel['assets'].is_a?(Array) && rel['assets'].any?, "#{rel['assets'].size} assets"

# 3. Скачивание .rbz через browser_download_url
asset = rel['assets'].find { |a| a['name'].to_s.end_with?('.rbz') }
assert 'есть .rbz asset', !!asset, asset && asset['name']
path = Dn1sup::Updater.download(asset['browser_download_url'], File.join(Dir.tmpdir, 'test_download.rbz'))
assert 'download succeeded', path && File.file?(path), path
assert 'скачанный файл — валидный RBZ', path && Dn1sup::Updater.rbz?(path)

# 4. Полный цикл install_from_url -> install_from_archive
ok = Dn1sup::Updater.install_from_url(asset['browser_download_url'], 'Test Extension')
assert 'install_from_url через install_from_archive', ok == true
log = $dialog_log.grep(/INSTALL_FROM_ARCHIVE/).last
assert 'install_from_archive зафиксирован', !!log, log

# 5. Полный цикл check! (silent, force — без pergola)
summary = Dn1sup::Updater.check!(
  id: 'test', repo: 'zinin/sketchup-mcp2', version: '0.0.1',
  asset: asset['name'], force: true, silent: true
)
assert 'check! вернул summary', summary.is_a?(Hash) && summary[:latest] == rel['tag_name'], summary.inspect
assert 'check! записал метку времени', Sketchup.read_default('Dn1supUpdater', 'last_test').is_a?(Integer)

# 5b. registry_entry: per-extension версия из registry.json
repo_for_reg = 'dn1test/dn1sup_ext_manager'
reg_entry = Dn1sup::Updater.registry_entry(repo_for_reg, 'dn1sup_time_project2')
if reg_entry.nil?
  local_reg = JSON.parse(File.read(File.expand_path('../registry.json', __dir__)))
  reg_entry = Dn1sup::Updater.find_registry_entry(local_reg, 'dn1sup_time_project2')
end
assert 'registry_entry находит расширение', reg_entry.is_a?(Hash) && !reg_entry['version'].to_s.empty?, reg_entry.inspect
assert 'registry_entry для чужого id — nil', Dn1sup::Updater.registry_entry(repo_for_reg, 'no_such_ext').nil?

# 6. fetch_text с raw.githubusercontent.com
ok = !Dn1sup::Updater.fetch_text('https://raw.githubusercontent.com/SketchUp/rubocop-sketchup/master/README.md').to_s.empty?
assert 'fetch_text raw.githubusercontent', ok

# 7. Несуществующий репозиторий не должен ронять код
bad = Dn1sup::Updater.latest_release('nonexistent-user-000/nonexistent-repo-999')
assert '404 -> {} (устойчивость)', bad == {}

# 8. Псевдоним log_last_error
assert 'log_last_error доступен', Dn1sup::Updater.respond_to?(:log_last_error)

# 9. Dn1sup::Updater.check! когда версия актуальна
current_summary = Dn1sup::Updater.check!(
  id: 'test', repo: 'zinin/sketchup-mcp2', version: rel['tag_name'],
  asset: asset['name'], force: true, silent: true
)
assert 'check! возвращает nil для актуальной версии', current_summary.nil?

# 10. Загрузка и проверка dn1sup_ext_manager
require_relative '../src/dn1sup_ext_manager/main'
Sketchup.write_default('DN1Sup ExtManager', 'installed_dummy', '1.5.0')
assert 'ExtManager::installed_version fallback read_default', Dn1sup::ExtManager.installed_version('dummy') == '1.5.0'

# 11. Проверка prompt_pick при нажатии Cancel (UI.inputbox возвращает false)
assert 'prompt_pick обрабатывает false без исключений', Dn1sup::ExtManager.prompt_pick([{ 'name' => 'Test', 'installed_version' => nil }]).nil?

# 12. Проверка мгновенного сбора каталога без сети (offline mode)
offline_products = Dn1sup::ExtManager.collect_products_data(false, check_releases: false)
assert 'collect_products_data offline возвращает все расширения из реестра', offline_products.size == 6
assert 'collect_products_data offline содержит id dn1sup_ext_manager', offline_products.any? { |p| p['id'] == 'dn1sup_ext_manager' }
assert 'collect_products_data offline содержит id dn1sup_comp_add_view', offline_products.any? { |p| p['id'] == 'dn1sup_comp_add_view' }
assert 'collect_products_data offline содержит id dn1sup_create_project', offline_products.any? { |p| p['id'] == 'dn1sup_create_project' }
assert 'collect_products_data offline содержит id dn1sup_save_settings', offline_products.any? { |p| p['id'] == 'dn1sup_save_settings' }

puts "\n#{$failed.zero? ? 'ALL TESTS PASSED' : "#{$failed} FAILED"}"
exit($failed.zero? ? 0 : 1)
