# frozen_string_literal: true

begin
  require 'sketchup.rb'
rescue LoadError
  # Outside SketchUp environment
end
require 'json'
require 'fileutils'
# Апдейтер — из папки расширения (относительный путь).
Sketchup.require File.join(File.dirname(__FILE__), 'dn1sup_updater')

module Dn1sup
  def self.common_menu
    @common_menu ||= begin
      legacy = (defined?($dn1sup_common_menu) && $dn1sup_common_menu) || (defined?($dn1sup_menu) && $dn1sup_menu)
      legacy || UI.menu('Extensions').add_submenu('DN1Sup')
    end
  end

  module ExtManager
    ID      = 'dn1sup_ext_manager'
    VERSION = '0.17.1'
    REPO    = 'dn1test/dn1sup_ext_manager'
    ASSET   = "#{ID}.rbz"
    # Папка разработки задана в самом расширении: корень этого репозитория
    # (исходники — src/<id>.rb + src/<id>/). Кнопка проверки сначала смотрит
    # её, потом GitHub.
    DEV_DIR      = File.expand_path('../..', File.dirname(__FILE__)).freeze
    PAGE_URL     = "https://github.com/#{REPO}/releases"
    REGISTRY_URL = "https://raw.githubusercontent.com/#{REPO}/main/registry.json"

    # Автопоиск расширений: аккаунт/организация на GitHub, в которой ищутся
    # репозитории dn1sup_*, отсутствующие в registry.json. Менеджер и
    # расширения связаны только этим именем — каждое расширение живёт в своём
    # репозитории и обновляется независимо.
    OWNER = 'dn1test'
    DISCOVERY_INTERVAL = 24 * 60 * 60
    # Проверка существования репозитория (repo_meta) при принудительном
    # обновлении — не чаще раза в 10 минут: экономит квоту GitHub API (60
    # req/час без токена), иначе каждое нажатие «Обновить» съедало ~9 запросов
    # только на meta и упиралось в 403.
    REPO_CHECK_TTL = 10 * 60
    CACHE_MUTEX = Mutex.new

    PLUGIN_DIR   = File.dirname(__FILE__).freeze
    HTML_PATH    = File.join(PLUGIN_DIR, 'html', 'index.html').freeze
    ICON_DIR     = File.join(PLUGIN_DIR, 'icons').freeze
    TOOLBAR_NAME = 'DN1Sup Extension Store'
    CMD_TOOLTIP  = 'DN1Sup Extension Store — каталог, установка и обновление расширений'
    # Актуальная версия формата снапшота релизов (см. save/load_release_snapshot).
    SNAPSHOT_VERSION = 4

    @dialog = nil
    @release_cache = {}   # repo => предлагаемый (новейший стабильный) релиз
    @releases_cache = {}  # repo => [релизы] — полный список для статусов
    @discovered_entries = [] # найденные на GitHub расширения вне registry.json
    @commits_cache = {}   # repo => {'installed'=>..,'offered'=>..,'messages'=>[...]}
    # Верхняя секция CHANGELOG.md из ветки main репозитория (repo => текст):
    # резервный источник «Что нового», когда у релиза пустое тело.
    @changelog_md_cache = {}
    # Результаты проверки существования репозиториев на GitHub:
    # repo => {'status'=>'ok'|'gone'|'renamed','renamed_to'=>'','checked_at'=>unixtime}.
    # gone/renamed — карточки убираются из установки/обновлений (установленные
    # остаются с пометкой), 'ok' — репозиторий жив (в т.ч. пересоздан).
    @stale_repos = {}
    # Состояние фоновой проверки (для кнопки «Обновить»):
    # повторные нажатия коалесцируются, а не плодят параллельные обходы.
    @fetching = false
    @pending_force = false
    # Сводка последней проверки для UI: сколько репозиториев опрошено,
    # какие не ответили (сеть/лимиты), когда проверено и дата снапшота.
    @sync_status = { 'fetching' => false, 'fetched' => 0, 'total' => 0,
                     'failed' => [], 'checked_at' => 0, 'snapshot_saved_at' => 0 }

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
      if raw.nil?
        # Сетевой фолбэк — один раз за сессию (успех или неудача): реестр без
        # файла на диске — аварийный режим, и повторные таймауты на каждом
        # рендере каталога замораживали бы UI.
        unless instance_variable_defined?(:@registry_net_fetch)
          @registry_net_fetch = Dn1sup::Updater.fetch_text(REGISTRY_URL)
        end
        raw = @registry_net_fetch
      end
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

    # Уникализация записей каталога по id и repo (первая копия выигрывает).
    # Защита от накопившихся дублей в @discovered_entries (исторические
    # снапшоты, повторные запуски автопоиска): карточки не должны плодиться.
    def uniq_entries(entries)
      seen = {}
      entries.find_all do |e|
        next false unless e.is_a?(Hash)

        key = e['id'].to_s
        repo = e['repo'].to_s
        key = repo if key.empty?
        next false if key.empty?
        next false if seen[key] || (repo && seen[repo])

        seen[key] = true
        seen[repo] = true if repo
        true
      end
    end

    # Полный список записей каталога: явный registry.json + найденные на
    # GitHub расширения, которых в реестре нет. Реестр первичен: найденное
    # дополняет, но не заменяет. Скрытые репозитории отфильтровываются,
    # записи уникализируются (в т.ч. внутри самого списка найденного).
    def merged_entries
      entries = load_registry
      known = {}
      entries.each do |e|
        known[e['id'].to_s] = true
        known[e['repo'].to_s] = true
      end
      @discovered_entries.each do |e|
        next if known[e['repo'].to_s] || known[e['id'].to_s]

        known[e['id'].to_s] = true
        known[e['repo'].to_s] = true
        entries << e
      end
      entries = uniq_entries(entries)
      hidden = hidden_repos
      hidden.empty? ? entries : entries.reject { |e| hidden.include?(e['repo'].to_s) }
    end

    # Запись каталога по id — и из реестра, и среди найденных (установка,
    # удаление и имена работают для обоих источников).
    def find_entry(id)
      merged_entries.find { |e| e['id'].to_s == id.to_s }
    end

    # Репозиторий удалён или переименован на GitHub (по данным repo_meta).
    def stale?(repo)
      info = @stale_repos[repo.to_s]
      info.is_a?(Hash) && %w[gone renamed].include?(info['status'].to_s)
    rescue StandardError
      false
    end

    # Статус stale-репозитория: 'gone' / 'renamed' / '' (жив или не проверялся).
    def stale_status(repo)
      info = @stale_repos[repo.to_s]
      info.is_a?(Hash) ? info['status'].to_s : ''
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

    # Записывает результат проверки репозитория (главный поток).
    # gone/renamed: чистятся кэши релизов/коммитов и найденные записи
    # репозитория — карточки собираются заново уже без них (установленные
    # остаются с пометкой repo_status). Возвращает true, если статус изменился.
    def mark_stale_repo(repo, mark)
      repo_str = repo.to_s
      prev = @stale_repos[repo_str].is_a?(Hash) ? @stale_repos[repo_str]['status'].to_s : ''
      @stale_repos[repo_str] = mark
      status = mark['status'].to_s
      return false unless %w[gone renamed].include?(status)

      if status != prev
        store_log(case status
                  when 'gone'
                    "репозиторий #{repo_str} недоступен на GitHub (удалён) — убран из каталога"
                  else
                    "репозиторий #{repo_str} переименован в #{mark['renamed_to']} — запись каталога обновляется"
                  end)
      end
      @release_cache.delete(repo_str)
      @releases_cache.delete(repo_str)
      @commits_cache.delete(repo_str)
      @discovered_entries.reject! { |e| e.is_a?(Hash) && e['repo'].to_s == repo_str }
      status != prev
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      false
    end

    # Применяет результаты проверки репозиториев из фоновой загрузки
    # (Hash { repo => результат Dn1sup::Updater.repo_meta }). Результат nil
    # (сеть/лимиты) ничего не меняет: прежняя пометка сохраняется.
    def apply_repo_status(updates)
      return unless updates.is_a?(Hash)

      now = Time.now.to_i
      updates.each do |repo, meta|
        repo_str = repo.to_s
        next if repo_str.empty? || !meta.is_a?(Hash)

        mark =
          if meta[:exists]
            if meta[:renamed]
              { 'status' => 'renamed', 'renamed_to' => meta[:repo].to_s, 'checked_at' => now }
            else
              { 'status' => 'ok', 'renamed_to' => '', 'checked_at' => now }
            end
          else
            { 'status' => 'gone', 'renamed_to' => '', 'checked_at' => now }
          end
        mark_stale_repo(repo_str, mark)
      end
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
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
      # Повторные репозитории (пагинация GitHub, гонки параллельных запросов)
      # не проходят: одна запись на repo.
      found = uniq_entries(found)
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
        if rel.is_a?(Hash) && rel.key?('tag_name')
          CACHE_MUTEX.synchronize { @release_cache[repo_str] = rel }
        end
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
          offered = Dn1sup::Updater.choose_release(list)
          CACHE_MUTEX.synchronize do
            @releases_cache[repo_str] = list
            @release_cache[repo_str] = offered if offered
          end
        end
      end
      @releases_cache[repo_str] || []
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      []
    end

    # Предлагаемый релиз для показа и установки — единый источник истины:
    # новейший стабильный из списка; фолбэк — одиночный /releases/latest
    # (когда список недоступен, а одиночный запрос прошёл). Раньше каталог
    # показывал choose_release, а установка ставила /latest — при нестандартной
    # публикации это были разные теги.
    def offered_release(repo, force = false)
      repo_str = repo.to_s
      list = releases_list(repo_str, force)
      offered = Dn1sup::Updater.choose_release(list)
      return offered if offered

      rel = latest_release(repo_str, force)
      rel.is_a?(Hash) && rel.key?('tag_name') ? rel : nil
    end

    # Дата сохранения снапшота (unixtime) — для пометки «данные от …» в UI.
    def snapshot_saved_at
      path = snapshot_path
      return @sync_status['snapshot_saved_at'].to_i if path.nil?

      if File.file?(path)
        begin
          data = JSON.parse(File.read(path))
          return data['saved_at'].to_i if data.is_a?(Hash) && data['saved_at'].to_i > 0
        rescue StandardError
          nil
        end
        begin
          return File.mtime(path).to_i
        rescue StandardError
          0
        end
      end
      @sync_status['snapshot_saved_at'].to_i
    end

    # Сводка синхронизации для push_state (UI показывает «проверено X/Y»).
    def sync_payload
      {
        'fetching' => !!@fetching,
        'fetched' => @sync_status['fetched'].to_i,
        'total' => @sync_status['total'].to_i,
        'failed' => Array(@sync_status['failed']),
        'checked_at' => @sync_status['checked_at'].to_i,
        'snapshot_saved_at' => snapshot_saved_at
      }
    end

    # Базовая дата установки для расширений, поставленных вручную (installed_at
    # неизвестна): фиксируем «сейчас», чтобы последующие переиздания без бампа
    # версии распознавались как switch. Вызывается на главном потоке.
    def seed_installed_at_baseline(products)
      return unless defined?(Sketchup)

      Array(products).each do |p|
        next unless p.is_a?(Hash) && p['is_installed']
        next unless Dn1sup::Updater.installed_at(p['id'].to_s).nil?

        Dn1sup::Updater.mark_installed(p['id'].to_s)
      end
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
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
    # расширений, логов правок и статусов репозиториев. Формат v4:
    # { "version" => 4, "releases" => { repo => [release, ...] },
    #   "discovered" => [entry, ...], "commits" => { repo => {...} },
    #   "stale" => { repo => {'status'=>..,'renamed_to'=>..,'checked_at'=>..} } } —
    # до 10 релизов на репозиторий (статусы и changelog берутся из них;
    # установка всегда делает свежий запрос).
    def save_release_snapshot
      path = snapshot_path
      return unless path

      data = {
        'version'    => SNAPSHOT_VERSION,
        'saved_at'   => Time.now.to_i,
        'releases'   => {},
        'discovered' => @discovered_entries,
        'commits'    => @commits_cache,
        'stale'      => @stale_repos
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
      @sync_status['snapshot_saved_at'] = data['saved_at'].to_i
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    # Загружает снапшот в кэши (только если кэш пуст — не затирая свежие
    # данные). Понимает формат v4 (v3 + статусы репозиториев) и старые:
    # v3 (списки релизов + найденные + коммиты), v2 (списки релизов) и
    # v1 (repo => релиз, заворачивается в список из одного элемента).
    def load_release_snapshot
      path = snapshot_path
      return unless path && File.file?(path) && @release_cache.empty?

      data = JSON.parse(File.read(path))
      return unless data.is_a?(Hash)

      # Снапшот более нового формата не читаем по догадкам: прежние поля
      # могут иметь другой смысл.
      return if data['version'].to_i > SNAPSHOT_VERSION

      if data['discovered'].is_a?(Array) && @discovered_entries.empty?
        # Самовосстановление: найденные записи мёртвых/перемещённых репозиториев
        # (снапшот старой версии или внешний мусор) не resurrect-им. Дубли
        # (исторические снапшоты/повторные записи) схлопываем по repo/id.
        stale = data['stale'].is_a?(Hash) ? data['stale'] : {}
        @discovered_entries = uniq_entries(data['discovered'].find_all do |e|
          next false unless e.is_a?(Hash) && !e['id'].to_s.empty? && !e['repo'].to_s.empty?

          info = stale[e['repo'].to_s]
          !(info.is_a?(Hash) && %w[gone renamed].include?(info['status'].to_s))
        end)
      end
      if data['commits'].is_a?(Hash) && @commits_cache.empty?
        @commits_cache = data['commits']
      end
      if data['stale'].is_a?(Hash) && @stale_repos.empty?
        data['stale'].each do |repo, info|
          next unless info.is_a?(Hash) && %w[ok gone renamed].include?(info['status'].to_s)

          @stale_repos[repo.to_s] = {
            'status'     => info['status'].to_s,
            'renamed_to' => info['renamed_to'].to_s,
            'checked_at' => info['checked_at'].to_i
          }
        end
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

    # Верхняя (свежая) секция CHANGELOG.md: от первого заголовка с номером
    # версии до заголовка того же или более высокого уровня. Строки заголовков
    # выбрасываются — карточке нужна суть изменений, а не «[0.2.0] — дата».
    def latest_changelog_section(md)
      text = md.to_s
      head = text.match(/^[#]{1,6}\s+[^\n]*\d+\.\d+[^\n]*$/)
      return '' unless head

      level = head.to_s[/\A#+/].length
      tail = text[head.end(0)..].to_s
      nxt = tail.match(/^#{'[#]' * level}\s+/)
      section = nxt ? tail[0...nxt.begin(0)] : tail
      section.gsub(/^[#]{1,6}\s+[^\n]*(\n|\z)/, '').strip
    end

    # Извлечение персонального лога изменений для конкретного расширения.
    # Источники по приоритету: тело предлагаемого релиза на GitHub; последний
    # известный лог — первый релиз списка с непустым телом (пользователь должен
    # видеть, что изменилось, даже если свежий релиз собран без тела); поле
    # 'changelog' записи реестра; верхняя секция CHANGELOG.md из ветки main
    # репозитория (кэшируется раз за сессию в fetch_and_render) — все текущие
    # релизы dn1sup_* созданы без тела, поэтому секция CHANGELOG — основной
    # запасной источник. Для показа в приложении — краткая суть (1-3 строки,
    # без markdown) через Dn1sup::Updater.short_notes; подробности остаются
    # в CHANGELOG и на GitHub.
    def extract_extension_changelog(body, entry, repo = nil, release_list = nil)
      id   = entry['id'].to_s
      name = entry['name'].to_s
      fallback = 'Лог изменений для этого расширения отсутствует.'

      # Строка «Что нового» не должна исчезать: у релиза без тела показываем
      # последний известный лог (списки релизов идут от новых к старым).
      if !body.is_a?(String) || body.strip.empty?
        known = Array(release_list).find { |r| r.is_a?(Hash) && !r['body'].to_s.strip.empty? }
        body = known['body'] if known
      end

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
          entry_changelog = entry['changelog'].to_s.strip
          entry_changelog.empty? ? latest_changelog_section(@changelog_md_cache[repo.to_s]) : entry_changelog
        end

      return fallback if raw.strip.empty?

      Dn1sup::Updater.short_notes(raw)
    end

    # Сбор сводки по всем продуктам для HTML интерфейса.
    # check_releases: false — мгновенный оффлайн-сбор из registry.json и локальных плагинов.
    # check_releases: true — с сетевым запросом к GitHub API.
    # releases: опциональный Hash { repo => release_data } для объединения данных.
    # release_lists: опциональный Hash { repo => [release, ...] } для статусов.
    def collect_products_data(force = false, check_releases: false, releases: nil, release_lists: nil)
      ensure_updater!
      entries = merged_entries
      return [] if entries.empty?

      rel_map  = releases || @release_cache || {}
      list_map = release_lists || @releases_cache || {}

      entries.map do |entry|
        id   = entry['id'].to_s
        repo = entry['repo'].to_s
        name = entry['name'].to_s.empty? ? id : entry['name'].to_s

        # Репозиторий удалён/переименован: кэши релизов игнорируем (релизы
        # нового репозитория по ключу старого показывали бы ложное обновление),
        # сетевые запросы по старому имени не тратятся.
        repo_stale = stale?(repo)
        if repo_stale
          release = {}
          rel_list = []
        else
          release = check_releases ? latest_release(repo, force) : (rel_map[repo.to_s] || {})
          rel_list = list_map[repo.to_s].is_a?(Array) ? list_map[repo.to_s] : []
        end

        # Найденные на GitHub расширения показываем, только когда известны
        # их релизы: без них нельзя ни версию показать, ни .rbz установить.
        next nil if entry['discovered'] && rel_list.empty?

        offered = Dn1sup::Updater.choose_release(rel_list)
        offered = release if offered.nil? && release.is_a?(Hash) && release.key?('tag_name')

        installed_ver = installed_version(entry)
        is_installed = !installed_ver.to_s.empty?

        # Локальная папка разработки (путь задан в самом расширении):
        # версия — для кнопки «проверить обновление» (круг со стрелками).
        dev_dir = repo_stale ? nil : dev_dir_for(entry)
        dev_ver = dev_dir ? Dn1sup::Updater.local_dev_version(dev_dir, id) : ''

        # Мёртвый репозиторий: неустановленные карточки исчезают из каталога
        # (и из вкладки «Обновления»), установленные остаются с пометкой.
        next nil if repo_stale && !is_installed

        latest_tag   = offered ? offered['tag_name'].to_s : ''
        release_body = offered ? offered['body'].to_s : ''
        published_at = offered ? offered['published_at'].to_s : ''
        release_url  = offered ? offered['html_url'].to_s : ''

        # Находим .rbz ассет в релизе конкретного репозитория
        rbz_asset  = find_rbz_asset(offered, entry['asset'])
        asset_name = rbz_asset ? rbz_asset['name'].to_s : (entry['asset'] || "#{id}.rbz").to_s
        # Есть ли .rbz в предлагаемом релизе: тег подняли, а архив ещё не
        # собран — обновление видно, но установка упадёт. Флаг нужен UI,
        # чтобы честно показать «релиз без архива».
        has_asset = !rbz_asset.nil?
        has_asset = true if offered.nil?

        # Описание: из репозитория/релиза или из реестра
        desc = entry['description'].to_s
        if desc.empty? && offered && !offered['name'].to_s.empty? && offered['name'] != latest_tag
          desc = offered['name'].to_s
        end

        # Автор: из реестра, фолбэк — владелец репозитория на GitHub
        author = entry['author'].to_s
        author = repo.split('/').first.to_s if author.empty?

        # Персональный лог изменений для этого расширения
        changelog = extract_extension_changelog(release_body, entry, repo, rel_list)

        # Актуальная версия расширения: из тега релиза репозитория либо из реестра
        ext_target_ver = !latest_tag.empty? ? latest_tag.sub(/\Av/i, '') : entry['version'].to_s

        # Статус относительно предлагаемого релиза: 'update' / 'switch' / 'current' / nil.
        # Для переизданных релизов без бампа версии — дата установки текущей сборки.
        installed_at = Dn1sup::Updater.installed_at(id) if is_installed
        status = safe_product_status(installed_ver, offered, rel_list, installed_at)
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
          'author'            => author,
          'repo'              => repo,
          'asset'             => asset_name,
          'discovered'        => !!entry['discovered'],
          'repo_status'       => repo_stale ? stale_status(repo) : '',
          'installed_version' => installed_ver,
          'is_installed'      => is_installed,
          'latest_version'    => ext_target_ver.empty? ? '—' : ext_target_ver,
          'has_update'        => has_update,
          'has_asset'         => has_asset,
          'status'            => status.to_s,
          'dev_available'     => !dev_dir.nil?,
          'dev_version'       => dev_ver.to_s,
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

    # ---- Локальная папка разработки -----------------------------------------

    # Путь к локальной папке задаётся в самом расширении: поле dev_path /
    # dev_dir записи реестра первично, дальше — ENV и соседние папки
    # (см. Dn1sup::Updater.resolve_dev_dir). nil = папки нет, обновление
    # только из GitHub.
    def dev_dir_for(entry_or_id)
      id = entry_or_id.is_a?(Hash) ? entry_or_id['id'].to_s : entry_or_id.to_s
      hint = ''
      if entry_or_id.is_a?(Hash)
        hint = (entry_or_id['dev_path'] || entry_or_id['dev_dir']).to_s
      end
      cfg = { id: id }
      cfg[:dev_dir] = hint unless hint.empty?
      Dn1sup::Updater.resolve_dev_dir(cfg)
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      nil
    end

    # Версия расширения в локальной папке ('' = папки нет или версия не читается).
    def local_dev_version_for(entry_or_id)
      id = entry_or_id.is_a?(Hash) ? entry_or_id['id'].to_s : entry_or_id.to_s
      dir = dev_dir_for(entry_or_id)
      dir ? Dn1sup::Updater.local_dev_version(dir, id) : ''
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      ''
    end

    # ---- Совместимость копий апдейтера --------------------------------------
    #
    # Файл dn1sup_updater.rb лежит в КАЖДОМ расширении DN1Sup, а в память
    # SketchUp загружается один общий модуль (кто встал последним — того
    # и методы). После обновления менеджера в Plugins соседствуют копии
    # разных версий: вызов нового кода (kwargs) против старого метода ронял
    # установку с "wrong number of arguments (given 4, expected 3)".
    # ensure_updater! догружает bundled-копию менеджера, если она новее
    # загруженной; safe_*-обёртки деградируют к старому поведению, если
    # догрузка невозможна.

    # Версия bundled-копии апдейтера (рядом с main.rb). 0 = копия без
    # константы UPDATER_VERSION (старая).
    def bundled_updater_version
      return @bundled_updater_version if defined?(@bundled_updater_version) && !@bundled_updater_version.nil?

      @bundled_updater_version = begin
        src = File.read(File.join(PLUGIN_DIR, 'dn1sup_updater.rb'))
        m = src.match(/UPDATER_VERSION\s*=\s*(\d+)/)
        m ? m[1].to_i : 0
      rescue StandardError
        0
      end
    end

    # Догружает bundled-копию апдейтера, если загруженный модуль старше.
    # Вызывать после загрузки всех расширений (perform_install,
    # perform_check_update, collect_products_data), а не при старте.
    def ensure_updater!
      have = defined?(Dn1sup::Updater::UPDATER_VERSION) ? Dn1sup::Updater::UPDATER_VERSION.to_i : 0
      need = bundled_updater_version
      return if have >= need || need <= 0

      path = File.join(PLUGIN_DIR, 'dn1sup_updater.rb')
      return unless File.file?(path)

      load path
      store_log("апдейтер в памяти обновлён: v#{have} -> v#{need}")
    rescue StandardError, ScriptError => e
      Dn1sup::Updater.log_error(e)
    end

    # pick_freshest с фолбэком на старый 3-аргументный метод (без дат).
    def safe_pick_freshest(installed_ver, local_ver, github_ver, installed_at: nil, github_time: nil, local_time: nil)
      ensure_updater!
      Dn1sup::Updater.pick_freshest(installed_ver, local_ver, github_ver,
                                    installed_at: installed_at,
                                    github_time: github_time,
                                    local_time: local_time)
    rescue ArgumentError => e
      raise unless e.message =~ /wrong number of arguments|unknown keyword/

      Dn1sup::Updater.pick_freshest(installed_ver, local_ver, github_ver)
    end

    # product_status с фолбэком на старый 3-аргументный метод (без даты).
    def safe_product_status(installed_ver, offered, list, installed_at)
      ensure_updater!
      Dn1sup::Updater.product_status(installed_ver, offered, list, installed_at: installed_at)
    rescue ArgumentError => e
      raise unless e.message =~ /wrong number of arguments|unknown keyword/

      Dn1sup::Updater.product_status(installed_ver, offered, list)
    end

    # install_from_url с фолбэком на метод без kwargs id:.
    def safe_install_from_url(url, what, silent, id)
      ensure_updater!
      Dn1sup::Updater.install_from_url(url, what, silent, id: id)
    rescue ArgumentError => e
      raise unless e.message =~ /wrong number of arguments|unknown keyword/

      Dn1sup::Updater.install_from_url(url, what, silent)
    end

    # local_dev_mtime есть только в новых копиях апдейтера.
    def safe_local_mtime(dev_dir, id)
      return nil if dev_dir.to_s.empty?
      return nil unless Dn1sup::Updater.respond_to?(:local_dev_mtime)

      Dn1sup::Updater.local_dev_mtime(dev_dir, id)
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      nil
    end

    # ---- Установка / Обновление / Удаление --------------------------------

    # Проверка обновления карточки (кнопка «круг со стрелками»): версия
    # сначала ищется в локальной папке разработки, потом на GitHub —
    # ставится та, что свежее. При равном номере версии свежесть — по
    # дате/времени (mtime файлов папки / published_at релиза против даты
    # установки). Папки нет — только GitHub.
    def perform_check_update(id)
      ensure_updater!
      entry = find_entry(id)
      unless entry
        store_log("проверка '#{id}': расширение не найдено в реестре")
        return { 'ok' => false, 'error' => "Расширение «#{id}» не найдено в реестре." }
      end

      repo = entry['repo'].to_s
      name = entry['name'].to_s.empty? ? id : entry['name'].to_s

      if stale?(repo)
        store_log("проверка '#{id}': репозиторий #{repo} недоступен (удалён или переименован)")
        return { 'ok' => false,
                 'error' => "#{name}: репозиторий #{repo} недоступен на GitHub (удалён или переименован)." }
      end

      installed_ver = installed_version(entry)
      dev_dir = dev_dir_for(entry)
      local_ver = dev_dir ? Dn1sup::Updater.local_dev_version(dev_dir, id) : ''
      local_time = dev_dir ? safe_local_mtime(dev_dir, id) : nil
      release = offered_release(repo, true)
      github_ver = release.is_a?(Hash) && release.key?('tag_name') ? release['tag_name'].to_s.sub(/\Av/i, '') : ''
      github_time = release.is_a?(Hash) ? Dn1sup::Updater.release_time(release) : nil
      installed_at = Dn1sup::Updater.installed_at(id)

      if local_ver.empty? && github_ver.empty?
        store_log("проверка '#{id}': ни локальной папки, ни релизов #{repo}")
        return { 'ok' => false,
                 'error' => "#{name}: не удалось проверить обновления — нет ни локальной папки, ни релизов на GitHub." }
      end

      pick = safe_pick_freshest(installed_ver, local_ver, github_ver,
                                installed_at: installed_at,
                                github_time: github_time,
                                local_time: local_time)
      if pick == :current
        detail = []
        detail << "локально #{local_ver}" unless local_ver.empty?
        detail << "GitHub #{github_ver}" unless github_ver.empty?
        store_log("проверка '#{id}': актуальная версия #{installed_ver}#{detail.empty? ? '' : " (#{detail.join(', ')})"}")
        return { 'ok' => true,
                 'message' => "#{name}: у вас уже установлена актуальная версия (#{installed_ver})." }
      end

      res = perform_install(id)
      if res['ok'] && pick == :local
        store_log("проверка '#{id}': установлено из локальной папки v#{local_ver}")
      end
      res
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      { 'ok' => false, 'error' => "Исключение при проверке: #{e.message} (подробности — в dn1sup_updater.log)" }
    end

    # Установка расширения по ID (в том числе найденного на GitHub)
    def perform_install(id)
      ensure_updater!
      entry = find_entry(id)
      unless entry
        store_log("установка '#{id}': расширение не найдено в реестре")
        return { 'ok' => false, 'error' => "Расширение «#{id}» не найдено в реестре." }
      end

      repo = entry['repo'].to_s
      name = entry['name'].to_s.empty? ? id : entry['name'].to_s

      if stale?(repo)
        store_log("установка '#{id}': репозиторий #{repo} недоступен (удалён или переименован)")
        return { 'ok' => false,
                 'error' => "#{name}: репозиторий #{repo} недоступен на GitHub (удалён или переименован)." }
      end

      release = offered_release(repo, true)
      installed_ver = installed_version(entry)
      dev_dir = dev_dir_for(entry)
      local_ver = (dev_dir && !dev_dir.empty?) ? Dn1sup::Updater.local_dev_version(dev_dir, id) : ''
      local_time = (dev_dir && !dev_dir.empty?) ? safe_local_mtime(dev_dir, id) : nil
      github_ver = release.is_a?(Hash) && release.key?('tag_name') ? release['tag_name'].to_s.sub(/\Av/i, '') : ''
      github_time = release.is_a?(Hash) ? Dn1sup::Updater.release_time(release) : nil
      installed_at = Dn1sup::Updater.installed_at(id)

      # Локальная папка свежее GitHub и установленной — ставим из неё
      # (.rbz собирается на лету). Свежесть — по номеру версии, а при равном
      # номере — по дате/времени (mtime файлов vs дата установки).
      # Папки нет — только GitHub-путь ниже.
      if safe_pick_freshest(installed_ver, local_ver, github_ver,
                              installed_at: installed_at,
                              github_time: github_time,
                              local_time: local_time) == :local
        ok = Dn1sup::Updater.install_from_local_dir(dev_dir, id, name)
        if ok
          installed_ver = local_ver
          Sketchup.write_default('DN1Sup ExtManager', "installed_#{id}", installed_ver) if defined?(Sketchup)
          store_log("установлен/обновлён #{id} -> v#{installed_ver} (локальная папка #{dev_dir})")
          msg = "Расширение «#{name}» (v#{installed_ver}) установлено из локальной папки! Перезапустите SketchUp для полной загрузки компонентов."
          return { 'ok' => true, 'message' => msg }
        else
          store_log("установка #{id} из локальной папки НЕУДАЧНА")
          return { 'ok' => false, 'error' => "Не удалось установить «#{name}» из локальной папки (#{dev_dir})." }
        end
      end

      unless release.is_a?(Hash) && release.key?('tag_name')
        store_log("установка '#{id}': релизы #{repo} недоступны")
        return { 'ok' => false, 'error' => "#{name}: не удалось получить список релизов с GitHub." }
      end

      # Ищем .rbz ассет в предлагаемом релизе (тот же релиз, что показывает
      # каталог — см. offered_release)
      rbz_asset = find_rbz_asset(release, entry['asset'])
      url = rbz_asset ? rbz_asset['browser_download_url'] : Dn1sup::Updater.asset_url(release, entry['asset'].to_s)
      if url.to_s.empty?
        store_log("установка '#{id}': в релизе #{release['tag_name']} нет .rbz-ассета")
        return {
          'ok' => false,
          'error' => "#{name}: в последнем релизе (#{release['tag_name']}) не найден .rbz файл для установки."
        }
      end

      ok = safe_install_from_url(url, "#{name} (#{release['tag_name']})", true, id)
      if ok
        # Сохраняем актуальную версию из релиза репозитория
        installed_ver = release['tag_name'].to_s.sub(/\Av/i, '')
        installed_ver = entry['version'].to_s.sub(/\Av/i, '') if installed_ver.empty?
        Sketchup.write_default('DN1Sup ExtManager', "installed_#{id}", installed_ver) if defined?(Sketchup)
        store_log("установлен/обновлён #{id} -> v#{installed_ver} (#{repo})")
        msg = "Расширение «#{name}» (v#{installed_ver}) успешно установлено! Перезапустите SketchUp для полной загрузки компонентов."
        { 'ok' => true, 'message' => msg }
      else
        store_log("установка #{id} (#{repo}) НЕУДАЧНА: архив не установлен")
        { 'ok' => false, 'error' => "SketchUp не удалось установить архив расширения «#{name}»." }
      end
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      { 'ok' => false, 'error' => "Исключение при установке: #{e.message} (подробности — в dn1sup_updater.log)" }
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

      # id приходит из диалога и уходит в FileUtils.rm_rf: без белого списка
      # значение "."/".." снесло бы всю папку Plugins.
      unless id.to_s =~ /\Adn1sup_[a-z0-9_]+\z/
        store_log("удаление отклонено: некорректный id #{id.inspect}")
        return { 'ok' => false, 'error' => "Некорректный идентификатор расширения." }
      end
      unless find_entry(id)
        store_log("удаление '#{id}': расширение не найдено в реестре")
        return { 'ok' => false, 'error' => "Расширение «#{id}» не найдено в реестре." }
      end

      plugins_dir = Sketchup.find_support_file('Plugins')
      return { 'ok' => false, 'error' => 'Папка Plugins не найдена.' } unless plugins_dir && File.directory?(plugins_dir)

      rb_file = File.join(plugins_dir, "#{id}.rb")
      sub_dir = File.join(plugins_dir, id.to_s)

      # 1. Отключаем расширение в текущей сессии SketchUp
      if Sketchup.respond_to?(:extensions) && Sketchup.extensions
        # ExtensionManager не включает Enumerable — только each/[]/size.
        ext = nil
        Sketchup.extensions.each do |candidate|
          c_name = candidate.respond_to?(:name) ? candidate.name.to_s : ''
          c_id   = candidate.respond_to?(:id) ? candidate.id.to_s : ''
          if c_name.casecmp?(id.to_s) || c_id.casecmp?(id.to_s)
            ext = candidate
            break
          end
        end
        ext.uncheck if ext && ext.respond_to?(:uncheck)
      end

      # 2. Удаляем файлы с диска
      FileUtils.rm_f(rb_file) if File.file?(rb_file)
      FileUtils.rm_rf(sub_dir) if File.directory?(sub_dir)

      # 3. Сбрасываем кэш версий (включая installed_at — иначе после
      # переустановки старой сборки даты сравнивались бы с прошлой установкой)
      Sketchup.write_default('DN1Sup ExtManager', "installed_#{id}", nil)
      Sketchup.write_default('Dn1supUpdater', "last_#{id}", 0)
      Sketchup.write_default('Dn1supUpdater', "installed_at_#{id}", nil)

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
      seed_installed_at_baseline(local)
      store_debug("отрисовка каталога: #{local.is_a?(Array) ? local.size : 0} продуктов" \
                  "#{force ? ', force-обновление' : ''}")
      push_state(dlg, local)

      # 2. Фоновое обновление версий через сеть (только сетевые запросы, без SketchUp API в потоке)
      repos = merged_entries.map { |e| e['repo'].to_s }.uniq.reject(&:empty?)
      return if repos.empty?

      if @fetching
        # Повторное нажатие «Обновить» во время обхода: второй параллельный
        # обход не запускаем (гонка merge! + перезапись push_state), а
        # запоминаем желание и доберём свежие данные по завершении текущего.
        @pending_force = true if force
        store_debug('обновление уже идёт — повторный запрос коалесцирован')
        return
      end
      @sync_status['total'] = repos.size
      @fetching = true
      @sync_status['fetching'] = true

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
          result = { 'releases' => {}, 'discovered' => nil, 'stale' => {}, 'changelogs' => {}, 'failed' => [] }
          now = Time.now.to_i
          repos.each do |repo|
            repo_str = repo.to_s
            next if repo_str.empty?

            # Существование репозитория: раз в сутки, при force — не чаще раза
            # в REPO_CHECK_TTL (экономия квоты GitHub API).
            info = @stale_repos[repo_str]
            meta = nil
            meta_due = force ? (!info.is_a?(Hash) || (now - info['checked_at'].to_i) >= REPO_CHECK_TTL) : (!info.is_a?(Hash) || (now - info['checked_at'].to_i) >= DISCOVERY_INTERVAL)
            if meta_due
              meta = Dn1sup::Updater.repo_meta(repo_str)
              result['stale'][repo_str] = meta
            end
            dead = meta.is_a?(Hash) ? (meta[:exists] == false || meta[:renamed]) : stale?(repo_str)
            # Мёртвый/перемещённый репозиторий на релизы не опрашиваем:
            # редирект переименования вернул бы релизы нового репозитория
            # под старым именем.
            next if dead

            list = releases_list(repo_str, force)
            if list.empty?
              # Пустой список — это неуспех (сеть/лимиты), а не «релизов нет»:
              # фиксируем для сводки, успешный кэш при этом не затёрт.
              result['failed'] << repo_str
            else
              result['releases'][repo_str] = list
            end

            # Резерв «Что нового»: CHANGELOG.md из ветки main — раз за сессию
            # на репозиторий. Сеть — только в этом фоновом потоке. nil (таймаут,
            # другая сетевая ошибка) не кэшируем — retry при следующем обновлении.
            unless @changelog_md_cache.key?(repo_str)
              md = Dn1sup::Updater.fetch_text(
                "https://raw.githubusercontent.com/#{repo_str}/main/CHANGELOG.md"
              )
              result['changelogs'][repo_str] = md unless md.nil?
            end
          end
          renamed_found = result['stale'].values.any? { |m| m.is_a?(Hash) && m[:renamed] }
          # Переименование обнаружено вне окна автопоиска — новый репозиторий
          # ищем сразу, не дожидаясь следующего суточного скана.
          result['discovered'] = discover_repos if want_discovery || renamed_found
          result
        end,
        lambda do |fetched_raw|
          fetched = fetched_raw.is_a?(Hash) ? fetched_raw : {}
          lists = fetched['releases'].is_a?(Hash) ? fetched['releases'] : {}
          failed = fetched['failed'].is_a?(Array) ? fetched['failed'] : []
          # Сводка видна и без debug-флага: иначе тихий 403 выглядел как
          # «обновлений нет».
          store_log("проверка обновлений: получено #{lists.size}/#{repos.size}" \
                    "#{failed.any? ? " (недоступны: #{failed.join(', ')})" : ''}")

          # Пометки удалённых/переименованных применяем ДО слияния релизов и
          # найденного: они чистят кэши и @discovered_entries под эти репозитории.
          apply_repo_status(fetched['stale'])

          added_repos = []
          new_entries = fetched['discovered']
          if new_entries.is_a?(Array)
            known = {}
            merged_entries.each do |e|
              known[e['id'].to_s] = true
              known[e['repo'].to_s] = true
            end
            # Дедупликация и внутри самой пачки (повторы автопоиска),
            # и против уже известных записей.
            added = []
            new_entries.each do |e|
              next unless e.is_a?(Hash)

              id_key   = e['id'].to_s
              repo_key = e['repo'].to_s
              next if (known[id_key] || known[repo_key]) || added.any? { |a| a['id'].to_s == id_key || a['repo'].to_s == repo_key }

              known[id_key] = true
              known[repo_key] = true
              added << e
            end
            @discovered_entries.concat(added) unless added.empty?
            mark_discovered
            store_debug("автопоиск: новых расширений #{added.size}") unless added.empty?
            added_repos = added.map { |e| e['repo'].to_s }.reject(&:empty?)
          end

          if lists.is_a?(Hash) && lists.any?
            CACHE_MUTEX.synchronize { @releases_cache.merge!(lists) }
          end
          changelogs = fetched['changelogs'].is_a?(Hash) ? fetched['changelogs'] : {}
          CACHE_MUTEX.synchronize { @changelog_md_cache.merge!(changelogs) } unless changelogs.empty?
          save_release_snapshot
          now = Time.now.to_i
          @sync_status['fetched'] = lists.size
          @sync_status['total'] = repos.size
          @sync_status['failed'] = failed
          @sync_status['checked_at'] = now
          if @dialog
            push_state(dlg, collect_products_data(false, check_releases: false))
          end

          missing = repos.size - lists.size
          if attempts_left > 0 && missing > 0 && @dialog
            fetch_and_render(dlg, repos - lists.keys, force, attempts_left: attempts_left - 1)
          elsif added_repos.any? && @dialog
            # Новонайденные расширения (в т.ч. на новом имени после
            # переименования) подтягивают релизы сразу, иначе карточки
            # появятся только при следующем открытии каталога.
            fetch_and_render(dlg, added_repos, force, attempts_left: 0)
          else
            @fetching = false
            @sync_status['fetching'] = false
            if @dialog
              push_state(dlg, collect_products_data(false, check_releases: false))
              fetch_commits_async(dlg)
            end
            if @pending_force && @dialog
              @pending_force = false
              send_products_to_dialog(force: true)
            else
              @pending_force = false
            end
          end
        end
      )
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      @fetching = false
      @sync_status['fetching'] = false
    end

    # Логи правок: для продуктов с обновлением/сменой версии подтягиваем
    # список коммитов между установленной и предлагаемой версиями
    # (compare API). Только сеть в фоне; результат — на главном потоке.
    #
    # Версии в каталоге хранятся без префикса, а теги бывают и без «v» —
    # полный тег берём из списка релизов, иначе compare по несуществующему
    # «v…» молча вернул бы пусто.
    def full_tag_name(repo, version)
      hit = @releases_cache[repo.to_s].to_a.find do |r|
        r.is_a?(Hash) && r['tag_name'].to_s.sub(/\Av/i, '') == version.to_s
      end
      hit ? hit['tag_name'] : "v#{version}"
    end

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
              item['repo'],
              full_tag_name(item['repo'], item['installed']),
              full_tag_name(item['repo'], item['offered']),
              limit: 15
            )
            result[item['repo']] = item.merge('messages' => msgs) unless msgs.empty?
          end
          result
        end,
        lambda do |fetched|
          next unless @dialog

          commits = fetched.is_a?(Hash) ? fetched : {}
          next if commits.empty?

          CACHE_MUTEX.synchronize { @commits_cache.merge!(commits) }
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
        'version'   => VERSION,
        'products'  => products.is_a?(Array) ? products : [],
        'sync'      => sync_payload
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
      when 'check_update'
        iid = parse_json(param)['id']
        notify_action_result(iid, 'check_update', perform_check_update(iid))
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

    # Разработка: перезагрузка файлов рабочей копии без перезапуска SketchUp
    # (один id — dev-варианта с суффиксом _dev больше нет).
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
      Sketchup.respond_to?(:version) && Sketchup.version.to_f >= 20.1
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
        Dn1sup::Updater.check_local_first!({ id: ID, repo: REPO, version: VERSION, asset: ASSET, dev_dir: DEV_DIR, force: true, async: true })
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
      # результат — ненавязчивое уведомление, без модальных диалогов).
      UI.start_timer(20, false) do
        Dn1sup::Updater.check_local_first!({ id: ID, repo: REPO, version: VERSION, asset: ASSET, dev_dir: DEV_DIR, async: true })
      end

      file_loaded(__FILE__)
    end
  end
end
