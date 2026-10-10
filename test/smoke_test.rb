$stdout.sync = true
$stderr.sync = true

require 'net/http'
require 'json'
require 'tmpdir'

ENV['GITHUB_TOKEN'] ||= ENV['GH_TOKEN'] || (begin
  t = `gh auth token 2>nul`.strip
  t.empty? ? nil : t
rescue StandardError
  nil
end)

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

  class Command
    def initialize(*); end

    def menu_text=(*);       self; end
    def tooltip=(*);         self; end
    def status_bar_text=(*); self; end
    def small_icon=(*);      self; end
    def large_icon=(*);      self; end
    def validation_proc=(*); self; end
  end

  class Toolbar
    def initialize(*); end

    def any?(*); false; end
    def add_item(*); $dialog_log << 'TOOLBAR_ITEM'; self; end
    def restore(*);  $dialog_log << 'TOOLBAR_RESTORE'; self; end
  end
end

IDYES = 6
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
reg_entry = Dn1sup::Updater.registry_entry(repo_for_reg, 'dn1sup_time_project')
if reg_entry.nil?
  local_reg = JSON.parse(File.read(File.expand_path('../registry.json', __dir__)))
  reg_entry = Dn1sup::Updater.find_registry_entry(local_reg, 'dn1sup_time_project')
end
assert 'registry_entry находит расширение', reg_entry.is_a?(Hash) && !reg_entry['repo'].to_s.empty?, reg_entry.inspect
assert 'registry_entry для чужого id — nil', Dn1sup::Updater.registry_entry(repo_for_reg, 'no_such_ext').nil?

# 6. fetch_text с raw.githubusercontent.com
ok = !Dn1sup::Updater.fetch_text('https://raw.githubusercontent.com/SketchUp/rubocop-sketchup/master/README.md').to_s.empty?
assert 'fetch_text raw.githubusercontent', ok

# 7. Несуществующий репозиторий не должен ронять код
bad = Dn1sup::Updater.latest_release('nonexistent-user-000/nonexistent-repo-999')
assert '404 -> {} (устойчивость)', bad == {}

# 7b. repo_meta: живой репозиторий существует, несуществующий — 404
live_meta = Dn1sup::Updater.repo_meta('dn1test/dn1sup_ext_manager')
assert 'repo_meta: живой репозиторий — exists без renamed',
       live_meta.is_a?(Hash) && live_meta[:exists] == true && live_meta[:renamed] == false &&
       live_meta[:repo] == 'dn1test/dn1sup_ext_manager', live_meta.inspect
gone_meta = Dn1sup::Updater.repo_meta('nonexistent-user-000/nonexistent-repo-999')
assert 'repo_meta: 404 -> exists: false', gone_meta == { exists: false }, gone_meta.inspect

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

assert 'тулбар создан с кнопкой каталога', $dialog_log.include?('TOOLBAR_ITEM')
assert 'тулбар показан (restore)', $dialog_log.include?('TOOLBAR_RESTORE')

# 10b. perform_uninstall: белый список id (path traversal) + сброс installed_at
require 'fileutils'
fake_plugins = Dir.mktmpdir
File.write(File.join(fake_plugins, 'other_plugin.rb'), '# соседний плагин — должен выжить')
FileUtils.mkdir_p(File.join(fake_plugins, 'dn1sup_save_settings'))
File.write(File.join(fake_plugins, 'dn1sup_save_settings', 'main.rb'), '# плагин под удаление')
File.write(File.join(fake_plugins, 'dn1sup_save_settings.rb'), '# loader под удаление')
Sketchup.define_singleton_method(:find_support_file) { |name| name == 'Plugins' ? fake_plugins : nil }
Sketchup.write_default('Dn1supUpdater', 'installed_at_dn1sup_save_settings', Time.now.to_i)

['.', '..', '../evil', 'foo', ''].each do |bad|
  r = Dn1sup::ExtManager.perform_uninstall(bad)
  assert "uninstall отклоняет #{bad.inspect}", r['ok'] == false, r.inspect
end
r = Dn1sup::ExtManager.perform_uninstall('dn1sup_nosuch')
assert 'uninstall отклоняет id вне реестра', r['ok'] == false, r.inspect
assert 'после отклонений соседний плагин цел', File.file?(File.join(fake_plugins, 'other_plugin.rb'))

r = Dn1sup::ExtManager.perform_uninstall('dn1sup_save_settings')
assert 'uninstall валидного id проходит', r['ok'] == true, r.inspect
assert 'файлы расширения удалены', !File.exist?(File.join(fake_plugins, 'dn1sup_save_settings')) &&
                                   !File.exist?(File.join(fake_plugins, 'dn1sup_save_settings.rb'))
