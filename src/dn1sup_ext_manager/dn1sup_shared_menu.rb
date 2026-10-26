# frozen_string_literal: true

# Настраиваемые меню DN1Sup: пользователь собирает свои подменю внутри
# общего меню DN1Sup (Dn1sup.common_menu) из команд установленных
# расширений. Источник команд — таблица SharedToolbar::BUTTONS
# (check/call), поэтому чужие репозитории трогать не нужно.
#
# Ограничение SketchUp API: пункты меню нельзя удалить в рантайме.
# Поэтому сохранённый конфиг применяется при следующем старте SketchUp
# (как отключённые кнопки тулбара). Сохранение из GUI показывает
# уведомление о необходимости перезапуска.
module Dn1sup
  module SharedMenu
    MGR_DIR     = File.dirname(__FILE__).freeze
    CONFIG_PATH = File.join(MGR_DIR, 'data', 'menu_config.json').freeze
    SEP         = '__sep__'

    MAX_MENUS = 10
    MAX_ITEMS = 20

    @built = false
    @startup_timer_id = nil

    module_function

    # ---- Конфиг ------------------------------------------------------------

    def default_config
      { 'menus' => [] }
    end

    def load_config
      raw = File.read(CONFIG_PATH, encoding: 'UTF-8')
      data = JSON.parse(raw)
      menus = data.is_a?(Hash) ? data['menus'] : data
      { 'menus' => sanitize_menus(menus) }
    rescue StandardError, ScriptError
      default_config
    end

    def save_config(config)
      menus = config.is_a?(Hash) ? (config['menus'] || config[:menus]) : config
      clean = { 'menus' => sanitize_menus(menus) }
      FileUtils.mkdir_p(File.dirname(CONFIG_PATH))
      File.write(CONFIG_PATH, JSON.pretty_generate(clean) + "\n")
      true
    rescue StandardError => e
      log(e)
      false
    end

    def reset_config
      FileUtils.rm_f(CONFIG_PATH)
      true
    rescue StandardError => e
      log(e)
      false
    end

    def sanitize_menus(menus)
      list = Array(menus).first(MAX_MENUS).map do |m|
        id = (m.is_a?(Hash) ? (m['id'] || m[:id]) : nil).to_s.strip
        title = (m.is_a?(Hash) ? (m['title'] || m[:title]) : nil).to_s.strip
        items = m.is_a?(Hash) ? (m['items'] || m[:items]) : nil
        next if title.empty?

        clean_items = Array(items).first(MAX_ITEMS).filter_map do |it|
          s = it.to_s
          next SEP if s == SEP || s == '---' || s == 'separator'

          s if known_command_id?(s)
        end
        # Убираем дублирующиеся и краевые разделители.
        clean_items = clean_items.chunk { |x| x == SEP ? :sep : :item }.flat_map do |k, g|
          k == :sep ? [SEP] : g
        end
        clean_items.shift while clean_items.first == SEP
        clean_items.pop while clean_items.last == SEP
        next if clean_items.empty?

        { 'id' => (id.empty? ? "menu_#{title.hash.abs % 100_000}" : id[0, 64]),
          'title' => title[0, 64], 'items' => clean_items }
      end.compact
      list
    end

    def known_command_id?(id)
      return false unless defined?(Dn1sup::SharedToolbar)

      Dn1sup::SharedToolbar::BUTTONS.any? { |d| d[:id].to_s == id.to_s }
    end

    def find_command(id)
      return nil unless defined?(Dn1sup::SharedToolbar)

      Dn1sup::SharedToolbar::BUTTONS.find { |d| d[:id].to_s == id.to_s }
    end

    # ---- Payload для JS ----------------------------------------------------

    def menu_payload
      cmds = []
      if defined?(Dn1sup::SharedToolbar)
        cmds = Dn1sup::SharedToolbar::BUTTONS.map do |d|
          { 'id' => d[:id].to_s, 'title' => d[:title].to_s,
            'tooltip' => d[:tooltip].to_s, 'available' => available?(d) }
        end
      end
      { 'menus' => load_config['menus'], 'commands' => cmds }
    rescue StandardError => e
      log(e)
      { 'menus' => [], 'commands' => [] }
    end

    def available?(defn)
      return false unless defined?(Dn1sup::SharedToolbar)

      Dn1sup::SharedToolbar.available?(defn)
    rescue StandardError
      false
    end

    # ---- Построение меню при старте ----------------------------------------

    def startup_when_ready
      return if @built || @startup_timer_id
      return build_menus! unless defined?(UI) && UI.respond_to?(:start_timer)

      prev = nil
      stable = 0
      deadline = Time.now + Dn1sup::SharedToolbar::STARTUP_MAX_SECONDS
      interval = Dn1sup::SharedToolbar::STARTUP_POLL_INTERVAL
      ticks = Dn1sup::SharedToolbar::STARTUP_STABLE_TICKS
      @startup_timer_id = UI.start_timer(interval, true) do
        ids = commands_snapshot
        stable = ids == prev ? stable + 1 : 0
        prev = ids
        next unless stable >= ticks || Time.now >= deadline

        stop_startup_timer!
        build_menus!
      end
    rescue StandardError => e
      log(e)
    end

    def stop_startup_timer!
      return unless @startup_timer_id

      UI.stop_timer(@startup_timer_id)
      @startup_timer_id = nil
    rescue StandardError
      @startup_timer_id = nil
    end

    def commands_snapshot
      return [] unless defined?(Dn1sup::SharedToolbar)

      Dn1sup::SharedToolbar::BUTTONS.select { |d| available?(d) }.map { |d| d[:id].to_s }.sort
    rescue StandardError
      []
    end

    def build_menus!
      return false if @built
      return false unless defined?(Dn1sup) && Dn1sup.respond_to?(:common_menu)

      menus = load_config['menus']
      return (@built = true) if menus.empty?

      common = Dn1sup.common_menu
      menus.each do |m|
        title = m['title'].to_s
        next if title.empty?

        begin
          sub = common.add_submenu(title)
          Array(m['items']).each do |item_id|
            if item_id.to_s == SEP
              sub.add_separator
              next
            end
            defn = find_command(item_id)
            next unless defn && available?(defn)

            cmd = menu_command(defn)
            sub.add_item(cmd) if cmd
          end
        rescue StandardError => e
          log(e)
          next
        end
      end
      @built = true
      true
    rescue StandardError => e
      log(e)
      false
    end

    def menu_command(defn)
      return nil unless defined?(UI::Command)

      cmd = UI::Command.new(defn[:title].to_s) { invoke(defn) }
      cmd.menu_text = defn[:title].to_s
      cmd.tooltip = defn[:tooltip].to_s
      cmd.status_bar_text = defn[:tooltip].to_s
      cmd
    rescue StandardError => e
      log(e)
      nil
    end

    def invoke(defn)
      defn[:call].call
    rescue StandardError, ScriptError => e
      msg = "DN1Sup: не удалось открыть «#{defn[:title]}».\n#{e.class}: #{e.message}"
      defined?(UI) ? UI.messagebox(msg) : nil
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
