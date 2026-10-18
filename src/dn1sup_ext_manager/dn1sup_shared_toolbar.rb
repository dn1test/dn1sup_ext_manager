# frozen_string_literal: true

# Общая панель инструментов DN1Sup: одна кнопка на расширение, состав
# настраивается в диалоге «Кнопки общей панели…» (меню DN1Sup → Extension
# Store). Кнопки вызывают главные действия расширений по стабильным
# модульным методам, поэтому чужие репозитории трогать не нужно; когда
# расширение не установлено (константа из check не определена), кнопка
# просто не добавляется.
#
# Ограничение SketchUp API: удалять кнопки из тулбара нельзя. Поэтому
# включение кнопки применяется сразу (панель скрывается, недостающие
# кнопки добавляются, панель возвращается на место), а отключённые
# пропадают только после перезапуска SketchUp — содержимое тулбаров не
# переживает рестарт, при старте панель собирается только из включённых.
# Старые индивидуальные тулбары «DN1Sup …» при этом скрываются
# (отключается в том же диалоге), чтобы кнопки не дублировались.
module Dn1sup
  module SharedToolbar
    TOOLBAR_NAME = 'DN1Sup'
    # Настройки — в секции менеджера, ключи отдельные. Списки хранятся CSV
    # (JSON-строки write_default не переживает: читаются обратно как nil),
    # по образцу hidden_repos менеджера.
    PREFS_SECTION      = 'DN1Sup ExtManager'
    PREFS_KEY_ON       = 'shared_toolbar_on'
    PREFS_KEY_OFF      = 'shared_toolbar_off'
    PREFS_KEY_SHOW_OLD = 'shared_toolbar_show_individual'

    MGR_DIR = File.dirname(__FILE__).freeze

    # Индивидуальные тулбары расширений (имена из их TOOLBAR_NAME); мост
    # тулбара не создаёт. Общая панель «DN1Sup» сюда не входит.
    INDIVIDUAL_TOOLBARS = [
      'DN1Sup Extension Store',
      'DN1Sup AutoSelect Tag',
      'DN1Sup Comp Add View',
      'DN1Sup Create Project',
      'Web 3D Export',
      'DN1Sup Export PDF 2',
      'DN1Sup Save Settings',
      'DN1Sup SketchUp Profiles',
      'DN1Sup Time Project'
    ].freeze

    # Кнопки: id — ключ настройки; check — константа, по наличию которой
    # определяется установленное расширение; call — действие кнопки;
    # small/large — шаблоны иконок: абсолютные пути (иконки менеджера) или
    # glob относительно корня Plugins (иконки самих расширений); если ничего
    # не нашлось — фирменная плитка icons/products/<fallback_base>_<16|24>.png
    # из папки менеджера. Второстепенные действия — default: false.
    BUTTONS = [
      {
        id: 'dn1sup_ext_manager',
        title: 'Каталог расширений',
        tooltip: 'DN1Sup Extension Store — каталог, установка и обновление расширений',
        default: true,
        check: 'Dn1sup::ExtManager',
        call: -> { Dn1sup::ExtManager.open_store },
        small: ["#{MGR_DIR}/icons/store.svg", "#{MGR_DIR}/icons/store_16.png"],
        large: ["#{MGR_DIR}/icons/store.svg", "#{MGR_DIR}/icons/store_24.png"]
      },
      {
        id: 'dn1sup_autoselect_tag',
        title: 'AutoSelect Tag',
        tooltip: 'DN1Sup AutoSelect Tag — настройки правил автотегов',
        default: true,
        check: 'Dn1sup::AutoSelectTag',
        call: -> { Dn1sup::AutoSelectTag::SettingsDialog.show },
        small: ['dn1sup_autoselect_tag/**/tag.svg', 'dn1sup_autoselect_tag/**/tag_16.png'],
        large: ['dn1sup_autoselect_tag/**/tag.svg', 'dn1sup_autoselect_tag/**/tag_24.png']
      },
      {
        id: 'dn1sup_autoselect_tag__apply',
        title: 'Применить правила тегов',
        tooltip: 'DN1Sup AutoSelect Tag — применить правила к текущей модели',
        default: false,
        check: 'Dn1sup::AutoSelectTag',
        call: -> { Dn1sup::AutoSelectTag.apply_rules_to_model },
        small: ['dn1sup_autoselect_tag/**/tag.svg', 'dn1sup_autoselect_tag/**/tag_16.png'],
        large: ['dn1sup_autoselect_tag/**/tag.svg', 'dn1sup_autoselect_tag/**/tag_24.png']
      },
      {
        id: 'dn1sup_comp_add_view',
        title: 'Comp Add View',
        tooltip: 'DN1Sup Comp Add View — панель видов и поворота компонентов',
        default: true,
        check: 'CustomTools::ComponentAddViews',
        call: -> { CustomTools::ComponentAddViews::Panel.show },
        small: ['dn1sup_comp_add_view/**/panel.svg', 'dn1sup_comp_add_view/**/panel_16.png'],
        large: ['dn1sup_comp_add_view/**/panel.svg', 'dn1sup_comp_add_view/**/panel_24.png']
      },
      {
        id: 'dn1sup_create_project',
        title: 'Создать проект',
        tooltip: 'DN1Sup Create Project — создание проекта',
        default: true,
        check: 'Dn1supCreateProject',
        call: -> { Dn1supCreateProject.show_dialog },
        small: ['dn1sup_create_project/**/cp.svg', 'dn1sup_create_project/**/cp_16.png'],
        large: ['dn1sup_create_project/**/cp.svg', 'dn1sup_create_project/**/cp_24.png']
      },
      {
        id: 'dn1sup_export_3d',
        title: 'Экспорт в GLB',
        tooltip: 'DN1Sup Export 3D — экспорт модели или выделения в GLB',
        default: true,
        check: 'Dn1supExport3d',
        call: -> { Dn1supExport3d::ExportDialog.show },
        small: ['dn1sup_export_3d/**/export_16.png', 'dn1sup_export_3d/**/export*.svg'],
        large: ['dn1sup_export_3d/**/export_24.png', 'dn1sup_export_3d/**/export*.svg']
      },
      {
        id: 'dn1sup_export_pdf2',
        title: 'Экспорт в PDF',
        tooltip: 'DN1Sup Export PDF 2 — диалог экспорта сцен в PDF',
        default: true,
        check: 'DN1Code::ExportPdf2',
        call: -> { DN1Code::ExportPdf2.open_export_dialog },
        small: ['dn1sup_export_pdf2/**/export_dialog.png', 'dn1sup_export_pdf2/**/export_dialog.svg'],
        large: ['dn1sup_export_pdf2/**/export_dialog_large.png', 'dn1sup_export_pdf2/**/export_dialog.svg']
      },
      {
        id: 'dn1sup_export_pdf2__quick',
        title: 'Быстрый экспорт PDF',
        tooltip: 'DN1Sup Export PDF 2 — быстрый экспорт всех сцен в PDF',
        default: false,
        check: 'DN1Code::ExportPdf2',
        call: -> { DN1Code::ExportPdf2.quick_export },
        small: ['dn1sup_export_pdf2/**/quick_export.png', 'dn1sup_export_pdf2/**/quick_export.svg'],
        large: ['dn1sup_export_pdf2/**/quick_export_large.png', 'dn1sup_export_pdf2/**/quick_export.svg'],
        fallback_base: 'dn1sup_export_pdf2__quick_export'
      },
      {
        id: 'dn1sup_save_settings',
        title: 'Сохранение настроек',
        tooltip: 'DN1Sup Save Settings — резервная копия настроек SketchUp',
        default: true,
        check: 'Dn1supSaveSettings',
        call: -> { Dn1supSaveSettings.show_dialog },
        small: ['dn1sup_save_settings/**/ss.svg', 'dn1sup_save_settings/**/ss_16.png'],
        large: ['dn1sup_save_settings/**/ss.svg', 'dn1sup_save_settings/**/ss_24.png']
      },
      {
        id: 'dn1sup_sketchup_profiles',
        title: 'Профили SketchUp',
        tooltip: 'DN1Sup SketchUp Profiles — сохранение и применение профилей настроек',
        default: true,
        check: 'Dn1sup::SketchupProfiles',
        call: -> { Dn1sup::SketchupProfiles.send(:open_dialog) },
        small: ['dn1sup_sketchup_profiles/**/profiles.svg', 'dn1sup_sketchup_profiles/**/profiles_16.png'],
        large: ['dn1sup_sketchup_profiles/**/profiles.svg', 'dn1sup_sketchup_profiles/**/profiles_24.png']
      },
      {
        id: 'dn1sup_time_project',
        title: 'Статистика времени',
        tooltip: 'DN1Sup Time Project — учёт времени работы с моделью',
        default: true,
        check: 'Dn1supTimeProject',
        call: -> { Dn1supTimeProject.show_dialog },
        small: ['dn1sup_time_project/**/timer.svg', 'dn1sup_time_project/**/timer_16.png'],
        large: ['dn1sup_time_project/**/timer.svg', 'dn1sup_time_project/**/timer_24.png']
      },
      {
        id: 'dn1sup_mcp2_bridge',
        title: 'Панель моста',
        tooltip: 'DN1Sup MCP Bridge — панель истории обращений (инструмент разработки)',
        default: false,
        check: 'Dn1supMcp2',
        call: -> { Dn1supMcp2.show_panel },
        small: [],
        large: [],
        fallback_base: nil
      }
    ].freeze

    @built = false
    @dialog = nil

    module_function

    # Точка входа для стартового таймера: все плагины к этому моменту
    # загружены, доступность констант актуальна.
    def startup
      build_toolbar!
      hide_individual_toolbars!
    rescue StandardError => e
      log(e)
    end

    # ---- Настройки ---------------------------------------------------------

    # Пользовательские переопределения — два списка id: явно включённые и
    # явно отключённые; id вне списков берёт default кнопки.
    def save!(enabled, show_old)
      enabled ||= {}
      write_csv(PREFS_KEY_ON,  enabled.map { |id, v| id.to_s if v == true }.compact)
      write_csv(PREFS_KEY_OFF, enabled.map { |id, v| id.to_s if v == false }.compact)
      Sketchup.write_default(PREFS_SECTION, PREFS_KEY_SHOW_OLD, show_old ? true : false)
      apply_settings!
      apply_individual_visibility!
      true
    rescue StandardError => e
      log(e)
      false
    end

    def enabled?(defn)
      id = defn[:id].to_s
      return false if read_csv(PREFS_KEY_OFF).include?(id)
      return true if read_csv(PREFS_KEY_ON).include?(id)

      defn.fetch(:default, false)
    end

    def show_individual?
      val = Sketchup.read_default(PREFS_SECTION, PREFS_KEY_SHOW_OLD)
      val.nil? ? false : (val == true || val == 'true')
    rescue StandardError
      false
    end

    def read_csv(key)
      raw = Sketchup.read_default(PREFS_SECTION, key)
      raw.is_a?(String) ? raw.split(',').map(&:to_s) : []
    rescue StandardError
      []
    end

    def write_csv(key, ids)
      Sketchup.write_default(PREFS_SECTION, key, Array(ids).empty? ? nil : Array(ids).join(','))
    end

    def available?(defn)
      !!(Kernel.eval("defined?(#{defn.fetch(:check)})"))
    rescue StandardError, ScriptError
      false
    end

    # ---- Построение панели -------------------------------------------------

    def build_toolbar!
      return false if @built
      return false unless defined?(UI::Command) && defined?(UI::Toolbar)

      tb = UI::Toolbar.new(TOOLBAR_NAME)
      add_enabled_buttons(tb)
      @built = true
      # restore показывает панель, если пользователь не прятал её в прошлой
      # сессии (TB_HIDDEN = 0; для TB_NEVER_SHOWN панель показываем — это
      # первый запуск после установки).
      tb.restore if tb.respond_to?(:get_last_state) && tb.get_last_state != 0
      true
    rescue StandardError => e
      log(e)
      false
    end

    # Применение изменений состава после сохранения: включённые кнопки
    # добавляются сразу, отключённые остаются до перезапуска (API не умеет
    # удалять кнопки).
    def apply_settings!
      return false unless @built && defined?(UI::Toolbar)

      tb = UI::Toolbar.new(TOOLBAR_NAME)
      was_visible = tb.respond_to?(:visible?) ? tb.visible? : false
      tb.hide if was_visible
      add_enabled_buttons(tb)
      tb.restore if was_visible
      true
    rescue StandardError => e
      log(e)
      false
    end

    # ---- Индивидуальные тулбары --------------------------------------------

    def hide_individual_toolbars!
      return false if show_individual?
      return false unless defined?(UI::Toolbar)

      INDIVIDUAL_TOOLBARS.each do |name|
        tb = UI::Toolbar.new(name)
        tb.hide if tb.respond_to?(:visible?) && tb.visible?
      end
      true
    rescue StandardError => e
      log(e)
      false
    end

    def apply_individual_visibility!
      return false unless defined?(UI::Toolbar)

      if show_individual?
        INDIVIDUAL_TOOLBARS.each do |name|
          tb = UI::Toolbar.new(name)
          tb.show if tb.respond_to?(:show)
        end
      else
        hide_individual_toolbars!
      end
      true
    rescue StandardError => e
      log(e)
      false
    end

    # ---- Диалог настроек ----------------------------------------------------

    def open_settings_dialog
      return false unless defined?(UI::HtmlDialog)

      close_settings_dialog
      dlg = UI::HtmlDialog.new(
        dialog_title: 'Кнопки панели DN1Sup',
        preferences_key: 'dn1sup_ext_manager_toolbar_settings',
        scrollable: true,
        resizable: true,
        width: 480,
        height: 640,
        min_width: 400,
        min_height: 460
      )
      dlg.add_action_callback('call_ruby') { |_context, name, param| dialog_dispatch(dlg, name.to_s, param.to_s) }
      dlg.set_file(File.join(MGR_DIR, 'html', 'toolbar_settings.html'))
      @dialog = dlg
      dlg.show
      true
    rescue StandardError => e
      log(e)
      false
    end

    def dialog_dispatch(dlg, name, param)
      case name
      when 'ready'
        push_state(dlg)
      when 'save'
        data = begin
          JSON.parse(param.to_s.empty? ? '{}' : param)
        rescue StandardError
          {}
        end
        save!(data['buttons'].is_a?(Hash) ? data['buttons'] : {}, data['show_old'] == true)
        dlg.execute_script('window.applySaved && window.applySaved(true);')
      when 'close'
        close_settings_dialog
      end
    rescue StandardError => e
      log(e)
    end

    def close_settings_dialog
      dlg = @dialog
      @dialog = nil
      dlg.close if dlg
      true
    rescue StandardError
      nil
    end

    # ---- Внутреннее ---------------------------------------------------------

    def add_enabled_buttons(tb)
      present = existing_tooltips(tb)
      BUTTONS.each do |defn|
        next if present[defn[:tooltip]]
        next unless enabled?(defn) && available?(defn)

        add_button(tb, defn)
      end
    end

    # Тулбар перечислим (Enumerable#each): элементы — UI::Command, разделители
    # приходят строкой '|'. Дедупликация по tooltip (стандартный приём).
    def existing_tooltips(tb)
      set = {}
      tb.each { |c| set[c.tooltip] = true if c.respond_to?(:tooltip) }
      set
    rescue StandardError
      {}
    end

    def add_button(tb, defn)
      cmd = UI::Command.new(defn[:title]) { invoke(defn) }
      cmd.tooltip = defn[:tooltip]
      cmd.status_bar_text = defn[:tooltip]
      small = icon_for(defn, :small)
      large = icon_for(defn, :large)
      cmd.small_icon = small if small
      cmd.large_icon = large || small if large || small
      tb.add_item(cmd)
    rescue StandardError => e
      log(e)
    end

    def invoke(defn)
      defn[:call].call
    rescue StandardError, ScriptError => e
      msg = "DN1Sup: не удалось открыть «#{defn[:title]}».\n#{e.class}: #{e.message}"
      defined?(UI) ? UI.messagebox(msg) : nil
      log(e)
    end

    def plugins_root
      File.expand_path('..', MGR_DIR)
    end

    def svg_icons_supported?
      Sketchup.respond_to?(:version) && Sketchup.version.to_f >= 20.1
    rescue StandardError
      false
    end

    # Разрешение иконки: шаблоны проверяются по порядку, абсолютные пути —
    # как есть, относительные — от корня Plugins. SVG пропускается на старых
    # SketchUp (< 2020.1). Фолбэк — фирменная плитка менеджера.
    def icon_for(defn, key)
      allow_svg = svg_icons_supported?
      Array(defn[key]).each do |pat|
        full = File.absolute_path?(pat) ? pat : File.join(plugins_root, pat)
        Dir.glob(full).sort.each do |hit|
          next if !allow_svg && hit.downcase.end_with?('.svg')

          return hit
        end
      end
      fallback_tile(defn, key)
    end

    def fallback_tile(defn, key)
      base = defn.fetch(:fallback_base, defn[:id])
      return nil if base.nil?

      size = key == :small ? 16 : 24
      path = File.join(MGR_DIR, 'icons', 'products', "#{base}_#{size}.png")
      File.file?(path) ? path : nil
    end

    def push_state(dlg)
      payload = {
        buttons: BUTTONS.map do |defn|
          {
            id: defn[:id],
            title: defn[:title],
            tooltip: defn[:tooltip],
            default: defn.fetch(:default, false),
            available: available?(defn),
            enabled: enabled?(defn)
          }
        end,
        show_old: show_individual?
      }
      dlg.execute_script("window.applyState(#{JSON.generate(payload)});")
    rescue StandardError => e
      log(e)
    end

    def log(err)
      return unless defined?(Dn1sup::Updater) && Dn1sup::Updater.respond_to?(:log_error)

      Dn1sup::Updater.log_error(err)
    rescue StandardError
      nil
    end
  end
end