assert 'installed_at сброшен', Sketchup.read_default('Dn1supUpdater', 'installed_at_dn1sup_save_settings', nil).nil?
assert 'соседний плагин не тронут', File.file?(File.join(fake_plugins, 'other_plugin.rb'))
Sketchup.singleton_class.send(:remove_method, :find_support_file)
FileUtils.remove_entry(fake_plugins)

# 10c. full_tag_name: полный тег из списка релизов, фолбэк v<version>
Dn1sup::ExtManager.instance_variable_set(
  :@releases_cache,
  'dn1test/tag_repo' => [{ 'tag_name' => '0.4.1' }, { 'tag_name' => 'v2.4.1' }]
)
assert 'full_tag_name: тег без префикса берётся как есть',
       Dn1sup::ExtManager.full_tag_name('dn1test/tag_repo', '0.4.1') == '0.4.1'
assert 'full_tag_name: v-тег из списка',
       Dn1sup::ExtManager.full_tag_name('dn1test/tag_repo', '2.4.1') == 'v2.4.1'
assert 'full_tag_name: фолбэк v<version>',
       Dn1sup::ExtManager.full_tag_name('dn1test/tag_repo', '9.9.9') == 'v9.9.9'
assert 'full_tag_name: пустой список — фолбэк',
       Dn1sup::ExtManager.full_tag_name('dn1test/other', '1.0.0') == 'v1.0.0'

# 11. Проверка prompt_pick при нажатии Cancel (UI.inputbox возвращает false)
assert 'prompt_pick обрабатывает false без исключений', Dn1sup::ExtManager.prompt_pick([{ 'name' => 'Test', 'installed_version' => nil }]).nil?

# 12. Проверка мгновенного сбора каталога без сети (offline mode)
offline_products = Dn1sup::ExtManager.collect_products_data(false, check_releases: false)
assert 'collect_products_data offline возвращает все расширения из реестра', offline_products.size == 6
assert 'collect_products_data offline содержит id dn1sup_ext_manager', offline_products.any? { |p| p['id'] == 'dn1sup_ext_manager' }
assert 'collect_products_data offline содержит id dn1sup_comp_add_view', offline_products.any? { |p| p['id'] == 'dn1sup_comp_add_view' }
assert 'collect_products_data offline содержит id dn1sup_create_project', offline_products.any? { |p| p['id'] == 'dn1sup_create_project' }
assert 'collect_products_data offline содержит id dn1sup_save_settings', offline_products.any? { |p| p['id'] == 'dn1sup_save_settings' }

# 13. Протокол диалога: dispatch (единый колбэк call_ruby -> pushState/pushResult)
class FakeStoreDialog
  attr_reader :scripts

  def initialize
    @scripts = []
  end

  def add_action_callback(*); true;   end
  def visible?;               true;   end
  def execute_script(s);      @scripts << s; end
end

store_dlg = FakeStoreDialog.new
Dn1sup::ExtManager.instance_variable_set(:@dialog, store_dlg)

# defer_async синхронно: start_timer вызывает блок сразу (repeat=false в SketchUp
# — однократный вызов; здесь повторный вызов не нужен, т.к. работа синхронна)
orig_start_timer = UI.method(:start_timer)
UI.define_singleton_method(:start_timer) { |_interval, _repeat = false, &blk| blk&.call(:timer) }
UI.define_singleton_method(:stop_timer)  { |_timer| true }

