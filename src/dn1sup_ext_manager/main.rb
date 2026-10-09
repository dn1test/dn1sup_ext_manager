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
    VERSION = '0.9.0'
    REPO    = 'dn1test/dn1sup_ext_manager'
    ASSET   = "#{ID}.rbz"
    PAGE_URL     = "https://github.com/#{REPO}/releases"
    REGISTRY_URL = "https://raw.githubusercontent.com/#{REPO}/main/registry.json"

    # Автопоиск расширений: аккаунт/организация на GitHub, в которой ищутся
    # репозитории dn1sup_*, отсутствующие в registry.json. Менеджер и
    # расширения связаны только этим именем — каждое расширение живёт в своём
    # репозитории и обновляется независимо.
    OWNER = 'dn1test'
    DISCOVERY_INTERVAL = 24 * 60 * 60

    PLUGIN_DIR   = File.dirname(__FILE__).freeze
    HTML_PATH    = File.join(PLUGIN_DIR, 'html', 'index.html').freeze
    ICON_DIR     = File.join(PLUGIN_DIR, 'icons').freeze
    TOOLBAR_NAME = 'DN1Sup Extension Store'
    CMD_TOOLTIP  = 'DN1Sup Extension Store — каталог, установка и обновление расширений'

    @dialog = nil
    @release_cache = {}   # repo => предлагаемый (новейший стабильный) релиз
    @releases_cache = {}  # repo => [релизы] — полный список для статусов
    @discovered_entries = [] # найденные на GitHub расширения вне registry.json
    @commits_cache = {}   # repo => {'installed'=>..,'offered'=>..,'messages'=>[...]}

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

    # ---- Автопоиск расширений на GitHub ------------------------------------

    # Скрытые пользователем найденные репозитории (pref, CSV).
    def hidden_repos
      return [] unless defined?(Sketchup)

      Sketchup.read_default('DN1Sup ExtManager', 'hidden_repos', '')
              .to_s.split(',').map(&:strip).reject(&:empty?)
    rescue StandardError
      []
    end

    def hide_repo(repo)
      return if repo.to_s.empty? || !defined?(Sketchup)

      list = (hidden_repos | [repo.to_s]).uniq
      Sketchup.write_default('DN1Sup ExtManager', 'hidden_repos', list.join(','))
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    def unhide_all_repos
      return unless defined?(Sketchup)

      Sketchup.write_default('DN1Sup ExtManager', 'hidden_repos', nil)
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    # Полный список записей каталога: явный registry.json + найденные на
    # GitHub расширения, которых в реестре нет. Реестр первичен: найденное
    # дополняет, но не заменяет. Скрытые репозитории отфильтровываются.
    def merged_entries
      entries = load_registry
      known = {}
      entries.each do |e|
        known[e['id'].to_s] = true
        known[e['repo'].to_s] = true
      end
      @discovered_entries.each do |e|
        next if known[e['repo'].to_s] || known[e['id'].to_s]

        entries << e
      end
      hidden = hidden_repos
      hidden.empty? ? entries : entries.reject { |e| hidden.include?(e['repo'].to_s) }
    end

    # Запись каталога по id — и из реестра, и среди найденных (установка,
    # удаление и имена работают для обоих источников).
    def find_entry(id)
      merged_entries.find { |e| e['id'].to_s == id.to_s }
    end

    # Пора ли сканировать GitHub: принудительно по кнопке либо не чаще раза
    # в сутки (pref last_discovery).
    def discovery_due?(force)
      return true if force
      return false unless defined?(Sketchup)

      last = Sketchup.read_default('DN1Sup ExtManager', 'last_discovery', 0)
      (Time.now.to_i - last.to_i) >= DISCOVERY_INTERVAL
    rescue StandardError
      false
    end

    def mark_discovered
      return unless defined?(Sketchup)

      Sketchup.write_default('DN1Sup ExtManager', 'last_discovery', Time.now.to_i)
    rescue StandardError
      nil
    end

    # Скан репозиториев dn1sup_* аккаунта OWNER, отсутствующих в registry.json.
    # Только сеть (вызывается в фоновом потоке). Метаданные — из registry.json
    # самого репозитория, фолбэк — описание репозитория с GitHub.
    def discover_repos
      registry_ids = {}
      load_registry.each do |e|
        registry_ids[e['id'].to_s] = true
        registry_ids[e['repo'].to_s] = true
      end
      found = []
      Dn1sup::Updater.repos_of_owner(OWNER).each do |r|
        next unless r.is_a?(Hash)

        repo = r['full_name'].to_s
        name = r['name'].to_s
        next if repo.empty? || !name.start_with?('dn1sup_')
        next if r['archived'] || registry_ids[repo] || registry_ids[name]

        meta = Dn1sup::Updater.registry_entry(repo, name) || {}
        entry = {
          'id'          => meta['id'].to_s.empty? ? name : meta['id'].to_s,
          'name'        => meta['name'].to_s.empty? ? name : meta['name'].to_s,
          'description' => meta['description'].to_s.empty? ? r['description'].to_s : meta['description'].to_s,
          'repo'        => repo,
          'discovered'  => true
        }
        found << entry
      end
      store_debug("автопоиск: найдено #{found.size} новых репозиториев")
      found
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      []
    end

    # Проверяет, физически ли файл расширения существует в папке Plugins
    def extension_file_exists?(id)
      return false unless defined?(Sketchup)
      return true unless Sketchup.respond_to?(:find_support_file)

      plugins_dir = Sketchup.find_support_file('Plugins')
      return true unless plugins_dir && File.directory?(plugins_dir)

      # Проверка лоадера по каноническому имени <id>.rb
      # (нестандартные имена лоадеров — ответственность репозитория расширения)
      File.file?(File.join(plugins_dir, "#{id}.rb"))
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

    # Получение последнего релиза с кэшированием по имени репозитория.
    # Неудачный запрос ({} — сеть недоступна, лимиты) НЕ кэшируется: иначе
    # одна сетевая ошибка обнуляла версии и changelog'и до конца сессии.
    def latest_release(repo, force = false)
      repo_str = repo.to_s
      if force || !@release_cache.key?(repo_str)
        rel = Dn1sup::Updater.latest_release(repo_str)
        @release_cache[repo_str] = rel if rel.is_a?(Hash) && rel.key?('tag_name')
      end
      @release_cache[repo_str] || {}
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      {}
    end

    # Список релизов репозитория (для статусов «обновление / смена версии»).
    # Успешный список кэшируется и заодно обновляет одиночный кэш предлагаемого
    # релиза; неудача (пустой список) не кэшируется.
    def releases_list(repo, force = false)
      repo_str = repo.to_s
      if force || !@releases_cache.key?(repo_str)
        list = Dn1sup::Updater.releases(repo_str)
        if list.is_a?(Array) && !list.empty?
          @releases_cache[repo_str] = list
          offered = Dn1sup::Updater.choose_release(list)
          @release_cache[repo_str] = offered if offered
        end
      end
      @releases_cache[repo_str] || []
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      []
    end

    # ---- Снапшот релизов (офлайн-фоллбэк для версий и changelog'ов) -------

    # Путь к снапшоту последних успешных релизов (в temp-каталоге SketchUp).
    def snapshot_path
      dir = defined?(Sketchup) && Sketchup.respond_to?(:temp_dir) ? Sketchup.temp_dir : Dir.tmpdir
      File.join(dir.to_s, 'dn1sup_ext_releases.json')
    rescue StandardError
      nil
    end

    # Сохраняет компактный снапшот успешных списков релизов, найденных
    # расширений и логов правок. Формат v3:
    # { "version" => 3, "releases" => { repo => [release, ...] },
    #   "discovered" => [entry, ...], "commits" => { repo => {...} } } —
    # до 10 релизов на репозиторий (статусы и changelog берутся из них;
    # установка всегда делает свежий запрос).
    def save_release_snapshot
      path = snapshot_path
      return unless path

      data = {
        'version'    => 3,
        'saved_at'   => Time.now.to_i,
        'releases'   => {},
        'discovered' => @discovered_entries,
        'commits'    => @commits_cache
      }
      @releases_cache.each do |repo, list|
        next unless list.is_a?(Array) && !list.empty?

        data['releases'][repo] = list.first(10).map do |rel|
          {
            'tag_name'     => rel['tag_name'],
            'name'         => rel['name'],
            'body'         => rel['body'],
            'published_at' => rel['published_at'],
            'prerelease'   => rel['prerelease'] ? true : false,
            'html_url'     => rel['html_url'],
            'assets'       => (rel['assets'] || []).map do |a|
              { 'name' => a['name'], 'browser_download_url' => a['browser_download_url'] }
            end
          }
        end
      end
      File.write(path, JSON.generate(data))
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    # Загружает снапшот в кэши (только если кэш пуст — не затирая свежие
    # данные). Понимает формат v3 (списки релизов + найденные + коммиты) и
    # старые: v2 (списки релизов) и v1 (repo => релиз, заворачивается в
    # список из одного элемента).
    def load_release_snapshot
      path = snapshot_path
      return unless path && File.file?(path) && @release_cache.empty?

      data = JSON.parse(File.read(path))
      return unless data.is_a?(Hash)

      if data['discovered'].is_a?(Array) && @discovered_entries.empty?
        @discovered_entries = data['discovered'].find_all do |e|
          e.is_a?(Hash) && !e['id'].to_s.empty? && !e['repo'].to_s.empty?
        end
      end
      if data['commits'].is_a?(Hash) && @commits_cache.empty?
        @commits_cache = data['commits']
      end

      if data['releases'].is_a?(Hash)
        data['releases'].each do |repo, list|
          next unless list.is_a?(Array) && !list.empty?

          @releases_cache[repo] = list
          offered = Dn1sup::Updater.choose_release(list)
          @release_cache[repo] = offered if offered
        end
      else
        data.each do |repo, rel|
          next unless rel.is_a?(Hash) && rel.key?('tag_name')

          @release_cache[repo] = rel
          @releases_cache[repo] = [rel]
        end
      end
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
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

    # Извлечение персонального лога изменений для конкретного расширения.
    # Для показа в приложении — краткая суть (1-3 строки, без markdown) через
    # Dn1sup::Updater.short_notes; подробности остаются в CHANGELOG и на GitHub.
    def extract_extension_changelog(body, entry)
      id   = entry['id'].to_s
      name = entry['name'].to_s
      fallback = 'Лог изменений для этого расширения отсутствует.'

      raw =
        if body.is_a?(String) && !body.strip.empty?
          # Ищем персональную секцию расширения в Release Notes:
          # ### [dn1sup_ext_manager] или ### dn1sup_ext_manager (v0.2.0) или ## DN1Sup Extension Store
          escaped_keys = [Regexp.escape(id), Regexp.escape(name)].reject(&:empty?).join('|')
          pattern = /(?:^|\n)[#]{2,4}\s*(?:\[?(?:#{escaped_keys})\]?)[^\n]*\n(.*?)(?=\n[#]{2,4}\s|\z)/mi
          if (m = body.match(pattern)) && !m[1].to_s.strip.empty?
            m[1].to_s.strip
          else
            # Для отдельных репозиториев тело релиза целиком является логом изменений
            body.strip
          end
        else
          entry['changelog'].to_s.strip
        end

      return fallback if raw.empty?

      Dn1sup::Updater.short_notes(raw)
    end

    # Сбор сводки по всем продуктам для HTML интерфейса.
    # check_releases: false — мгновенный оффлайн-сбор из registry.json и локальных плагинов.
    # check_releases: true — с сетевым запросом к GitHub API.
    # releases: опциональный Hash { repo => release_data } для объединения данных.
    # release_lists: опциональный Hash { repo => [release, ...] } для статусов.
    def collect_products_data(force = false, check_releases: false, releases: nil, release_lists: nil)
      entries = merged_entries
      return [] if entries.empty?

      rel_map  = releases || @release_cache || {}
      list_map = release_lists || @releases_cache || {}

      entries.map do |entry|
        id   = entry['id'].to_s
        repo = entry['repo'].to_s
        name = entry['name'].to_s.empty? ? id : entry['name'].to_s

        release = check_releases ? latest_release(repo, force) : (rel_map[repo.to_s] || {})
        rel_list = list_map[repo.to_s].is_a?(Array) ? list_map[repo.to_s] : []

        # Найденные на GitHub расширения показываем, только когда известны
        # их релизы: без них нельзя ни версию показать, ни .rbz установить.
        next nil if entry['discovered'] && rel_list.empty?

        offered = Dn1sup::Updater.choose_release(rel_list)
        offered = release if offered.nil? && release.is_a?(Hash) && release.key?('tag_name')

        installed_ver = installed_version(entry)
        is_installed = !installed_ver.to_s.empty?

        latest_tag   = offered ? offered['tag_name'].to_s : ''
        release_body = offered ? offered['body'].to_s : ''
        published_at = offered ? offered['published_at'].to_s : ''
        release_url  = offered ? offered['html_url'].to_s : ''

        # Находим .rbz ассет в релизе конкретного репозитория
        rbz_asset  = find_rbz_asset(offered, entry['asset'])
        asset_name = rbz_asset ? rbz_asset['name'].to_s : (entry['asset'] || "#{id}.rbz").to_s

        # Описание: из репозитория/релиза или из реестра
        desc = entry['description'].to_s
        if desc.empty? && offered && !offered['name'].to_s.empty? && offered['name'] != latest_tag
          desc = offered['name'].to_s
        end

        # Персональный лог изменений для этого расширения
        changelog = extract_extension_changelog(release_body, entry)

        # Актуальная версия расширения: из тега релиза репозитория либо из реестра
        ext_target_ver = !latest_tag.empty? ? latest_tag.sub(/\Av/i, '') : entry['version'].to_s

        # Статус относительно предлагаемого релиза: 'update' / 'switch' / 'current' / nil.
        # Для переизданных релизов без бампа версии — дата установки текущей сборки.
        installed_at = Dn1sup::Updater.installed_at(id) if is_installed
        status = Dn1sup::Updater.product_status(installed_ver, offered, rel_list, installed_at: installed_at)
        has_update = (status == 'update')

        # Лог правок (коммиты) между установленной и предлагаемой версиями —
        # если он уже загружен и относится именно к этой паре версий.
        commits = []
        cached = @commits_cache[repo.to_s]
        if cached.is_a?(Hash) && cached['installed'].to_s == installed_ver.to_s &&
           cached['offered'].to_s == ext_target_ver && cached['messages'].is_a?(Array)
          commits = cached['messages']
        end

        {
          'id'                => id,
          'name'              => name,
          'description'       => desc,
          'repo'              => repo,
          'asset'             => asset_name,
          'discovered'        => !!entry['discovered'],
          'installed_version' => installed_ver,
          'is_installed'      => is_installed,
          'latest_version'    => ext_target_ver.empty? ? '—' : ext_target_ver,
          'has_update'        => has_update,
          'status'            => status.to_s,
          'changelog'         => changelog,
          'commits'           => commits,
          'release_url'       => release_url,
          'published_at'      => published_at
        }
      end.compact
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      []
    end

    # ---- Установка / Обновление / Удаление --------------------------------

    # Установка расширения по ID (в том числе найденного на GitHub)
    def perform_install(id)
      entry = find_entry(id)
      unless entry
        store_log("установка '#{id}': расширение не найдено в реестре")
        return { 'ok' => false, 'error' => "Расширение «#{id}» не найдено в реестре." }
      end

      repo = entry['repo'].to_s
      name = entry['name'].to_s.empty? ? id : entry['name'].to_s
      release = latest_release(repo, true)
      unless release.is_a?(Hash) && release.key?('tag_name')
        store_log("установка '#{id}': релизы #{repo} недоступны")
        return { 'ok' => false, 'error' => "#{name}: не удалось получить список релизов с GitHub." }
      end

      # Ищем .rbz ассет в релизе репозитория
      rbz_asset = find_rbz_asset(release, entry['asset'])
      url = rbz_asset ? rbz_asset['browser_download_url'] : Dn1sup::Updater.asset_url(release, entry['asset'].to_s)
      if url.to_s.empty?
        store_log("установка '#{id}': в релизе #{release['tag_name']} нет .rbz-ассета")
        return {
          'ok' => false,
          'error' => "#{name}: в последнем релизе (#{release['tag_name']}) не найден .rbz файл для установки."
        }
      end

      ok = Dn1sup::Updater.install_from_url(url, "#{name} (#{release['tag_name']})", true, id: id)
      if ok
        # Сохраняем актуальную версию из релиза репозитория
        installed_ver = release['tag_name'].to_s.sub(/\Av/i, '')
        installed_ver = entry['version'].to_s.sub(/\Av/i, '') if installed_ver.empty?
        Sketchup.write_default('DN1Sup ExtManager', "installed_#{id}", installed_ver) if defined?(Sketchup)
        store_log("установлен/обновлён #{id} -> v#{installed_ver} (#{repo})")
        { 'ok' => true, 'message' => "Расширение «#{name}» (v#{installed_ver}) успешно установлено! Перезапустите SketchUp для полной загрузки компонентов." }
      else
        store_log("установка #{id} (#{repo}) НЕУДАЧНА: архив не установлен")
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

      store_log("удалён #{id} из Plugins")
      { 'ok' => true, 'message' => "Расширение «#{id}» удалено из папки Plugins. Запись в меню исчезнет после перезапуска SketchUp." }
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      { 'ok' => false, 'error' => "Ошибка при удалении: #{e.message}" }
    end

    # ---- UI & HtmlDialog --------------------------------------------------
    #
    # Обмен Ruby ↔ JS (единый паттерн с dn1sup_create_project /
    # dn1sup_save_settings): один экшен-колбэк 'call_ruby' (name + JSON-параметр)
    # и пуш-функции window.pushState / window.pushResult.

    # Отправка состояния каталога в диалог.
    # Этап 1: МГНОВЕННО отдаём локальные данные (реестр + найденные ранее +
    # локально установленные плагины). Каталог отображается сразу, не дожидаясь
    # ответа от GitHub API. Выполняется синхронно на главном потоке
    # (безопасно для вызовов SketchUp API).
    # Этап 2: В фоновом потоке запрашиваем последние релизы с GitHub, при
    # необходимости сканируем GitHub на новые расширения dn1sup_*, затем
    # подтягиваем логи правок (коммиты) для обновлений. По готовности данные
    # обновляются на главном потоке.
    def send_products_to_dialog(force: false)
      dlg = @dialog
      return unless dlg

      # 1. Мгновенная отрисовка из локального кэша, реестра и снапшота.
      #    Если кэш пуст (новая сессия) — подгружаем снапшот последних
      #    успешных релизов и найденных расширений, чтобы каталог был виден офлайн.
      load_release_snapshot if @release_cache.empty?
      local = collect_products_data(false, check_releases: false)
      store_debug("отрисовка каталога: #{local.is_a?(Array) ? local.size : 0} продуктов" \
                  "#{force ? ', force-обновление' : ''}")
      push_state(dlg, local)

      # 2. Фоновое обновление версий через сеть (только сетевые запросы, без SketchUp API в потоке)
      repos = merged_entries.map { |e| e['repo'].to_s }.uniq.reject(&:empty?)
      return if repos.empty?

      fetch_and_render(dlg, repos, force, attempts_left: 1)
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    # Фоновая загрузка списков релизов, автопоиска новых расширений и
    # перерисовка каталога. Однократный автоповтор, если сеть была
    # недоступна в момент первого обхода. После релизов — фоновая догрузка
    # логов правок (коммитов) для продуктов с обновлением.
    def fetch_and_render(dlg, repos, force, attempts_left: 0)
      want_discovery = discovery_due?(force)
      Dn1sup::Updater.defer_async(
        lambda do
          result = { 'releases' => {}, 'discovered' => nil }
          repos.each do |repo|
            list = releases_list(repo, force)
            result['releases'][repo] = list unless list.empty?
          end
          result['discovered'] = discover_repos if want_discovery
          result
        end,
        lambda do |fetched_raw|
          next unless @dialog

          fetched = fetched_raw.is_a?(Hash) ? fetched_raw : {}
          lists = fetched['releases'].is_a?(Hash) ? fetched['releases'] : {}
          store_debug("релизы получены #{lists.size}/#{repos.size}" \
                      "#{lists.size < repos.size && attempts_left == 0 ? ' (часть недоступна)' : ''}")

          new_entries = fetched['discovered']
          if new_entries.is_a?(Array)
            known = {}
            merged_entries.each do |e|
              known[e['id'].to_s] = true
              known[e['repo'].to_s] = true
            end
            added = new_entries.reject { |e| known[e['id'].to_s] || known[e['repo'].to_s] }
            @discovered_entries.concat(added) unless added.empty?
            mark_discovered
            store_debug("автопоиск: новых расширений #{added.size}") unless added.empty?
          end

          if lists.is_a?(Hash) && lists.any?
            @releases_cache.merge!(lists)
          end
          save_release_snapshot
          push_state(dlg, collect_products_data(false, check_releases: false))

          missing = repos.size - lists.size
          if attempts_left > 0 && missing > 0
            fetch_and_render(dlg, repos - lists.keys, force, attempts_left: attempts_left - 1)
          else
            fetch_commits_async(dlg)
          end
        end
      )
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    # Логи правок: для продуктов с обновлением/сменой версии подтягиваем
    # список коммитов между установленной и предлагаемой версиями
    # (compare API). Только сеть в фоне; результат — на главном потоке.
    def fetch_commits_async(dlg)
      pending = []
      collect_products_data(false, check_releases: false).each do |p|
        next unless p['has_update'] || p['status'] == 'switch'
        next if p['installed_version'].to_s.empty? || p['latest_version'].to_s.empty?

        cached = @commits_cache[p['repo']]
        next if cached.is_a?(Hash) &&
                cached['installed'].to_s == p['installed_version'].to_s &&
                cached['offered'].to_s == p['latest_version'].to_s

        pending << { 'repo' => p['repo'], 'installed' => p['installed_version'], 'offered' => p['latest_version'] }
      end
      return if pending.empty?

      Dn1sup::Updater.defer_async(
        lambda do
          result = {}
          pending.each do |item|
            msgs = Dn1sup::Updater.compare_commits(
              item['repo'], "v#{item['installed']}", "v#{item['offered']}", limit: 15
            )
            result[item['repo']] = item.merge('messages' => msgs) unless msgs.empty?
          end
          result
        end,
        lambda do |fetched|
          next unless @dialog

          commits = fetched.is_a?(Hash) ? fetched : {}
          next if commits.empty?

          @commits_cache.merge!(commits)
          save_release_snapshot
          push_state(dlg, collect_products_data(false, check_releases: false))
        end
      )
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    # Имя продукта по id — из реестра или среди найденных на GitHub
    # (для диалогов подтверждения).
    def product_name(id)
      entry = find_entry(id)
      entry && !entry['name'].to_s.empty? ? entry['name'].to_s : id.to_s
    rescue StandardError
      id.to_s
    end

    # Пуш состояния каталога в диалог. products — собранный список карточек
    # (nil → пустой список, UI покажет empty-state).
    def push_state(dlg, products)
      return unless dlg

      payload = {
        'version'  => VERSION,
        'products' => products.is_a?(Array) ? products : []
      }
      dlg.execute_script("window.pushState(#{JSON.generate(payload)});")
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    # Пуш результата операции в диалог. Все строки — через JSON.generate,
    # никакого interpolate в JS-литералы.
    def push_result(dlg, kind, payload)
      return unless dlg

      dlg.execute_script("window.pushResult(#{JSON.generate(kind)}, #{JSON.generate(payload || {})});")
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    # Результат операции install/update/uninstall в диалог.
    def notify_action_result(id, action, res)
      push_result(@dialog, 'action_result',
                  'id'      => id.to_s,
                  'action'  => action.to_s,
                  'ok'      => !!(res && res['ok']),
                  'message' => res && res['message'],
                  'error'   => res && res['error'])
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
      register_callbacks(@dialog)
      @dialog.show
      store_log("каталог открыт (Store v#{VERSION})")
    end

    def register_callbacks(dlg)
      dlg.add_action_callback('call_ruby') do |_context, name, param|
        dispatch(dlg, name.to_s, param.to_s)
      end
    end

    # Псевдонимы для логов: события каталога помечаются "ExtStore".
    def store_log(message)
      Dn1sup::Updater.log_info("ExtStore: #{message}")
    end

    def store_debug(message)
      Dn1sup::Updater.log_debug("ExtStore: #{message}")
    end

    # Диспетчер команд интерфейса (единый колбэк 'call_ruby').
    # param — JSON { id: '...' } для действий над карточками.
    def dispatch(dlg, name, param)
      id = begin
        parse_json(param)['id']
      rescue StandardError
        nil
      end
      store_debug("команда '#{name}'#{id && !id.to_s.empty? ? " (#{id})" : ''}")
      case name
      when 'ready', 'get_state'
        # Хук ошибок JS инжектится на каждый запрос состояния: идемпотентен
        # (флаг в window), а первый get_state приходит сразу после загрузки
        # страницы — до монтирования Vue.
        inject_error_hook(dlg)
        send_products_to_dialog(force: false)
      when 'refresh'
        send_products_to_dialog(force: true)
      when 'install'
        iid = parse_json(param)['id']
        notify_action_result(iid, 'install', perform_install(iid))
        send_products_to_dialog(force: false)
      when 'update'
        iid = parse_json(param)['id']
        notify_action_result(iid, 'update', perform_update(iid))
        send_products_to_dialog(force: false)
      when 'confirm_uninstall'
        # Подтверждение удаления через нативный диалог SketchUp
        # (window.confirm в HtmlDialog на части сборок подавлен).
        id = parse_json(param)['id']
        msg = "Вы действительно хотите удалить расширение «#{product_name(id)}» из SketchUp?"
        yes = defined?(UI) && UI.messagebox(msg, MB_YESNO) == IDYES
        push_result(dlg, 'confirm_uninstall', 'id' => id.to_s, 'ok' => !!yes)
      when 'uninstall'
        id = parse_json(param)['id']
        notify_action_result(id, 'uninstall', perform_uninstall(id))
        send_products_to_dialog(force: false)
      when 'hide'
        # Скрыть найденное на GitHub расширение (не из реестра)
        repo = parse_json(param)['repo']
        hide_repo(repo)
        store_log("скрыт найденный репозиторий #{repo}")
        send_products_to_dialog(force: false)
      when 'log_js_error'
        log_js_error(param)
      else
        Dn1sup::Updater.log_error(RuntimeError.new("Неизвестная команда диалога: #{name}"))
      end
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      push_result(dlg, 'error', 'message' => "#{e.class}: #{e.message}")
    end

    # Перехват ошибок интерфейса (window error / unhandledrejection) → Ruby
    # (log_js_error). Инжектится со стороны Ruby при 'ready' — без пересборки
    # фронтенда; повторная инжекция безопасна (флаг в window).
    JS_ERROR_HOOK = <<~'JS'.freeze
      (function () {
        if (window.__dn1supErrorHook) { return; }
        window.__dn1supErrorHook = true;
        function report(payload) {
          try {
            var bridge = (typeof sketchup !== 'undefined' && sketchup) || window.sketchup;
            if (bridge && typeof bridge.call_ruby === 'function') {
              bridge.call_ruby('log_js_error', JSON.stringify(payload));
            }
          } catch (e) { /* журнал не должен ломать интерфейс */ }
        }
        window.addEventListener('error', function (event) {
          var err = event && event.error;
          report({
            message: err && err.message ? String(err.message) : String((event && event.message) || 'JS error'),
            source: String((event && event.filename) || ''),
            lineno: (event && event.lineno) || 0,
            stack: err && err.stack ? String(err.stack) : ''
          });
        });
        window.addEventListener('unhandledrejection', function (event) {
          var reason = event && event.reason;
          report({
            message: 'Unhandled rejection: ' + (reason && reason.message ? String(reason.message) : String(reason)),
            source: '',
            lineno: 0,
            stack: reason && reason.stack ? String(reason.stack) : ''
          });
        });
      })();
    JS

    def inject_error_hook(dlg)
      dlg.execute_script(JS_ERROR_HOOK)
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    # Ошибки интерфейса (Vue/JS) → журнал. param — JSON {message, source,
    # lineno, stack}.
    def log_js_error(param)
      data = parse_json(param)
      message = "JS: #{data['message']}"
      source = [data['source'].to_s, data['lineno'].to_s].reject(&:empty?).join(':')
      message += " (#{source})" unless source.empty?
      stack = data['stack'].to_s
      message += "\n#{stack.lines.first(5).map(&:strip).join("\n")}" unless stack.empty?
      Dn1sup::Updater.log_error(RuntimeError.new(message))
    rescue StandardError
      nil
    end

    def parse_json(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      {}
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

    # Команда «Каталог расширений» — общая для меню и тулбара.
    def catalog_command
      cmd = UI::Command.new('Каталог расширений') { open_store }
      cmd.menu_text       = 'Каталог расширений…'
      cmd.tooltip         = CMD_TOOLTIP
      cmd.status_bar_text = 'Открыть каталог расширений DN1Sup'
      cmd.small_icon      = small_icon_path
      cmd.large_icon      = large_icon_path
      cmd
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      nil
    end

    # SVG-иконка поддерживается тулбарами начиная с SketchUp 2020.1 (v20);
    # на старых версиях используем PNG 16/24.
    def svg_icons_supported?
      Sketchup.respond_to?(:version) && Sketchup.version.to_i >= 20
    end

    def small_icon_path
      svg = File.join(ICON_DIR, 'store.svg')
      return svg if svg_icons_supported? && File.file?(svg)

      File.join(ICON_DIR, 'store_16.png')
    end

    def large_icon_path
      svg = File.join(ICON_DIR, 'store.svg')
      return svg if svg_icons_supported? && File.file?(svg)

      File.join(ICON_DIR, 'store_24.png')
    end

    # Панель инструментов с кнопкой вызова каталога. Тулбар нельзя удалить
    # через API, поэтому кнопка создаётся один раз: после перезагрузки кода
    # UI::Toolbar.new возвращает существующую панель, а дубликаты отсекаются
    # проверкой tooltip.
    def setup_toolbar
      toolbar = UI::Toolbar.new(TOOLBAR_NAME)
      return if toolbar.any? { |c| c.respond_to?(:tooltip) && c.tooltip == CMD_TOOLTIP }

      cmd = catalog_command
      return unless cmd

      toolbar.add_item(cmd)
      toolbar.restore
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    unless file_loaded?(__FILE__)
      # Общее меню DN1Sup — синглтон в корневом модуле Dn1sup, разделяется всеми
      # расширениями DN1Sup без глобальных переменных.
      common = Dn1sup.common_menu

      # Пункты расширения — в подменю «Extension Store» внутри DN1Sup
      menu = common.add_submenu('Extension Store')
      menu.add_item(catalog_command)
      menu.add_item('Проверить обновления менеджера') do
        Dn1sup::Updater.check!({ id: ID, repo: REPO, version: VERSION, asset: ASSET, force: true, async: true })
      end
      menu.add_separator
      menu.add_item('О реестре') { open_registry_repo }
      menu.add_item('Показать скрытые расширения') do
        if UI.messagebox('Снова показывать в каталоге все найденные на GitHub расширения?', MB_YESNO) == IDYES
          unhide_all_repos
          store_log('список скрытых репозиториев очищен')
          send_products_to_dialog(force: false) if @dialog
        end
      end

      # Кнопка с иконкой на панели инструментов
      setup_toolbar

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
