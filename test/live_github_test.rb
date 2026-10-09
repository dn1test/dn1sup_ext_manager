$stdout.sync = true
$stderr.sync = true

require 'net/http'
require 'json'
require 'tmpdir'

REPO = 'dn1test/dn1sup_ext_manager'
OWNER = 'dn1test'
CATALOG_IDS = %w[
  dn1sup_ext_manager
  dn1sup_time_project
  dn1sup_create_project
  dn1sup_autoselect_tag
  dn1sup_comp_add_view
  dn1sup_save_settings
].freeze
ENV['GITHUB_TOKEN'] ||= ENV['GH_TOKEN']
$failed = 0

def assert(label, cond, details = '')
  passed = !!cond
  puts(format('%s %s%s', passed ? 'PASS' : 'FAIL', label, details.to_s.empty? ? '' : " — #{details}"))
  $failed += 1 unless passed
end

puts "=== ТЕСТИРОВАНИЕ ОПУБЛИКОВАННОГО РЕПОЗИТОРИЯ: #{REPO} ==="

module Sketchup
  $prefs = {}
  module_function
  def read_default(sec, key, d = nil); $prefs.dig(sec, key) || d; end
  def write_default(sec, key, val); ($prefs[sec] ||= {})[key] = val; end
  def require(p); Kernel.require_relative("../src/#{p}"); end
end
module UI
  module_function
  def messagebox(*); 1; end
  def start_timer(*); end
  def menu(*); Class.new { def add_submenu(*); self; end; def add_item(*); self; end; def add_separator(*); self; end }.new; end

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
    def initialize(*); false; end

    def any?(*); false; end
    def add_item(*); self; end
    def restore(*);  self; end
  end
end
def file_loaded?(_); false; end
def file_loaded(_); true; end

require_relative '../shared/dn1sup_updater'
require_relative '../src/dn1sup_ext_manager/main'

# 1. Реестр каталога на GitHub (первичный список расширений)
raw_reg = Dn1sup::Updater.fetch_text("https://raw.githubusercontent.com/#{REPO}/main/registry.json")
assert 'registry.json доступен по raw-ссылке', !raw_reg.to_s.empty?
reg_data = JSON.parse(raw_reg) rescue []
assert "registry.json содержит #{CATALOG_IDS.size} расширений", reg_data.is_a?(Array) && reg_data.size >= CATALOG_IDS.size - 1, "#{reg_data.size} записей"
assert 'registry.json покрывает весь каталог',
       CATALOG_IDS.all? { |id| reg_data.any? { |e| e.is_a?(Hash) && e['id'] == id } }

# 2. Релиз менеджера и постоянная ссылка на скачивание
release = Dn1sup::Updater.latest_release(REPO)
assert 'latest_release возвращает релиз', release.is_a?(Hash) && release['tag_name'] =~ /\Av\d+\.\d+\.\d+\z/, release['tag_name'].to_s
rbz_asset = (release['assets'] || []).find { |a| a['name'].to_s.end_with?('.rbz') }
assert 'релиз содержит .rbz ассет менеджера', !!rbz_asset, rbz_asset && rbz_asset['name']
saved = Dn1sup::Updater.download(rbz_asset['browser_download_url'], File.join(Dir.tmpdir, 'live_manager.rbz'))
assert 'скачивание менеджера успешно', saved && File.file?(saved), saved && File.size(saved)
assert 'файл менеджера — валидный .rbz', Dn1sup::Updater.rbz?(saved)
File.delete(saved) if saved && File.file?(saved)

# 3. Автопоиск: репозитории аккаунта и их метаданные (по одному raw-запросу
# на репозиторий — так каталог достраивает карточки вне реестра)
owner_repos = Dn1sup::Updater.repos_of_owner(OWNER)
assert 'repos_of_owner находит репозитории аккаунта', owner_repos.is_a?(Array) && owner_repos.any?, "#{owner_repos.size} репозиториев"
full_names = owner_repos.map { |r| r['full_name'].to_s }
assert 'автопоиск покрывает весь каталог', CATALOG_IDS.all? { |id| full_names.include?("dn1test/#{id}") }, full_names.join(', ')

reg_entries = CATALOG_IDS.map do |id|
  entry = Dn1sup::Updater.registry_entry("dn1test/#{id}", id)
  assert "метаданные #{id} доступны (registry.json репозитория)", entry.is_a?(Hash) && !entry['name'].to_s.empty?
  entry
end

# 4. Релизы расширений: предлагаемый тег есть у каждого репозитория каталога
CATALOG_IDS.each do |id|
  list = Dn1sup::Updater.releases("dn1test/#{id}", per_page: 5)
  offered = Dn1sup::Updater.choose_release(list)
  assert "релизы #{id} доступны", offered.is_a?(Hash) && !offered['tag_name'].to_s.empty?, offered && offered['tag_name']
  rbz = Dn1sup::Updater.asset_url(offered, "#{id}.rbz")
  assert "в релизе #{id} есть .rbz ассет", !rbz.to_s.empty?
end

# 5. Проверка Updater: старая версия расширения → предлагается новая
tp_entry = reg_entries.find { |e| e['id'] == 'dn1sup_time_project' }
tp_ver = tp_entry && tp_entry['version'].to_s
assert 'registry dn1sup_time_project содержит версию', !tp_ver.to_s.empty?, tp_ver
summary = Dn1sup::Updater.check!(
  id: 'dn1sup_time_project',
  repo: 'dn1test/dn1sup_time_project',
  version: '0.0.1',
  asset: 'dn1sup_time_project.rbz',
  force: true,
  silent: true
)
assert "Updater находит обновление #{tp_ver} при старой версии", summary.is_a?(Hash) && summary[:latest] == tp_ver, summary && summary[:latest]
current_summary = Dn1sup::Updater.check!(
  id: 'dn1sup_time_project',
  repo: 'dn1test/dn1sup_time_project',
  version: tp_ver,
  asset: 'dn1sup_time_project.rbz',
  force: true,
  silent: true
)
assert 'Updater понимает, что версия уже актуальна (возвращает nil)', current_summary.nil?

# 6. Лог правок: коммиты между соседними тегами time_project
tp_list = Dn1sup::Updater.releases('dn1test/dn1sup_time_project', per_page: 10)
tags = tp_list.map { |r| r['tag_name'] }.uniq
if tags.size >= 2
  cmts = Dn1sup::Updater.compare_commits('dn1test/dn1sup_time_project', tags[1], tags[0], limit: 10)
  assert 'compare_commits возвращает лог правок между тегами', cmts.is_a?(Array) && cmts.any?, "#{cmts.size} коммитов"
else
  assert 'compare_commits: у репозитория есть минимум 2 тега', false, tags.join(', ')
end

# 7. ExtManager::load_registry
loaded_reg = Dn1sup::ExtManager.load_registry
assert 'ExtManager успешно загружает реестр', loaded_reg.is_a?(Array) && loaded_reg.size >= CATALOG_IDS.size - 1

puts "\n#{$failed.zero? ? 'ВСЕ ЖИВЫЕ ТЕСТЫ С GITHUB УСПЕШНО ПРОЙДЕНЫ!' : "#{$failed} ТЕСТОВ ПРОВАЛЕНО"}"
exit($failed.zero? ? 0 : 1)