begin
  # Предзаполняем кэш релизов: pushState уйдёт офлайн, без сетевых запросов
  entries = Dn1sup::ExtManager.load_registry
  Dn1sup::ExtManager.instance_variable_set(
    :@release_cache,
    entries.each_with_object({}) { |e, h| h[e['repo'].to_s] = { 'tag_name' => 'v9.9.9' } }
  )
  # Откладываем автопоиск GitHub: dispatch-тесты должны быть офлайн
  Sketchup.write_default('DN1Sup ExtManager', 'last_discovery', Time.now.to_i)

  store_dlg.scripts.clear
  Dn1sup::ExtManager.dispatch(store_dlg, 'ready', '')
  pushed = store_dlg.scripts.grep(/\Awindow\.pushState\(/).last
  assert 'dispatch ready -> pushState', !!pushed, pushed.to_s[0, 120]
  assert 'pushState содержит version', pushed.to_s.include?('"version":')
  assert 'pushState содержит products', pushed.to_s.include?('"products":[')
  assert 'pushState содержит все расширения реестра', pushed.to_s.include?('"dn1sup_ext_manager"')

  store_dlg.scripts.clear
  Dn1sup::ExtManager.dispatch(store_dlg, 'install', JSON.generate('id' => 'no_such_ext'))
  res_script = store_dlg.scripts.grep(/window\.pushResult\(/).last
  assert 'dispatch install неизвестного id -> pushResult ok:false', !!res_script && res_script.include?('false'), res_script.to_s[0, 160]

  store_dlg.scripts.clear
  Dn1sup::ExtManager.dispatch(store_dlg, 'confirm_uninstall', JSON.generate('id' => 'no_such_ext'))
  conf_script = store_dlg.scripts.grep(/window\.pushResult\(/).last
  assert 'dispatch confirm_uninstall -> pushResult(kind, payload)', !!conf_script && conf_script.include?('confirm_uninstall'), conf_script.to_s[0, 160]

  store_dlg.scripts.clear
  Dn1sup::ExtManager.dispatch(store_dlg, 'hide', JSON.generate('repo' => 'dn1test/dn1sup_dummy_found'))
  assert 'dispatch hide -> перерисовка каталога', store_dlg.scripts.grep(/\Awindow\.pushState\(/).any?
  assert 'dispatch hide записал pref', Sketchup.read_default('DN1Sup ExtManager', 'hidden_repos').to_s.include?('dn1sup_dummy_found')
  Dn1sup::ExtManager.unhide_all_repos

  before = $dialog_log.size
  Dn1sup::ExtManager.dispatch(store_dlg, 'неизвестная_команда', '')
  assert 'dispatch неизвестная команда не роняет код', $dialog_log.size >= before
ensure
  UI.define_singleton_method(:start_timer, orig_start_timer)
  UI.singleton_class.send(:remove_method, :stop_timer) rescue nil
  Dn1sup::ExtManager.instance_variable_set(:@dialog, nil)
  Dn1sup::ExtManager.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtManager.unhide_all_repos
end

# 13b. Автопоиск расширений: слияние реестра и найденного, скрытие, коммиты,
# снапшот v3 (все проверки офлайн — найденное подкладывается в кэш руками)
discovered_fixture = [
  {
    'id'          => 'dn1sup_dummy_found',
    'name'        => 'DN1Sup Dummy Found',
    'description' => 'расширение, найденное на GitHub вне реестра',
    'repo'        => 'dn1test/dn1sup_dummy_found',
    'discovered'  => true
  }
]
begin
  Dn1sup::ExtManager.instance_variable_set(:@discovered_entries, discovered_fixture)

  merged = Dn1sup::ExtManager.merged_entries
  assert 'merged_entries: реестр + найденное', merged.any? { |e| e['id'] == 'dn1sup_dummy_found' } && merged.any? { |e| e['id'] == 'dn1sup_ext_manager' }
  assert 'find_entry находит найденное расширение', Dn1sup::ExtManager.find_entry('dn1sup_dummy_found').is_a?(Hash)
  assert 'product_name для найденного расширения', Dn1sup::ExtManager.product_name('dn1sup_dummy_found') == 'DN1Sup Dummy Found'

  # Найденное без известных релизов в каталог не попадает
  offline = Dn1sup::ExtManager.collect_products_data(false, check_releases: false)
  assert 'collect: найденное без релизов скрыто', offline.none? { |p| p['discovered'] }

  # С известными релизами появляется карточка discovered (не установлено)
  Dn1sup::ExtManager.instance_variable_set(
    :@releases_cache,
    {
      'dn1test/dn1sup_dummy_found' => [
        {
          'tag_name' => 'v0.1.0', 'published_at' => '2026-10-01T00:00:00Z',
          'assets' => [{ 'name' => 'dn1sup_dummy_found.rbz', 'browser_download_url' => 'https://example.com/x.rbz' }]
        }
      ]
    }
  )
  dummy = Dn1sup::ExtManager.collect_products_data(false, check_releases: false).find { |p| p['id'] == 'dn1sup_dummy_found' }
  assert 'collect: найденное с релизами показано', !!dummy && dummy['discovered'] == true
  assert 'collect: найденное помечено не установленным', !!dummy && dummy['is_installed'] == false
  assert 'collect: у найденного есть .rbz ассет', !!dummy && dummy['asset'] == 'dn1sup_dummy_found.rbz'

  # Коммиты из кэша попадают в payload при совпадении пары версий
  Dn1sup::ExtManager.instance_variable_set(
    :@commits_cache,
    { 'dn1test/dn1sup_dummy_found' => { 'installed' => '', 'offered' => '0.1.0', 'messages' => ['feat: demo'] } }
  )
  dummy2 = Dn1sup::ExtManager.collect_products_data(false, check_releases: false).find { |p| p['id'] == 'dn1sup_dummy_found' }
  assert 'collect: коммиты в payload при совпадении версий', !!dummy2 && dummy2['commits'] == ['feat: demo']

  # Скрытие найденного репозитория
  Dn1sup::ExtManager.hide_repo('dn1test/dn1sup_dummy_found')
  assert 'hide_repo: запись в pref', Sketchup.read_default('DN1Sup ExtManager', 'hidden_repos').to_s.include?('dn1sup_dummy_found')
  assert 'merged_entries: скрытое отфильтровано', Dn1sup::ExtManager.merged_entries.none? { |e| e['id'] == 'dn1sup_dummy_found' }
  Dn1sup::ExtManager.unhide_all_repos
  assert 'unhide_all_repos: pref очищен', Dn1sup::ExtManager.hidden_repos.empty?

  # Снапшот v3: найденные расширения и коммиты переживают перезапуск
  Dn1sup::ExtManager.save_release_snapshot
  Dn1sup::ExtManager.instance_variable_set(:@discovered_entries, [])
  Dn1sup::ExtManager.instance_variable_set(:@commits_cache, {})
  Dn1sup::ExtManager.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtManager.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtManager.load_release_snapshot
  assert 'снапшот v3: discovered восстановлен', Dn1sup::ExtManager.merged_entries.any? { |e| e['id'] == 'dn1sup_dummy_found' }
  assert 'снапшот v3: commits восстановлен',
         Dn1sup::ExtManager.instance_variable_get(:@commits_cache)['dn1test/dn1sup_dummy_found']['messages'] == ['feat: demo']
ensure
  Dn1sup::ExtManager.instance_variable_set(:@discovered_entries, [])
  Dn1sup::ExtManager.instance_variable_set(:@commits_cache, {})
  Dn1sup::ExtManager.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtManager.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtManager.unhide_all_repos
end

# 13c. Мёртвые/переименованные репозитории: repo_meta (офлайн, с подменой
# http_get), apply_repo_status, фильтрация карточек, снапшот v4.
# Живые проверки repo_meta — в секции 7b.
begin
  # --- repo_meta с подменой http_get --------------------------------------
  # body= у Net::HTTPResponse вне блока request бросает IOError — заполняем ivar'ы
  resp200 = lambda do |full_name|
    r = Net::HTTPSuccess.new('1.1', '200', 'OK')
    r.instance_variable_set(:@body, JSON.generate('full_name' => full_name))
    r.instance_variable_set(:@read, true)
    r
  end
  resp404 = Net::HTTPNotFound.new('1.1', '404', 'Not Found')
  orig_http_get = Dn1sup::Updater.method(:http_get)
  Dn1sup::Updater.define_singleton_method(:http_get) { |_uri_or_str, _redirects = 5| $stub_http_response }

  $stub_http_response = resp200.call('dn1test/dn1sup_time_project')
  m = Dn1sup::Updater.repo_meta('dn1test/dn1sup_time_project')
  assert 'repo_meta: жив, имя совпадает', m == { exists: true, repo: 'dn1test/dn1sup_time_project', renamed: false }, m.inspect

  $stub_http_response = resp200.call('dn1test/dn1sup_new_name')
  m = Dn1sup::Updater.repo_meta('dn1test/dn1sup_old_name')
  assert 'repo_meta: переименован — новое имя и renamed',
         m == { exists: true, repo: 'dn1test/dn1sup_new_name', renamed: true }, m.inspect

  $stub_http_response = resp404
  assert 'repo_meta: 404 -> exists: false', Dn1sup::Updater.repo_meta('dn1test/dn1sup_old_name') == { exists: false }

  Dn1sup::Updater.define_singleton_method(:http_get) { |_u, _r = 5| raise Errno::ECONNREFUSED }
  assert 'repo_meta: сетевая ошибка -> nil (статус неизвестен)', Dn1sup::Updater.repo_meta('dn1test/x').nil?
ensure
  Dn1sup::Updater.define_singleton_method(:http_get, orig_http_get)
end

begin
  # --- apply_repo_status и фильтрация карточек ----------------------------
  Dn1sup::ExtManager.instance_variable_set(:@discovered_entries, [discovered_fixture[0].dup])
  Dn1sup::ExtManager.instance_variable_set(
    :@releases_cache,
    { 'dn1test/dn1sup_dummy_found' => [{ 'tag_name' => 'v0.1.0', 'published_at' => '2026-10-01T00:00:00Z', 'assets' => [] }] }
  )
  # save_settings считаем установленным: карточка с мёртвым репо должна
  # остаться в каталоге с пометкой
  Sketchup.write_default('DN1Sup ExtManager', 'installed_dn1sup_save_settings', '1.0.0')

  Dn1sup::ExtManager.apply_repo_status(
    'dn1test/dn1sup_dummy_found'   => { exists: false },
    'dn1test/dn1sup_save_settings' => { exists: true, repo: 'dn1test/dn1sup_save_settings_new', renamed: true },
    'dn1test/dn1sup_ext_manager'   => { exists: true, repo: 'dn1test/dn1sup_ext_manager', renamed: false },
    'dn1test/unreachable'          => nil
  )
  stale_map = Dn1sup::ExtManager.instance_variable_get(:@stale_repos)
  assert 'apply: удалённый помечен gone', stale_map['dn1test/dn1sup_dummy_found']['status'] == 'gone'
  assert 'apply: переименованный помечен с новым именем',
         stale_map['dn1test/dn1sup_save_settings']['status'] == 'renamed' &&
         stale_map['dn1test/dn1sup_save_settings']['renamed_to'] == 'dn1test/dn1sup_save_settings_new'
  assert 'apply: живой репозиторий — ok', stale_map['dn1test/dn1sup_ext_manager']['status'] == 'ok'
  assert 'apply: сеть (nil) — без пометки', stale_map['dn1test/unreachable'].nil?
  assert 'apply: stale? видит мёртвые',
         Dn1sup::ExtManager.stale?('dn1test/dn1sup_dummy_found') &&
         Dn1sup::ExtManager.stale?('dn1test/dn1sup_save_settings')
  assert 'apply: живой не stale', !Dn1sup::ExtManager.stale?('dn1test/dn1sup_ext_manager')
  assert 'apply: кэш релизов мёртвого почищен',
         Dn1sup::ExtManager.instance_variable_get(:@releases_cache).none? { |repo, _| repo == 'dn1test/dn1sup_dummy_found' }
  assert 'apply: найденная запись мёртвого удалена',
         Dn1sup::ExtManager.instance_variable_get(:@discovered_entries).none? { |e| e['repo'] == 'dn1test/dn1sup_dummy_found' }

  products = Dn1sup::ExtManager.collect_products_data(false, check_releases: false)
  assert 'collect: неустановленное с мёртвым репо скрыто', products.none? { |p| p['id'] == 'dn1sup_dummy_found' }
  ss = products.find { |p| p['id'] == 'dn1sup_save_settings' }
  assert 'collect: установленное с переименованным репо осталось с пометкой',
         !!ss && ss['repo_status'] == 'renamed' && ss['is_installed'] == true && ss['has_update'] == false,
         ss&.slice('repo_status', 'has_update').inspect
  em = products.find { |p| p['id'] == 'dn1sup_ext_manager' }
  assert 'collect: живое расширение без пометки', !!em && em['repo_status'].to_s.empty?

  res = Dn1sup::ExtManager.perform_install('dn1sup_save_settings')
  assert 'install: мёртвый репо отклонён без сети', res['ok'] == false && res['error'].to_s.include?('недоступен'), res.inspect

  Dn1sup::ExtManager.apply_repo_status(
    'dn1test/dn1sup_save_settings' => { exists: true, repo: 'dn1test/dn1sup_save_settings', renamed: false }
  )
  assert 'apply: вернувшийся репозиторий перестаёт быть stale', !Dn1sup::ExtManager.stale?('dn1test/dn1sup_save_settings')
ensure
  Dn1sup::ExtManager.instance_variable_set(:@stale_repos, {})
  Dn1sup::ExtManager.instance_variable_set(:@discovered_entries, [])
  Dn1sup::ExtManager.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtManager.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtManager.instance_variable_set(:@commits_cache, {})
  Sketchup.write_default('DN1Sup ExtManager', 'installed_dn1sup_save_settings', nil)
end

begin
  # --- снапшот v4: статусы репозиториев переживают перезапуск -------------
  Dn1sup::ExtManager.instance_variable_set(
    :@stale_repos,
    { 'dn1test/dn1sup_dummy_found' => { 'status' => 'gone', 'renamed_to' => '', 'checked_at' => 1_700_000_000 } }
  )
  Dn1sup::ExtManager.save_release_snapshot
  data = JSON.parse(File.read(Dn1sup::ExtManager.snapshot_path))
  assert 'снапшот v4: версия и поле stale',
         data['version'] == 4 && data['stale'].is_a?(Hash) &&
         data['stale']['dn1test/dn1sup_dummy_found']['status'] == 'gone', "version=#{data['version']}"

  Dn1sup::ExtManager.instance_variable_set(:@stale_repos, {})
  Dn1sup::ExtManager.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtManager.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtManager.load_release_snapshot
  assert 'снапшот v4: stale восстановлен',
         Dn1sup::ExtManager.instance_variable_get(:@stale_repos)['dn1test/dn1sup_dummy_found']['status'] == 'gone'

  # Старый формат v3 (без stale) читается, stale остаётся пустым
  data.delete('stale')
  data['version'] = 3
  File.write(Dn1sup::ExtManager.snapshot_path, JSON.generate(data))
  Dn1sup::ExtManager.instance_variable_set(:@stale_repos, {})
  Dn1sup::ExtManager.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtManager.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtManager.load_release_snapshot
  assert 'снапшот v3 без stale читается',
         Dn1sup::ExtManager.instance_variable_get(:@stale_repos).empty? &&
         Dn1sup::ExtManager.instance_variable_get(:@releases_cache).is_a?(Hash)
ensure
  Dn1sup::ExtManager.instance_variable_set(:@stale_repos, {})
  Dn1sup::ExtManager.instance_variable_set(:@release_cache, {})
  Dn1sup::ExtManager.instance_variable_set(:@releases_cache, {})
  Dn1sup::ExtManager.instance_variable_set(:@discovered_entries, [])
  Dn1sup::ExtManager.instance_variable_set(:@commits_cache, {})
end

# 14. Уровни логирования: краткий прикладной лог + [DEBUG] только при флаге debug
Dn1sup::Updater.log_info('smoke_test_probe_log_info')
Dn1sup::Updater.log_error(RuntimeError.new('smoke_test_probe_log_error'))
Dn1sup::Updater.log_debug('smoke_test_probe_log_debug')
slog = File.join(Sketchup.temp_dir, 'dn1sup_updater.log')
assert 'лог-файл создан', File.file?(slog), slog
if File.file?(slog)
  last_entries = File.readlines(slog, encoding: 'UTF-8').last(3).join
  assert 'log_info пишет [INFO] строку в лог', last_entries.include?('[INFO] smoke_test_probe_log_info'), last_entries
  assert 'log_error пишет [ERROR] строку в лог', last_entries.include?('[ERROR] RuntimeError: smoke_test_probe_log_error'), last_entries
  dbg_off = !last_entries.include?('[DEBUG] smoke_test_probe_log_debug')
  assert 'log_debug НЕ пишет без флага debug', dbg_off

  # Включаем debug-флаг, пере-тестируем
  $prefs['Dn1supUpdater']['debug'] = true
  Dn1sup::Updater.log_debug('smoke_test_probe_log_debug_on')
  line = File.readlines(slog, encoding: 'UTF-8').last
  assert 'log_debug пишет [DEBUG] с флагом debug', line.include?('[DEBUG] smoke_test_probe_log_debug_on'), line
  $prefs['Dn1supUpdater']['debug'] = nil
end

# 15. Краткие заметки для UI: markdown вычищен, ≤3 строки, ~200 символов
md = <<~BODY
  ### Extension Store (v0.6.2)
  - **Первый пункт** с `кодом` и [ссылкой](https://example.com/very/long/url)
  ![img](https://example.com/img.png)
  - **Второй пункт** — перенос
  третьей строки, а это длинный-предлинный четвёртый пункт описания который превышает лимит двести символов и потому будет аккуратно усечён по границе слова с многоточием в конце чтобы не ломать отображение в интерфейсе
BODY
sn = Dn1sup::Updater.short_notes(md)
assert 'short_notes: не содержит markdown-символов', ['**', '`', '](', '![', '### '].none? { |m| sn.include?(m) }, sn
assert 'short_notes: не более 3 строк', sn.lines.size <= 3, "строк: #{sn.lines.size}"
assert 'short_notes: длина в пределах', sn.length <= 210, "длина: #{sn.length}"
assert 'short_notes: markdown-текст -> plain', sn.include?('Первый пункт'), sn

# 16. Выбор предлагаемого релиза и статусы: сценарий смены схемы нумерации
# (реальная ситуация dn1sup_time_project: релиз v0.4.1 опубликован позже
# серии 2.4.x, /releases/latest указывает на 0.4.1 при установленной 2.4.1)
tp_list = [
  { 'tag_name' => 'v0.4.1', 'published_at' => '2026-10-09T06:17:55Z' },
  { 'tag_name' => 'v2.4.1', 'published_at' => '2026-10-07T14:45:39Z' },
  { 'tag_name' => 'v2.4.0', 'published_at' => '2026-10-07T05:28:57Z' }
]
tp_offered = Dn1sup::Updater.choose_release(tp_list)
assert 'choose_release берёт новейший по дате публикации', tp_offered['tag_name'] == 'v0.4.1', tp_offered['tag_name'].to_s
assert 'product_status: 0.3.0 -> 0.4.1 это update', Dn1sup::Updater.product_status('0.3.0', tp_offered, tp_list) == 'update'
assert 'product_status: 2.4.1 -> 0.4.1 это switch', Dn1sup::Updater.product_status('2.4.1', tp_offered, tp_list) == 'switch'
assert 'product_status: 2.4.0 -> 0.4.1 это switch', Dn1sup::Updater.product_status('2.4.0', tp_offered, tp_list) == 'switch'
assert 'product_status: 0.4.1 -> 0.4.1 это current', Dn1sup::Updater.product_status('0.4.1', tp_offered, tp_list) == 'current'
assert 'product_status: v-префикс нормализуется', Dn1sup::Updater.product_status('v0.4.1', tp_offered, tp_list) == 'current'
assert 'product_status: установленная новее, её релиза нет в списке — без предложения',
       Dn1sup::Updater.product_status('9.9.9', tp_offered, tp_list).nil?
assert 'product_status: 2.3.0 тоже ниже 0.4.1 отсутствует в списке — без предложения',
       Dn1sup::Updater.product_status('2.3.0', tp_offered, tp_list).nil?
assert 'product_status: не установлено — nil', Dn1sup::Updater.product_status(nil, tp_offered, tp_list).nil?
assert 'product_status: релизы недоступны — nil', Dn1sup::Updater.product_status('2.4.1', nil, []).nil?
# Если самый свежий по дате релиз — сама установленная версия (перепубликованный
# тег), предлагаемого действия нет; при равных датах предлагаемый не новее —
# тоже без предложения (строгое сравнение).
repub = [
  { 'tag_name' => 'v2.4.1', 'published_at' => '2026-10-11T00:00:00Z' },
  { 'tag_name' => 'v0.4.1', 'published_at' => '2026-10-09T06:17:55Z' }
]
assert 'product_status: перепубликованный установленный тег — current',
       Dn1sup::Updater.product_status('2.4.1', Dn1sup::Updater.choose_release(repub), repub) == 'current'
same_time = [
  { 'tag_name' => 'v0.4.1', 'published_at' => '2026-10-09T06:17:55Z' },
  { 'tag_name' => 'v2.4.1', 'published_at' => '2026-10-09T06:17:55Z' }
]
assert 'product_status: равные даты публикации — без предложения',
       Dn1sup::Updater.product_status('2.4.1', Dn1sup::Updater.choose_release(same_time), same_time).nil?
pre_list = [
  { 'tag_name' => 'v0.5.0-rc1', 'prerelease' => true, 'published_at' => '2026-10-10T00:00:00Z' },
  { 'tag_name' => 'v0.4.9', 'published_at' => '2026-10-01T00:00:00Z' }
]
assert 'choose_release пропускает prerelease', Dn1sup::Updater.choose_release(pre_list)['tag_name'] == 'v0.4.9'
assert 'choose_release пустой/битый список — nil', Dn1sup::Updater.choose_release([nil, 'x', {}]).nil?

# 16b. Дата-фолбэк: обновление по дате публикации релиза, а не только по номеру
assert 'installed_at: не задано — nil', Dn1sup::Updater.installed_at('date_none').nil?
Dn1sup::Updater.mark_installed('date_rt')
at = Dn1sup::Updater.installed_at('date_rt')
assert 'installed_at: mark_installed -> чтение', at.is_a?(Integer) && at > 0, at.inspect

repub_rel = {
  'tag_name' => 'v1.2.3', 'published_at' => '2026-10-09T00:00:00Z',
  'body' => 'hotfix без бампа версии', 'html_url' => 'https://example.com/r', 'assets' => []
}
cfg_date = { id: 'date_t1', repo: 'o/r', version: '1.2.3', asset: 'x.rbz' }

# Тот же номер версии, релиз издан позже установки -> предлагаем установку
Sketchup.write_default('Dn1supUpdater', 'installed_at_date_t1', 1_600_000_000)
s = Dn1sup::Updater.apply_check(cfg_date, { release: repub_rel, latest: '1.2.3', from_registry: false },
                                force: true, silent: true)
assert 'apply_check: переизданный релиз той же версии — обновление по дате',
       s.is_a?(Hash) && s[:same_version] == true, s.inspect

# Релиз старее установленной сборки — прежнее «актуальная версия»
Sketchup.write_default('Dn1supUpdater', 'installed_at_date_t1', 1_900_000_000)
s = Dn1sup::Updater.apply_check(cfg_date, { release: repub_rel, latest: '1.2.3', from_registry: false },
                                force: true, silent: true)
assert 'apply_check: релиз старее установки — nil', s.nil?

# Дата установки неизвестна (ручная установка) — прежнее поведение
Sketchup.write_default('Dn1supUpdater', 'installed_at_date_t1', nil)
s = Dn1sup::Updater.apply_check(cfg_date, { release: repub_rel, latest: '1.2.3', from_registry: false },
                                force: true, silent: true)
assert 'apply_check: без даты установки — nil', s.nil?

# Монорепо: версия из registry не совпадает с тегом релиза — релиз чужой,
# его дату сравнивать нельзя
cfg_mono = { id: 'date_t2', repo: 'o/r', version: '2.0.0', asset: 'y.rbz' }
Sketchup.write_default('Dn1supUpdater', 'installed_at_date_t2', 1_600_000_000)
s = Dn1sup::Updater.apply_check(cfg_mono, { release: repub_rel, latest: '2.0.0', from_registry: true },
                                force: true, silent: true)
assert 'apply_check: монорепо, чужой тег релиза — nil', s.nil?

# Монорепо: версия из registry совпадает с тегом — дата-фолбэк работает
mono_rel = repub_rel.merge('tag_name' => 'v2.0.0')
s = Dn1sup::Updater.apply_check(cfg_mono, { release: mono_rel, latest: '2.0.0', from_registry: true },
                                force: true, silent: true)
assert 'apply_check: монорепо, тег соответствует — обновление по дате',
       s.is_a?(Hash) && s[:same_version] == true, s.inspect

# Численно новая версия — как раньше, без даты установки и без флага
Sketchup.write_default('Dn1supUpdater', 'installed_at_date_t1', nil)
new_rel = repub_rel.merge('tag_name' => 'v1.3.0')
s = Dn1sup::Updater.apply_check(cfg_date, { release: new_rel, latest: '1.3.0', from_registry: false },
                                force: true, silent: true)
assert 'apply_check: новая версия — update как раньше, без same_version',
       s.is_a?(Hash) && !s.key?(:same_version), s.inspect

# product_status: фолбэк на дату установки, когда релиза установленной версии
# нет в списке
older_install = 1_600_000_000   # 2020-09, раньше релиза 0.4.1 (2026-10)
newer_install = 1_900_000_000   # 2030-03, позже релиза
v041 = { 'tag_name' => 'v0.4.1', 'published_at' => '2026-10-09T06:17:55Z' }
assert 'product_status: релиза нет в списке, установка старее — switch',
       Dn1sup::Updater.product_status('1.0.0', v041, [], installed_at: older_install) == 'switch'
assert 'product_status: релиза нет в списке, установка новее — nil',
       Dn1sup::Updater.product_status('1.0.0', v041, [], installed_at: newer_install).nil?
assert 'product_status: релиза нет в списке, даты нет — nil (как раньше)',
       Dn1sup::Updater.product_status('1.0.0', v041, []).nil?
# Переизпуск той же версии: релиз опубликован позже установки
assert 'product_status: та же версия, переиздана позже установки — switch',
       Dn1sup::Updater.product_status('0.4.1', v041, [v041], installed_at: older_install) == 'switch'
assert 'product_status: та же версия, установка позже релиза — current',
       Dn1sup::Updater.product_status('0.4.1', v041, [v041], installed_at: newer_install) == 'current'

# 17. Живой список релизов GET /releases
live_releases = Dn1sup::Updater.releases('zinin/sketchup-mcp2')
assert 'releases возвращает непустой массив', live_releases.is_a?(Array) && live_releases.any?, "#{live_releases.size} релизов"
live_offered = Dn1sup::Updater.choose_release(live_releases)
assert 'choose_release по живому списку даёт тег из этого списка',
       live_offered && live_releases.any? { |r| r['tag_name'] == live_offered['tag_name'] }, live_offered && live_offered['tag_name']
bad_releases = Dn1sup::Updater.releases('nonexistent-user-000/nonexistent-repo-999')
assert 'releases 404 -> [] (устойчивость)', bad_releases == []

# 18. Автопоиск: репозитории аккаунта dn1test (живой GitHub)
owner_repos = Dn1sup::Updater.repos_of_owner('dn1test')
assert 'repos_of_owner возвращает репозитории', owner_repos.is_a?(Array) && owner_repos.any?, "#{owner_repos.size} репозиториев"
assert 'repos_of_owner содержит менеджер', owner_repos.any? { |r| r['full_name'] == 'dn1test/dn1sup_ext_manager' }
assert 'repos_of_owner неизвестный аккаунт -> []', Dn1sup::Updater.repos_of_owner('nonexistent-user-000-zzz') == []

# 19. Лог правок: коммиты между тегами (живой GitHub)
cmts = Dn1sup::Updater.compare_commits('dn1test/dn1sup_time_project', 'v0.4.1', 'v0.5.0', limit: 5)
assert 'compare_commits возвращает сообщения', cmts.is_a?(Array) && cmts.any?, cmts.inspect
assert 'compare_commits: непустые строки', cmts.all? { |m| m.is_a?(String) && !m.strip.empty? }
assert 'compare_commits: несуществующие теги -> []',
       Dn1sup::Updater.compare_commits('dn1test/dn1sup_time_project', 'v9.9.9', 'v0.0.1') == []

puts "\n#{$failed.zero? ? 'ALL TESTS PASSED' : "#{$failed} FAILED"}"
exit($failed.zero? ? 0 : 1)
