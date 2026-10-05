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

# === 1. dn1sup_autoselect_tag ===
ext_base = ENV['SKETCHUP_EXT_ROOT'] || File.expand_path('../..', __dir__)
tag_main = [
  File.join(ext_base, 'dn1sup_autoselect_tag', 'dn1sup_autoselect_tag', 'dn1sup_autoselect_tag', 'main.rb'),
  File.join(ext_base, 'dn1sup_autoselect_tag', 'dn1sup_autoselect_tag', 'main.rb')
].find { |f| File.file?(f) }

if tag_main
  require tag_main
  M = Dn1sup::AutoSelectTag
  assert 'константы расширения autoselect_tag', M::ID == 'dn1sup_autoselect_tag' && M::REPO == 'dn1test/sketchup-dn1sup-extensions'
  assert 'установлен AppObserver', Sketchup.app_observers.size == 1
  assert 'наблюдатель сущностей подключён к модели', Sketchup.active_model.entities.observers.size == 1

  # Отложенное назначение тега через таймер
  dim = Sketchup::Dimension.new
  Sketchup.active_model.entities.notify_added(dim)
  assert 'Dimension получил тег Dimension после flush', dim.layer == 'Dimension'
  txt = Sketchup::Text.new
  Sketchup.active_model.entities.notify_added(txt)
  assert 'Text получил тег Label после flush', txt.layer == 'Label'
  line = Sketchup::Line.new
  Sketchup.active_model.entities.notify_added(line)
  assert 'Line не тегируется', line.layer.nil?

  # Отложенность: при нулевом интервале flush выполняется сразу после notify;
  # erase-элемент перед defer_assign пропускается
  before = UI.timers.size
  d2 = Sketchup::Dimension.new
  Sketchup.active_model.entities.notify_added(d2)
  assert 'Dimension тегируется при повторном добавлении (auto-flush)', d2.layer == 'Dimension'
  assert 'повторное подключение модели подавлено', Sketchup.active_model.entities.observers.size == 1
  d3 = Sketchup::Dimension.new
  d3.erase
  Dn1sup::AutoSelectTag.defer_assign(Sketchup.active_model, d3)
  assert 'erase перед flush пропускает тегирование', d3.layer.nil?

  # Компонент: onComponentAdded подключает наблюдатель сущностей определения
  defn_ents = Sketchup::Entities.new(Sketchup.active_model)
  defn = Struct.new(:entities).new(defn_ents)
  Sketchup.active_model.definitions.notify_added(defn)
  assert 'наблюдатель подключён к определению компонента', defn_ents.observers.size == 1
  dim_in_comp = Sketchup::Dimension.new
  defn_ents.notify_added(dim_in_comp)
  assert 'размер внутри компонента тегируется', dim_in_comp.layer == 'Dimension'
else
  puts 'SKIP autoselect_tag: внешняя папка не найдена'
end

# === 2. dn1sup_comp_add_view ===
comp_main = File.join(ext_base, 'dn1sup_comp_add_view', 'su_component_add_view', 'main.rb')
if File.file?(comp_main)
  require comp_main
  assert 'меню и тулбар зарегистрированы', $dialog_log.include?('MENU_ITEM') && $dialog_log.include?('TOOLBAR_SHOW')
  settings = CustomTools::ComponentAddViews::Settings.get_settings
  assert 'settings возвращает 5 значений', settings.is_a?(Array) && settings.size == 5, settings.inspect
  assert 'settings: side_view/offset валидны', %w[Справа Слева].include?(settings[3]) && !settings[4].to_s.empty?
else
  puts 'SKIP comp_add_view: внешняя папка не найдена'
end

# === 3. registry.json содержит оба новых расширения ===
require 'json'
reg = JSON.parse(File.read(File.join(BASE, 'registry.json')))
ids = reg.map { |e| e['id'] }
assert 'registry содержит dn1sup_autoselect_tag', ids.include?('dn1sup_autoselect_tag')
assert 'registry содержит dn1sup_comp_add_view', ids.include?('dn1sup_comp_add_view')
new_entries = reg.select { |e| %w[dn1sup_autoselect_tag dn1sup_comp_add_view].include?(e['id']) }
assert 'у новых записей есть name/description/asset/version/changelog',
       new_entries.all? { |e| !e['name'].to_s.empty? && !e['description'].to_s.empty? && e['asset'] == "#{e['id']}.rbz" && !e['version'].to_s.empty? && !e['changelog'].to_s.empty? }

# === 4. Иконка для новых id в каталоге ===
html = File.read(File.join(BASE, 'src', 'dn1sup_ext_manager', 'html', 'index.html'))
assert 'getPluginIcon: tag → 🏷️', html.include?("if (s.includes('tag')) return '🏷️'")
assert 'getPluginIcon: comp_add_view → 📐', html.include?("if (s.includes('comp_add_view')) return '📐'")

puts "\n#{$failed.zero? ? 'ALL TESTS PASSED' : "#{$failed} FAILED"}"
exit($failed.zero? ? 0 : 1)
