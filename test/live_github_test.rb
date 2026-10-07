$stdout.sync = true
$stderr.sync = true

require 'net/http'
require 'json'
require 'tmpdir'

REPO = 'dn1test/dn1sup_ext_manager'
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
    def initialize(*); end

    def any?(*); false; end
    def add_item(*); self; end
    def restore(*);  self; end
  end
end
def file_loaded?(_); false; end
def file_loaded(_); true; end

require_relative '../shared/dn1sup_updater'
require_relative '../src/dn1sup_ext_manager/main'

# 1. Проверка сырого файла registry.json на GitHub
raw_reg = Dn1sup::Updater.fetch_text("https://raw.githubusercontent.com/#{REPO}/main/registry.json")
assert 'registry.json доступен по raw-ссылке', !raw_reg.to_s.empty?
reg_data = JSON.parse(raw_reg) rescue []
assert 'registry.json содержит 4 расширения', reg_data.is_a?(Array) && reg_data.size == 4

target_entry = reg_data.find { |e| e.is_a?(Hash) && e['id'] == 'dn1sup_time_project2' }
target_ver = target_entry && target_entry['version'].to_s
assert 'registry содержит dn1sup_time_project2 с версией', !target_ver.empty?, target_ver

# 2. Проверка GitHub Releases API (тег монорепо — общий, формат vX.Y.Z)
release = Dn1sup::Updater.latest_release(REPO)
assert 'latest_release возвращает релиз', release.is_a?(Hash) && release['tag_name'] =~ /\Av\d+\.\d+\.\d+\z/, release['tag_name'].to_s
assets = release['assets'] || []
assert 'релиз содержит 4 .rbz ассета', assets.size == 4

# 3. Проверка постоянных ссылок на скачивание (latest/download/*.rbz)
(assets.map { |a| a['name'].delete_suffix('.rbz') }).each do |id|
  asset_name = "#{id}.rbz"
  asset_url = Dn1sup::Updater.asset_url(release, asset_name)
  assert "asset_url найден для #{asset_name}", !asset_url.empty?, asset_url

  download_dest = File.join(Dir.tmpdir, "live_#{asset_name}")
  saved = Dn1sup::Updater.download(asset_url, download_dest)
  size_str = saved && File.file?(saved) ? "#{File.size(saved)} bytes" : 'download failed'
  assert "скачивание #{asset_name} успешно", saved && File.file?(saved), size_str
  assert "файл #{asset_name} валидный .rbz", Dn1sup::Updater.rbz?(saved)
  File.delete(saved) if saved && File.file?(saved)
end

# 4. Проверка Updater: старая локальная версия → предлагается версия из registry.json
summary = Dn1sup::Updater.check!(
  id: 'dn1sup_time_project2',
  repo: REPO,
  version: '0.0.1',
  asset: 'dn1sup_time_project2.rbz',
  force: true,
  silent: true
)
assert "Updater находит обновление #{target_ver} при старой версии", summary.is_a?(Hash) && summary[:latest] == target_ver

# 5. Проверка Updater: актуальная версия расширения (из registry.json) → nil
current_summary = Dn1sup::Updater.check!(
  id: 'dn1sup_time_project2',
  repo: REPO,
  version: target_ver,
  asset: 'dn1sup_time_project2.rbz',
  force: true,
  silent: true
)
assert 'Updater понимает, что версия из registry уже актуальна (возвращает nil)', current_summary.nil?

# 6. Проверка ExtManager::load_registry
loaded_reg = Dn1sup::ExtManager.load_registry
assert 'ExtManager успешно загружает реестр', loaded_reg.is_a?(Array) && loaded_reg.size >= 4

puts "\n#{$failed.zero? ? 'ВСЕ ЖИВЫЕ ТЕСТЫ С GITHUB УСПЕШНО ПРОЙДЕНЫ!' : "#{$failed} ТЕСТОВ ПРОВАЛЕНО"}"
exit($failed.zero? ? 0 : 1)
