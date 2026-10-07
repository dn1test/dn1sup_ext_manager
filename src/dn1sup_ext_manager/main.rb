# frozen_string_literal: true

begin
  require 'sketchup.rb'
rescue LoadError
  # Outside SketchUp environment
end
require 'json'
require 'fileutils'
Sketchup.require 'dn1sup_ext_manager/dn1sup_updater'

module Dn1sup
  def self.common_menu
    @common_menu ||= begin
      legacy = (defined?($dn1sup_common_menu) && $dn1sup_common_menu) || (defined?($dn1sup_menu) && $dn1sup_menu)
      legacy || UI.menu('Extensions').add_submenu('DN1Sup')
    end
  end

  module ExtManager
    ID      = 'dn1sup_ext_manager'
    VERSION = '0.3.1'
    REPO    = 'dn1test/dn1sup_ext_manager'
    ASSET   = "#{ID}.rbz"
    PAGE_URL     = "https://github.com/#{REPO}/releases"
    REGISTRY_URL = "https://raw.githubusercontent.com/#{REPO}/main/registry.json"

    PLUGIN_DIR = File.dirname(__FILE__).freeze
    HTML_PATH  = File.join(PLUGIN_DIR, 'html', 'index.html').freeze

    @dialog = nil
    @release_cache = {}

    module_function

    # ---- Модель данных ----------------------------------------------------

    # registry.json -> [ { "id", "name", "description", "repo", "asset" }, ...]
    def registry_path
      File.join(PLUGIN_DIR, 'data', 'registry.json')
    end

    # Читает локальный реестр из .rbz; если файла нет — тянет с GitHub (raw).
    # Без UI-диалогов: метод вызывается в том числе из фонового потока,
    # пустой список каталог сам отрисует как empty-state.
    def load_registry
      raw = nil
      if File.file?(registry_path)
        begin
          raw = File.read(registry_path, encoding: 'UTF-8')
        rescue StandardError
          raw = File.read(registry_path)
        end
      end
      raw ||= Dn1sup::Updater.fetch_text(REGISTRY_URL)
      unless raw
        Dn1sup::Updater.log_error(RuntimeError.new("Реестр недоступен: ни #{registry_path}, ни #{REGISTRY_URL}"))
        return []
      end
      # Удаляем BOM, если присутствует
      raw = raw.sub(/\A\xEF\xBB\xBF/, '')
      list = JSON.parse(raw)
      list = list['extensions'] if list.is_a?(Hash) && list['extensions'].is_a?(Array)
      list.is_a?(Array) ? list.find_all { |e| e.is_a?(Hash) && !e['id'].to_s.empty? } : []
    rescue StandardError, ScriptError => e
      Dn1sup::Updater.log_error(e)
      []
    end

    # Проверяет, физически ли файл расширения существует в папке Plugins
    def extension_file_exists?(id)
      return false unless defined?(Sketchup)
      return true unless Sketchup.respond_to?(:find_support_file)

      plugins_dir = Sketchup.find_support_file('Plugins')
      return true unless plugins_dir && File.directory?(plugins_dir)

      # Проверка как основного имени, так и альтернативных лоадеров
      candidates = [
        "#{id}.rb",
        (id == 'dn1sup_comp_add_view' ? 'su_component_add_view.rb' : nil)
      ].compact

      candidates.any? { |f| File.file?(File.join(plugins_dir, f)) }
    rescue StandardError
      false
    end

    # Установленная версия: фактическая из Extension Manager — источник истины;
    # сохранённый при установке через Store default — только fallback (для
    # перезапуска до регистрации расширения). nil = не установлено.
    def installed_version(entry_or_id)
      return nil unless defined?(Sketchup)

      id   = entry_or_id.is_a?(Hash) ? entry_or_id['id'].to_s : entry_or_id.to_s
      name = entry_or_id.is_a?(Hash) ? entry_or_id['name'].to_s : nil

      # Если файла нет в Plugins — расширение удалено или не ставилось
      return nil unless extension_file_exists?(id)

      # 1. Фактическая версия из зарегистрированных расширений Sketchup
      if Sketchup.respond_to?(:extensions) && Sketchup.extensions
        ext = (name && Sketchup.extensions[name]) || Sketchup.extensions[id]

        unless ext
          search_keys = [name, id].compact
          search_keys << 'ComponentAddViews' if id == 'dn1sup_comp_add_view'

          Sketchup.extensions.each do |candidate|
            c_name = candidate.respond_to?(:name) ? candidate.name.to_s : ''
            c_id   = candidate.respond_to?(:id) ? candidate.id.to_s : ''
            if search_keys.any? { |k| (!k.to_s.empty? && (c_name.casecmp?(k) || c_id.casecmp?(k))) }
              ext = candidate
              break
            end
          end
        end

        ver = ext&.version
        return ver.to_s.sub(/\Av/, '') unless ver.to_s.empty?
      end

      # 2. Версия, сохранённая при установке через Store
      saved = Sketchup.read_default('DN1Sup ExtManager', "installed_#{id}", nil)
      return saved.to_s.sub(/\Av/, '') unless saved.to_s.empty?

      nil
    rescue StandardError
      nil
    end

    # Получение последнего релиза с кэшированием по имени репозитория
    def latest_release(repo, force = false)
      repo_str = repo.to_s
      if force || !@release_cache.key?(repo_str)
        @release_cache[repo_str] = Dn1sup::Updater.latest_release(repo_str)
      end
      @release_cache[repo_str] || {}
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      {}
    end
    # Поиск .rbz ассета в релизе репозитория
    def find_rbz_asset(release, preferred_name = nil)
      return nil unless release.is_a?(Hash) && release['assets'].is_a?(Array)
      assets = release['assets']
      if preferred_name && !preferred_name.to_s.empty?
        found = assets.find { |a| a['name'].to_s.casecmp?(preferred_name.to_s) }
        return found if found
      end
      assets.find { |a| a['name'].to_s.end_with?('.rbz') }
    end

    # Извлечение персонального лога изменений для конкретного расширения
    def extract_extension_changelog(body, entry)
      id   = entry['id'].to_s
      name = entry['name'].to_s

      if body.is_a?(String) && !body.strip.empty?
        # Ищем персональную секцию расширения в Release Notes:
        # ### [dn1sup_ext_manager] или ### dn1sup_ext_manager (v0.2.0) или ## DN1Sup Extension Store
        escaped_keys = [Regexp.escape(id), Regexp.escape(name)].reject(&:empty?).join('|')
        pattern = /(?:^|\n)[#]{2,4}\s*(?:\[?(?:#{escaped_keys})\]?)[^\n]*\n(.*?)(?=\n[#]{2,4}\s|\z)/mi
        if (m = body.match(pattern))
          text = m[1].to_s.strip
          return text unless text.empty?
        end

        # Для отдельных репозиториев тело релиза целиком является логом изменений
        clean_body = body.strip
        return clean_body unless clean_body.empty?
      end

      # Если в релизе нет лога — берём персональный лог из реестра
      entry_log = entry['changelog'].to_s.strip
      return entry_log unless entry_log.empty?

      'Лог изменений для этого расширения отсутствует.'
    end

    # Сбор сводки по всем продуктам для HTML интерфейса.
    # check_releases: false — мгновенный оффлайн-сбор из registry.json и локальных плагинов.
    # check_releases: true — с сетевым запросом к GitHub API.
    # releases: опциональный Hash { repo => release_data } для объединения данных.
    def collect_products_data(force = false, check_releases: false, releases: nil)
      entries = load_registry
      return [] if entries.empty?

      rel_map = releases || @release_cache || {}

      entries.map do |entry|
        id   = entry['id'].to_s
        repo = entry['repo'].to_s
        name = entry['name'].to_s.empty? ? id : entry['name'].to_s

        release = check_releases ? latest_release(repo, force) : (rel_map[repo.to_s] || {})
        installed_ver = installed_version(entry)
        is_installed = !installed_ver.to_s.empty?

        latest_tag   = release.is_a?(Hash) ? release['tag_name'].to_s : ''
        release_body = release.is_a?(Hash) ? release['body'].to_s : ''
        published_at = release.is_a?(Hash) ? release['published_at'].to_s : ''
        release_url  = release.is_a?(Hash) ? release['html_url'].to_s : ''

        # Находим .rbz ассет в релизе конкретного репозитория
        rbz_asset  = find_rbz_asset(release, entry['asset'])
        asset_name = rbz_asset ? rbz_asset['name'].to_s : (entry['asset'] || "#{id}.rbz").to_s

        # Описание: из репозитория/релиза или из реестра
        desc = entry['description'].to_s
        if desc.empty? && release.is_a?(Hash) && !release['name'].to_s.empty? && release['name'] != latest_tag
          desc = release['name'].to_s
        end

        # Персональный лог изменений для этого расширения
        changelog = extract_extension_changelog(release_body, entry)

        # Актуальная версия расширения: из тега релиза репозитория либо из реестра
        ext_target_ver = !latest_tag.empty? ? latest_tag.sub(/\Av/i, '') : entry['version'].to_s

        has_update = false
        if is_installed && !ext_target_ver.empty?
          latest_norm    = Dn1sup::Updater.norm_version(ext_target_ver)
          installed_norm = Dn1sup::Updater.norm_version(installed_ver)
          has_update     = Dn1sup::Updater.newer?(latest_norm, installed_norm)
        end

        {
          'id'                => id,
          'name'              => name,
          'description'       => desc,
          'repo'              => repo,
          'asset'             => asset_name,
          'installed_version' => installed_ver,
          'is_installed'      => is_installed,
          'latest_version'    => ext_target_ver.empty? ? '—' : ext_target_ver,
          'has_update'        => has_update,
          'changelog'         => changelog,
          'release_url'       => release_url,
          'published_at'      => published_at
        }
      end
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      []
    end

    # ---- Установка / Обновление / Удаление --------------------------------

    # Установка расширения по ID
    def perform_install(id)
      entries = load_registry
      entry = entries.find { |e| e['id'].to_s == id.to_s }
      return { 'ok' => false, 'error' => "Расширение «#{id}» не найдено в реестре." } unless entry

      repo = entry['repo'].to_s
      name = entry['name'].to_s.empty? ? id : entry['name'].to_s
      release = latest_release(repo, true)
      unless release.is_a?(Hash) && release.key?('tag_name')
        return { 'ok' => false, 'error' => "#{name}: не удалось получить список релизов с GitHub." }
      end

      # Ищем .rbz ассет в релизе репозитория
      rbz_asset = find_rbz_asset(release, entry['asset'])
      url = rbz_asset ? rbz_asset['browser_download_url'] : Dn1sup::Updater.asset_url(release, entry['asset'].to_s)
      if url.to_s.empty?
        return {
          'ok' => false,
          'error' => "#{name}: в последнем релизе (#{release['tag_name']}) не найден .rbz файл для установки."
        }
      end

      ok = Dn1sup::Updater.install_from_url(url, "#{name} (#{release['tag_name']})", true)
      if ok
        # Сохраняем актуальную версию из релиза репозитория
        installed_ver = release['tag_name'].to_s.sub(/\Av/i, '')
        installed_ver = entry['version'].to_s.sub(/\Av/i, '') if installed_ver.empty?
        Sketchup.write_default('DN1Sup ExtManager', "installed_#{id}", installed_ver) if defined?(Sketchup)
        { 'ok' => true, 'message' => "Расширение «#{name}» (v#{installed_ver}) успешно установлено! Перезапустите SketchUp для полной загрузки компонентов." }
      else
        { 'ok' => false, 'error' => "SketchUp не удалось установить архив расширения «#{name}»." }
      end
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      { 'ok' => false, 'error' => "Исключение при установке: #{e.message}" }
    end

    # Обновление расширения
    def perform_update(id)
      res = perform_install(id)
      if res['ok']
        res['message'] = "Расширение успешно обновлено! Перезапустите SketchUp, чтобы новый код загрузился."
      end
      res
    end

    # Удаление расширения (выгрузка и удаление файлов из Plugins)
    def perform_uninstall(id)
      return { 'ok' => false, 'error' => 'DN1Sup Extension Store нельзя удалить из самого себя. Используйте Window → Extension Manager.' } if id.to_s == ID
      return { 'ok' => false, 'error' => 'SketchUp недоступен.' } unless defined?(Sketchup)

      plugins_dir = Sketchup.find_support_file('Plugins')
      return { 'ok' => false, 'error' => 'Папка Plugins не найдена.' } unless plugins_dir && File.directory?(plugins_dir)

      rb_file = File.join(plugins_dir, "#{id}.rb")
      sub_dir = File.join(plugins_dir, id.to_s)

      # 1. Отключаем расширение в текущей сессии SketchUp
      if Sketchup.respond_to?(:extensions) && Sketchup.extensions
        ext = Sketchup.extensions.find do |candidate|
          c_name = candidate.respond_to?(:name) ? candidate.name.to_s : ''
          c_id   = candidate.respond_to?(:id) ? candidate.id.to_s : ''
          c_name.casecmp?(id.to_s) || c_id.casecmp?(id.to_s)
        end
        ext.uncheck if ext && ext.respond_to?(:uncheck)
      end

      # 2. Удаляем файлы с диска
      FileUtils.rm_f(rb_file) if File.file?(rb_file)
      FileUtils.rm_rf(sub_dir) if File.directory?(sub_dir)

      # 3. Сбрасываем кэш версий
      Sketchup.write_default('DN1Sup ExtManager', "installed_#{id}", nil)
      Sketchup.write_default('Dn1supUpdater', "last_#{id}", 0)

      { 'ok' => true, 'message' => "Расширение «#{id}» удалено из папки Plugins. Запись в меню исчезнет после перезапуска SketchUp." }
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      { 'ok' => false, 'error' => "Ошибка при удалении: #{e.message}" }
    end

    # ---- UI & HtmlDialog --------------------------------------------------

    # Отправка актуальных данных о продуктах в HTML диалог.
    # Этап 1: МГНОВЕННО отдаём локальные данные (реестр + локально установленные плагины).
    #         Каталог отображается сразу, не дожидаясь ответа от GitHub API.
    #         Выполняется синхронно на главном потоке (безопасно для вызовов SketchUp API).
    # Этап 2: В фоновом потоке запрашиваем последние релизы с GitHub (только сеть, БЕЗ вызовов API SketchUp).
    #         По готовности обновляем данные на главном потоке.
    def send_products_to_dialog(force: false)
      return unless @dialog

      # 1. Мгновенная отрисовка из локального кэша и реестра
      local_products = collect_products_data(false, check_releases: false)
      if local_products.is_a?(Array)
        @dialog.execute_script("window.renderProducts(#{JSON.generate(local_products)});")
      end

      # 2. Фоновое обновление версий через сеть (только сетевые запросы, без SketchUp API в потоке)
      entries = load_registry
      repos = entries.map { |e| e['repo'].to_s }.uniq.reject(&:empty?)
      return if repos.empty?

      Dn1sup::Updater.defer_async(
        lambda do
          result = {}
          repos.each do |repo|
            rel = latest_release(repo, force)
            result[repo] = rel if rel.is_a?(Hash) && rel.key?('tag_name')
          end
          result
        end,
        lambda do |fetched_releases|
          return unless @dialog

          if fetched_releases.is_a?(Hash) && fetched_releases.any?
            @release_cache.merge!(fetched_releases)
            updated_products = collect_products_data(false, check_releases: false, releases: @release_cache)
            if updated_products.is_a?(Array) && updated_products.any?
              @dialog.execute_script("window.renderProducts(#{JSON.generate(updated_products)});")
            end
          end
        end
      )
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    # Имя продукта из реестра по id (для диалогов подтверждения).
    def product_name(id)
      entry = load_registry.find { |e| e['id'].to_s == id.to_s }
      entry && !entry['name'].to_s.empty? ? entry['name'].to_s : id.to_s
    rescue StandardError
      id.to_s
    end

    # Результат операции в диалог. Все строки — через JSON.generate,
    # никакого interpolate в JS-литералы.
    def notify_action_result(id, action, res)
      return unless @dialog && @dialog.visible?

      script = "window.handleActionResult(#{JSON.generate(id.to_s)}, #{JSON.generate(action)}, #{JSON.generate(res)});"
      @dialog.execute_script(script)
    end

    # Открытие HTML диалога каталога расширений
    def open_store
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end

      unless File.file?(HTML_PATH)
        UI.messagebox("HTML-интерфейс не найден: #{HTML_PATH}", MB_OK) if defined?(UI)
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title:    'DN1Sup Extension Store',
        preferences_key: 'dn1sup_ext_manager_store_window',
        scrollable:      true,
        resizable:       true,
        width:           860,
        height:          660,
        left:            180,
        top:             140,
        min_width:       600,
        min_height:      420
      )

      @dialog.set_file(HTML_PATH)

      # Callback: готовность интерфейса к приёму данных
      @dialog.add_action_callback('ready') do |_context|
        send_products_to_dialog(force: false)
      end

      # Callback: принудительное обновление списка и проверка версий
      @dialog.add_action_callback('refresh') do |_context|
        send_products_to_dialog(force: true)
      end

      # Callback: установка
      @dialog.add_action_callback('install') do |_context, id|
        res = perform_install(id)
        notify_action_result(id, 'install', res)
        send_products_to_dialog(force: false)
      end

      # Callback: обновление
      @dialog.add_action_callback('update') do |_context, id|
        res = perform_update(id)
        notify_action_result(id, 'update', res)
        send_products_to_dialog(force: false)
      end

      # Callback: подтверждение удаления через нативный диалог SketchUp
      # (window.confirm в HtmlDialog на части сборок подавлен).
      @dialog.add_action_callback('confirm_uninstall') do |_context, id|
        msg = "Вы действительно хотите удалить расширение «#{product_name(id)}» из SketchUp?"
        yes = defined?(UI) && UI.messagebox(msg, MB_YESNO) == IDYES
        if @dialog && @dialog.visible?
          @dialog.execute_script("window.confirmResult(#{JSON.generate(id.to_s)}, #{!!yes});")
        end
      end

      # Callback: удаление
      @dialog.add_action_callback('uninstall') do |_context, id|
        res = perform_uninstall(id)
        notify_action_result(id, 'uninstall', res)
        send_products_to_dialog(force: false)
      end

      @dialog.show
    end

    # Показывает выпадающий список (fallback / CLI / тесты).
    def prompt_pick(entries)
      options = entries.map.with_index do |e, i|
        ver   = e['installed_version'].to_s
        state = ver.empty? ? 'не установлено' : "установлена #{ver}"
        "#{i + 1}. #{e['name']} [#{state}]"
      end
      options << '0. Выйти из магазина'

      prompts  = ['Выберите расширение:']
      defaults = [options.first]
      lists    = [options.join('|')]

      answer = UI.inputbox(prompts, defaults, lists, 'DN1Sup Extension Store')
      return nil if !answer || answer == false

      choice = answer[0].to_s.strip
      idx = choice.to_i
      (idx >= 1 && idx <= entries.size) ? idx : 0
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      nil
    end

    def open_registry_repo
      UI.openURL("https://github.com/#{REPO}/blob/main/registry.json") if defined?(UI)
    end

    # Dev-режим: перезагрузка файлов
    def reload(clear_console = true, undo = false)
      verbose = $VERBOSE
      $VERBOSE = nil
      Dir.glob(File.join(PLUGIN_DIR, '**/*.{rb,rbe}')).each { |f| load(f) }
      $VERBOSE = verbose
      UI.start_timer(0, false) { SKETCHUP_CONSOLE.clear } if clear_console && defined?(SKETCHUP_CONSOLE)
      Sketchup.undo if undo
    rescue StandardError => e
      $VERBOSE = verbose
      puts e.message
      puts e.backtrace.join("\n")
      nil
    end

    unless file_loaded?(__FILE__)
      # Общее меню DN1Sup — синглтон в корневом модуле Dn1sup, разделяется всеми
      # расширениями DN1Sup без глобальных переменных.
      common = Dn1sup.common_menu

      # Пункты расширения — в подменю «Extension Store» внутри DN1Sup
      menu = common.add_submenu('Extension Store')
      menu.add_item('Каталог расширений…') { open_store }
      menu.add_item('Проверить обновления менеджера') do
        Dn1sup::Updater.check!({ id: ID, repo: REPO, version: VERSION, asset: ASSET, force: true, async: true })
      end
      menu.add_separator
      menu.add_item('О реестре') { open_registry_repo }

      # Фоновая проверка обновлений менеджера при запуске (сеть в потоке,
      # результат — ненавязчивое уведомление, без модальных диалогов)
      timer_id = nil
      timer_id = UI.start_timer(20, false) do
        UI.stop_timer(timer_id) if timer_id
        Dn1sup::Updater.check!({ id: ID, repo: REPO, version: VERSION, asset: ASSET, async: true })
      end

      file_loaded(__FILE__)
    end
  end
end
