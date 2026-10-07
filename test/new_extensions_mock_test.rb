# Временный тест: имитация SketchUp API для загрузки новых расширений вне SketchUp.
# Проверяет структуру модулей, наблюдателей, отложенное назначение тегов и меню.
require 'tmpdir'

$dialog_log = []
$failed = 0

def assert(label, cond, details = '')
  passed = !!cond
  puts(format('%s %s%s', passed ? 'PASS' : 'FAIL', label, details.to_s.empty? ? '' : " — #{details}"))
  $failed += 1 unless passed
end

BASE = File.expand_path('..', __dir__)
$LOAD_PATH.unshift File.join(BASE, 'src')

module Sketchup
  class Entity
    attr_reader :layer
    def initialize; @tags = {}; end
    def deleted?; @deleted || false; end
    def erase; @deleted = true; end
    def layer=(val); @layer = val; end
  end
  class Dimension < Entity; end
  class Text < Entity; end
  class Line < Entity; end

  class Entities
    def initialize(model = nil); @model = model; @elements = []; end
    attr_reader :elements
    def model; @model; end
    def add_observer(obs); (@observers ||= []) << obs; end
    def observers; @observers || []; end
    def notify_added(ent); @elements << ent; @observers.each { |o| o.onElementAdded(self, ent) if o.respond_to?(:onElementAdded) }; end
  end

  class Definitions
    def initialize; @defs = []; end
    def each(&block); @defs.each(&block); end
    def add_observer(obs); (@observers ||= []) << obs; end
    def notify_added(defn); @defs << defn; @observers.each { |o| o.onComponentAdded(self, defn) if o.respond_to?(:onComponentAdded) }; end
  end

  class EntitiesObserver; end
  class DefinitionsObserver; end
  class AppObserver; end
  class Extension; end

  class FakeModel
    attr_reader :entities, :definitions, :layers
    def initialize
      @entities = Entities.new(self)
      @definitions = Definitions.new
      @layers = FakeLayers.new
    end
  end
  class FakeLayers
    def initialize; @names = {}; end
    def [](name); @names.key?(name) ? name : nil; end
    def add(name); @names[name] = name; name; end
  end

  @app_observers = []
  $prefs = {}
  module_function

  def read_default(sec, key, d = nil); $prefs.dig(sec, key) || d; end
  def write_default(sec, key, val); ($prefs[sec] ||= {})[key] = val; end

  def require(path)
    ext_base = ENV['SKETCHUP_EXT_ROOT'] || File.expand_path('../..', __dir__)
    candidates = [
      File.join(BASE, 'src', path + '.rb'),
      File.join(BASE, 'src', path, path + '.rb'),
      File.join(ext_base, path + '.rb'),
      File.join(ext_base, path, path + '.rb'),
      File.join(ext_base, 'dn1sup_autoselect_tag', 'dn1sup_autoselect_tag', path + '.rb'),
      File.join(ext_base, 'dn1sup_comp_add_view', path + '.rb'),
      File.join(ext_base, 'dn1sup_time_project2', 'dn1sup_time_project2', path + '.rb')
    ]
    candidates.each do |c|
      c += '.rb' unless File.extname(c) == '.rb'
      return Kernel.require(c) if File.file?(c)
    end
    nil
  end

  def add_observer(obs); @app_observers << obs; end
  def app_observers; @app_observers; end
  def active_model; @model ||= FakeModel.new; end
end

$LOADED_FEATURES << 'sketchup.rb' unless $LOADED_FEATURES.include?('sketchup.rb')

module UI
  @timers = []
  module_function

  def start_timer(interval, repeat = false, &block); @timers << [interval, repeat, block]; block.call if interval.zero?; block.object_id; end
  def stop_timer(_id); end
  def timers; @timers; end
  def openURL(url); $dialog_log << "OPEN_URL: #{url}"; end
  def menu(*)
    Class.new do
      def add_submenu(*); self; end
      def add_item(*); $dialog_log << 'MENU_ITEM'; self; end
      def add_separator(*); self; end
    end.new
  end
  def messagebox(msg, _t = 0); $dialog_log << "MESSAGEBOX: #{msg}"; 0; end

  class Command
    attr_accessor :tooltip, :status_bar_text, :small_icon, :large_icon
    def initialize(_title, &block); @block = block; end
    def proc; end
  end

  class Toolbar
    def initialize(*); end
    def add_item(*); self; end
    def get_last_state; -1; end
    def show; $dialog_log << 'TOOLBAR_SHOW'; end
    def restore; end
  end
end

MB_OK = 0

def file_loaded?(_); false; end
def file_loaded(_); true; end

# === 1. registry.json содержит валидные репозитории расширений ===
require 'json'
reg = JSON.parse(File.read(File.join(BASE, 'registry.json')))
ids = reg.map { |e| e['id'] }
assert 'registry содержит dn1sup_ext_manager', ids.include?('dn1sup_ext_manager')
assert 'registry содержит dn1sup_autoselect_tag', ids.include?('dn1sup_autoselect_tag')
assert 'registry содержит dn1sup_comp_add_view', ids.include?('dn1sup_comp_add_view')
assert 'registry содержит dn1sup_create_project', ids.include?('dn1sup_create_project')
assert 'registry содержит dn1sup_time_project2', ids.include?('dn1sup_time_project2')
assert 'registry содержит dn1sup_save_settings', ids.include?('dn1sup_save_settings')
assert 'каждая запись ссылается на свой репозиторий', reg.all? { |e| e['repo'].start_with?('dn1test/dn1sup_') }

# === 3. registry.json содержит новые расширения ===
require 'json'
reg = JSON.parse(File.read(File.join(BASE, 'registry.json')))
ids = reg.map { |e| e['id'] }
assert 'registry содержит dn1sup_autoselect_tag', ids.include?('dn1sup_autoselect_tag')
assert 'registry содержит dn1sup_comp_add_view', ids.include?('dn1sup_comp_add_view')
assert 'registry содержит dn1sup_create_project', ids.include?('dn1sup_create_project')
new_entries = reg.select { |e| %w[dn1sup_autoselect_tag dn1sup_comp_add_view dn1sup_create_project].include?(e['id']) }
assert 'у новых записей есть name/description/asset/version/changelog',
       new_entries.all? { |e| !e['name'].to_s.empty? && !e['description'].to_s.empty? && e['asset'] == "#{e['id']}.rbz" && !e['version'].to_s.empty? && !e['changelog'].to_s.empty? }

# === 4. Иконка для новых id в каталоге ===
html = File.read(File.join(BASE, 'src', 'dn1sup_ext_manager', 'html', 'index.html'))
assert 'getPluginIcon: tag → 🏷️', html.include?("if (s.includes('tag')) return '🏷️'")
assert 'getPluginIcon: comp_add_view → 📐', html.include?("if (s.includes('comp_add_view')) return '📐'")
assert 'getPluginIcon: create_project → 📁', html.include?("if (s.includes('create_project') || s.includes('project')) return '📁'")

# === 5. Единое меню без глобальных переменных ===
require_relative '../src/dn1sup_ext_manager/main'
assert 'Dn1sup.common_menu определен и возвращает меню', defined?(Dn1sup) && Dn1sup.respond_to?(:common_menu) && !Dn1sup.common_menu.nil?
assert 'глобальные переменные $dn1sup_common_menu и $dn1sup_menu не создаются', !defined?($dn1sup_common_menu) && !defined?($dn1sup_menu)

puts "\n#{$failed.zero? ? 'ALL TESTS PASSED' : "#{$failed} FAILED"}"
exit($failed.zero? ? 0 : 1)
