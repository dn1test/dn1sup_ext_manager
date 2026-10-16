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
    VERSION = '0.22.12'
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
    # Жёсткий предел одной проверки каталога: watchdog в прогресс-таймере
    # принудительно завершает зависший обход, чтобы кнопка «Проверить
    # обновления» не крутилась вечно (0/9 при мёртвой сети).
    FETCH_TIMEOUT = 120
    # Проверка существования репозитория (repo_meta) при принудительном
    # обновлении — не чаще раза в 10 минут: экономит квоту GitHub API (60
    # req/час без токена), иначе каждое нажатие «Обновить» съедало ~9 запросов
    # только на meta и упиралось в 403.
    REPO_CHECK_TTL = 10 * 60
    # Параллельный опрос репозиториев при проверке обновлений: сетевые
    # запросы IO-bound, GVL на сокетах отпускается — N воркеров дают
    # ускорение примерно в N раз вместо последовательного обхода.
    FETCH_CONCURRENCY = 6
    CACHE_MUTEX = Mutex.new

    PLUGIN_DIR   = File.dirname(__FILE__).freeze
    HTML_PATH    = File.join(PLUGIN_DIR, 'html', 'index.html').freeze
    ICON_DIR     = File.join(PLUGIN_DIR, 'icons').freeze
    TOOLBAR_NAME = 'DN1Sup Extension Store'
    CMD_TOOLTIP  = 'DN1Sup Extension Store — каталог, установка и обновление расширений'
    # Актуальная версия формата снапшота релизов (см. save/load_release_snapshot).
    SNAPSHOT_VERSION = 5

    @dialog = nil
    @release_cache = {}   # repo => предлагаемый (новейший стабильный) релиз
    @releases_cache = {}  # repo => [релизы] — полный список для статусов
    @discovered_entries = [] # найденные на GitHub расширения вне registry.json
    @commits_cache = {}   # repo => {'installed'=>..,'offered'=>..,'messages'=>[...]}
    # Центральный registry.json с GitHub (REGISTRY_URL, ветка main):
    # основа каталога поверх bundled-копии. Обновляется фоново, работает
    # и для неустановленных расширений.
    @remote_registry = []
    @remote_registry_at = 0
    # Per-repo дополнения из registry.json каждого расширения
    # (raw.githubusercontent.com/<repo>/main/registry.json):
    # id => {'data' => {...}, 'at' => unixtime}. Непустые поля дополняют
    # и обновляют центральную запись.
    @registry_meta_cache = {}
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
    # first_scan — блокирующее первое сканирование после установки:
    # каталог показывает полноэкранный прогресс до конца обхода.
    @sync_status = { 'fetching' => false, 'fetched' => 0, 'total' => 0,
                     'failed' => [], 'checked_at' => 0, 'snapshot_saved_at' => 0,
                     'first_scan' => false }

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

    # ---- Обновление каталога с GitHub (для всех, не только установленных) --

    # Разбор сырого текста registry.json в список записей (Array/Hash.extensions).
    def parse_registry_list(raw)
      text = raw.to_s.sub(/\A\xEF\xBB\xBF/, '')
      return [] if text.strip.empty?

      list = JSON.parse(text)
      list = list['extensions'] if list.is_a?(Hash) && list['extensions'].is_a?(Array)
      list.is_a?(Array) ? list.find_all { |e| e.is_a?(Hash) && !e['id'].to_s.empty? } : []
    rescue StandardError, ScriptError => e
      Dn1sup::Updater.log_error(e)
      []
    end

    # Пора ли тянуть центральный реестр: принудительно по кнопке либо
    # не чаще раза в сутки (pref last_remote_registry).
    def remote_registry_due?(force)
      return true if force
      return (@remote_registry_at.to_i <= 0 || @remote_registry.empty?) unless defined?(Sketchup)

      last = Sketchup.read_default('DN1Sup ExtManager', 'last_remote_registry', 0)
      (Time.now.to_i - last.to_i) >= DISCOVERY_INTERVAL
    rescue StandardError
      @remote_registry.empty?
    end

    def mark_remote_registry
      @remote_registry_at = Time.now.to_i
      return unless defined?(Sketchup)

      Sketchup.write_default('DN1Sup ExtManager', 'last_remote_registry', @remote_registry_at)
    rescue StandardError
      nil
    end

    # Чистая сетевая загрузка центрального реестра (вызывается в фоне).
    # Возвращает Array записей или nil (неудача — прежние данные сохраняются).
    def fetch_remote_registry_list
      raw = Dn1sup::Updater.fetch_text(REGISTRY_URL)
      return nil if raw.to_s.strip.empty?

      parse_registry_list(raw)
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      nil
    end

    # Пора ли обновлять per-repo метаданные записи.
    def registry_meta_due?(id, force, now = nil)
      return true if force

      now ||= Time.now.to_i
      hit = @registry_meta_cache[id.to_s]
      return true unless hit.is_a?(Hash) && hit['at'].to_i > 0

      (now - hit['at'].to_i) >= REPO_CHECK_TTL
    rescue StandardError
      true
    end

    # Наложение свежих полей поверх базовой записи. Пустые значения
    # ничего не затирают; id не меняется.
    OVERLAY_FIELDS = %w[name description author repo asset version changelog].freeze

    def overlay_entry(base, overlay)
      return base unless base.is_a?(Hash) && overlay.is_a?(Hash)

      merged = base.dup
      OVERLAY_FIELDS.each do |k|
        v = overlay[k]
        merged[k] = v if !v.nil? && !v.to_s.strip.empty?
      end
      merged
    end

    # Эффективный реестр: bundled-основа + центральный remote с GitHub +
    # per-repo дополнения из репозиториев расширений. Порядок важен:
    # центральный — основа, per-repo — точечные обновления поверх.
    def effective_registry_entries
      entries = load_registry
      index_by_id = {}
      index_by_repo = {}
      entries.each do |e|
        next unless e.is_a?(Hash)

        index_by_id[e['id'].to_s] = e unless e['id'].to_s.empty?
        index_by_repo[e['repo'].to_s] = e unless e['repo'].to_s.empty?
      end
      Array(@remote_registry).each do |r|
        next unless r.is_a?(Hash) && !r['id'].to_s.empty?

        hit = index_by_id[r['id'].to_s] || index_by_repo[r['repo'].to_s]
        if hit
          OVERLAY_FIELDS.each do |k|
            v = r[k]
            hit[k] = v if !v.nil? && !v.to_s.strip.empty?
          end
        else
          dup = r.dup
          entries << dup
          index_by_id[dup['id'].to_s] = dup
          index_by_repo[dup['repo'].to_s] = dup unless dup['repo'].to_s.empty?
        end
      end
      @registry_meta_cache.each_value do |hit|
        meta = hit.is_a?(Hash) ? hit['data'] : nil
        next unless meta.is_a?(Hash) && !meta['id'].to_s.empty?

        target = index_by_id[meta['id'].to_s] || index_by_repo[meta['repo'].to_s]
        if target
          OVERLAY_FIELDS.each do |k|
            v = meta[k]
            target[k] = v if !v.nil? && !v.to_s.strip.empty?
          end
        else
          dup = meta.dup
          entries << dup
          index_by_id[dup['id'].to_s] = dup
          index_by_repo[dup['repo'].to_s] = dup unless dup['repo'].to_s.empty?
        end
      end
      entries
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      load_registry
    end

    # Применяет результаты фоновой загрузки каталога (главный поток).
    # remote_list: Array (успех) / nil (не запрашивалось или неудача).
    # meta_map: { id => Hash записи из репозитория расширения }.
    def apply_registry_refresh(remote_list, meta_map)
      now = Time.now.to_i
      if remote_list.is_a?(Array)
        CACHE_MUTEX.synchronize do
          @remote_registry = remote_list.map { |e| e.is_a?(Hash) ? e.dup : e }
          @remote_registry_at = now
        end
        mark_remote_registry
        store_debug("реестр: центральный обновлён (#{remote_list.size} записей)")
      end
      if meta_map.is_a?(Hash) && !meta_map.empty?
        CACHE_MUTEX.synchronize do
          meta_map.each do |id, meta|
            next unless meta.is_a?(Hash) && !id.to_s.empty?

            prev = @registry_meta_cache[id.to_s]
            prev_data = prev.is_a?(Hash) && prev['data'].is_a?(Hash) ? prev['data'].dup : {}
            merged = prev_data
            merged['id'] = meta['id'].to_s unless meta['id'].to_s.empty?
            merged['id'] = id.to_s if merged['id'].to_s.empty?
            OVERLAY_FIELDS.each do |k|
              v = meta[k]
              merged[k] = v if !v.nil? && !v.to_s.strip.empty?
            end
            @registry_meta_cache[id.to_s] = { 'data' => merged, 'at' => now }
          end
        end
        store_debug("реестр: per-repo дополнения (#{meta_map.size})")
      end
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
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

    # Полный список записей каталога: эффективный реестр (bundled +
    # центральный с GitHub + per-repo дополнения) + найденные на
    # GitHub расширения, которых в реестре нет. Реестр первичен: найденное
    # дополняет, но не заменяет. Скрытые репозитории отфильтровываются,
    # записи уникализируются (в т.ч. внутри самого списка найденного).
    def merged_entries
      entries = effective_registry_entries
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
      @registry_meta_cache.delete_if { |_id, hit| hit.is_a?(Hash) && hit['data'].is_a?(Hash) && hit['data']['repo'].to_s == repo_str }
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
      effective_registry_entries.each do |e|
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
        'snapshot_saved_at' => snapshot_saved_at,
        'first_scan' => !!@sync_status['first_scan']
      }
    end

    # Первое открытие после установки: кэши пусты и снапшота нет —
    # нужен полный принудительный скан (релизы + автопоиск), а не тихий
    # офлайн-рендер пустого каталога.
    def first_run_scan?
      return false unless @release_cache.empty? && @releases_cache.empty?

      path = snapshot_path
      return true if path.nil?

      !File.file?(path)
    rescue StandardError
      false
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
    # расширений, логов правок, статусов репозиториев и свежих данных
    # каталога. Формат v5 (v4 + remote_registry/registry_meta):
    # { "version" => 5, "releases" => { repo => [release, ...] },
    #   "discovered" => [entry, ...], "commits" => { repo => {...} },
    #   "stale" => { repo => {...} },
    #   "remote_registry" => [entry, ...],
    #   "registry_meta" => { id => {'data'=>{...},'at'=>..} } } —
    # до 10 релизов на репозиторий (статусы и changelog берутся из них;
    # установка всегда делает свежий запрос).
    def save_release_snapshot
      path = snapshot_path
      return unless path

      data = {
        'version'         => SNAPSHOT_VERSION,
        'saved_at'        => Time.now.to_i,
        'releases'        => {},
        'discovered'      => @discovered_entries,
        'commits'         => @commits_cache,
        'stale'           => @stale_repos,
        'remote_registry' => @remote_registry,
        'registry_meta'   => @registry_meta_cache
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
    # данные). Понимает формат v5 (v4 + каталог с GitHub) и старые:
    # v4 (списки релизов + найденные + коммиты + статусы), v3 (без stale),
    # v2 (списки релизов) и v1 (repo => релиз).
    def load_release_snapshot
      path = snapshot_path
      return unless path && File.file?(path) && @release_cache.empty?

      data = JSON.parse(File.read(path))
      return unless data.is_a?(Hash)

      # Снапшот более нового формата не читаем по догадкам: прежние поля
      # могут иметь другой смысл.
      return if data['version'].to_i > SNAPSHOT_VERSION

      if data['remote_registry'].is_a?(Array) && @remote_registry.empty?
        list = data['remote_registry'].find_all { |e| e.is_a?(Hash) && !e['id'].to_s.empty? }
        @remote_registry = uniq_entries(list)
        @remote_registry_at = data['saved_at'].to_i
      end
      if data['registry_meta'].is_a?(Hash) && @registry_meta_cache.empty?
        data['registry_meta'].each do |id, hit|
          next unless hit.is_a?(Hash) && hit['data'].is_a?(Hash) && !id.to_s.empty?

            @registry_meta_cache[id.to_s] = {
              'data' => hit['data'],
              'at'   => hit['at'].to_i > 0 ? hit['at'].to_i : data['saved_at'].to_i
            }
        end
      end
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

    # Список id из JSON-параметра bulk-команд: {ids:[...]} / {id:'...'} / [...].
    def extract_ids(param)
      data = parse_json(param)
      ids = if data.is_a?(Hash) && data['ids'].is_a?(Array)
              data['ids']
            elsif data.is_a?(Array)
              data
            elsif data.is_a?(Hash) && data['id']
              [data['id']]
            else
              []
            end
      ids.map(&:to_s).reject(&:empty?).uniq
    rescue StandardError
      []
    end

    # Цели «Установить все» по текущему каталогу: неустановленные +
    # обновления (has_update / switch).
    def default_install_targets
      collect_products_data(false, check_releases: false)
        .select { |p| !p['is_installed'] || p['has_update'] || p['status'].to_s == 'switch' }
        .map { |p| p['id'].to_s }.reject(&:empty?).uniq
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      []
    end

    # Цели «Удалить все»: установленные, кроме самого менеджера.
    def default_uninstall_targets
      collect_products_data(false, check_releases: false)
        .select { |p| p['is_installed'] && p['id'].to_s != ID }
        .map { |p| p['id'].to_s }.reject(&:empty?).uniq
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      []
    end

    # Массовая установка/обновление. После каждого расширения пушит
    # bulk_progress (current/total + имя + итог шага), в конце возвращает
    # сводку для тоста.
    def perform_install_all(ids, dlg = nil)
      ids = Array(ids).map(&:to_s).reject(&:empty?).uniq
      ids = default_install_targets if ids.empty?
      return { 'ok' => false, 'error' => 'Нет расширений для установки.' } if ids.empty?

      ok = 0
      failed = []
      ids.each_with_index do |iid, i|
        res = perform_install(iid)
        name = product_name(iid)
        if res && res['ok']
          ok += 1
        else
          failed << name
        end
        push_result(dlg, 'bulk_progress',
                    'action'  => 'install_all',
                    'current' => i + 1,
                    'total'   => ids.size,
                    'id'      => iid.to_s,
                    'name'    => name,
                    'ok'      => !!(res && res['ok']))
      end
      store_log("массовая установка: ok=#{ok} fail=#{failed.size} (#{ids.size})")
      if failed.empty?
        { 'ok' => true, 'message' => "Установлено/обновлено: #{ok} из #{ids.size}." }
      elsif ok.positive?
        { 'ok' => true, 'message' => "Установлено: #{ok} из #{ids.size}. Не удалось: #{failed.join(', ')}." }
      else
        { 'ok' => false, 'error' => "Не удалось установить: #{failed.join(', ')}." }
      end
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      { 'ok' => false, 'error' => "Исключение при массовой установке: #{e.message}" }
    end

    # Массовое удаление (менеджер пропускается). Прогресс — как в
    # perform_install_all: bulk_progress после каждого расширения.
    def perform_uninstall_all(ids, dlg = nil)
      ids = Array(ids).map(&:to_s).reject(&:empty?).uniq
      ids = default_uninstall_targets if ids.empty?
      ids = ids.reject { |iid| iid == ID }
      return { 'ok' => false, 'error' => 'Нет установленных расширений для удаления.' } if ids.empty?

      ok = 0
      failed = []
      ids.each_with_index do |iid, i|
        res = perform_uninstall(iid)
        name = product_name(iid)
        if res && res['ok']
          ok += 1
        else
          failed << name
        end
        push_result(dlg, 'bulk_progress',
                    'action'  => 'uninstall_all',
                    'current' => i + 1,
                    'total'   => ids.size,
                    'id'      => iid.to_s,
                    'name'    => name,
                    'ok'      => !!(res && res['ok']))
      end
      store_log("массовое удаление: ok=#{ok} fail=#{failed.size} (#{ids.size})")
      if failed.empty?
        { 'ok' => true, 'message' => "Удалено: #{ok} из #{ids.size}. Записи в меню исчезнут после перезапуска SketchUp." }
      elsif ok.positive?
        { 'ok' => true, 'message' => "Удалено: #{ok} из #{ids.size}. Не удалось: #{failed.join(', ')}." }
      else
        { 'ok' => false, 'error' => "Не удалось удалить: #{failed.join(', ')}." }
      end
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      { 'ok' => false, 'error' => "Исключение при массовом удалении: #{e.message}" }
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
      # Первый запуск после установки: снапшота нет — форсируем полный скан
      # (релизы + автопоиск) и показываем блокирующий прогресс, а не пустой каталог.
      first_scan = !force && first_run_scan?
      use_force = force || first_scan
      local = collect_products_data(false, check_releases: false)
      seed_installed_at_baseline(local)
      store_debug("отрисовка каталога: #{local.is_a?(Array) ? local.size : 0} продуктов" \
                  "#{force ? ', force-обновление' : ''}#{first_scan ? ', первое сканирование' : ''}")

      # 2. Фоновое обновление версий через сеть (только сетевые запросы, без SketchUp API в потоке)
      repos = merged_entries.map { |e| e['repo'].to_s }.uniq.reject(&:empty?)

      if first_scan && !repos.empty?
        # Блокирующий первый скан: прогресс виден уже в первом push_state.
        @sync_status['total'] = repos.size
        @sync_status['fetched'] = 0
        @sync_status['failed'] = []
        @sync_status['first_scan'] = true
        @sync_status['fetching'] = true
        @fetching = true
        store_log("первое сканирование: полный опрос #{repos.size} репозиториев")
      end
      push_state(dlg, local)

      return if repos.empty?

      if @fetching && !first_scan
        # Повторное нажатие «Обновить» во время обхода: второй параллельный
        # обход не запускаем (гонка merge! + перезапись push_state), а
        # запоминаем желание и доберём свежие данные по завершении текущего.
        @pending_force = true if force
        store_debug('обновление уже идёт — повторный запрос коалесцирован')
        return
      end
      if @fetching && first_scan
        fetch_and_render(dlg, repos, true, attempts_left: 1, first_scan: true, notify_summary: true)
        return
      end
      @sync_status['total'] = repos.size
      @sync_status['first_scan'] = false
      @fetching = true
      @sync_status['fetching'] = true

      fetch_and_render(dlg, repos, use_force, attempts_left: 1, first_scan: false, notify_summary: use_force)
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    # Параллельный обход списка: элементы раздаются воркерам через Queue,
    # каждый воркер выполняет только сеть/чистые вычисления (без SketchUp API).
    # Ошибки воркеров логируются и не роняют весь обход. Пустой список — noop.
    def parallel_each(list, max: FETCH_CONCURRENCY, &block)
      items = Array(list)
      return if items.empty?
      return items.each { |it| block.call(it) } if items.size < 2

      workers_n = [[max.to_i, 1].max, items.size].min
      queue = Queue.new
      items.each { |it| queue << it }
      workers = workers_n.times.map do
        Thread.new do
          loop do
            item = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            begin
              block.call(item)
            rescue StandardError, ScriptError => e
              Dn1sup::Updater.log_error(e)
            end
          end
        end
      end
      workers.each(&:join)
      nil
    rescue StandardError, ScriptError => e
      Dn1sup::Updater.log_error(e)
      nil
    end

    # Фоновая загрузка каталога с GitHub, списков релизов, автопоиска
    # новых расширений и перерисовка каталога. Каталог обновляется даже
    # для неустановленных расширений: центральный registry.json — основа,
    # per-repo registry.json — дополнения поверх. Однократный автоповтор,
    # если сеть была недоступна в момент первого обхода. После релизов —
    # фоновая догрузка логов правок (коммитов) для продуктов с обновлением.
    def fetch_and_render(dlg, repos, force, attempts_left: 0, first_scan: false, notify_summary: false)
      want_discovery = discovery_due?(force) || first_scan
      # Живой прогресс проверки: фон пишет fetched, главный поток раз в 0.5с
      # пушит состояние (X/Y) в диалог. Раньше таймер включался только для
      # first_scan — обычная кнопка «Проверить обновления» висела на 0/9
      # до самого конца обхода. Плюс watchdog: обход дольше FETCH_TIMEOUT
      # принудительно завершается, а не крутится вечно.
      started_at = Time.now.to_i
      progress_timer = nil
      if Dn1sup::Updater.async_ui? && defined?(UI) && UI.respond_to?(:start_timer)
        begin
          progress_timer = UI.start_timer(0.5, true) do
            if @fetching && @dialog
              begin
                if Time.now.to_i - started_at > FETCH_TIMEOUT
                  @fetching = false
                  @sync_status['fetching'] = false
                  @sync_status['first_scan'] = false
                  push_state(@dialog, collect_products_data(false, check_releases: false))
                  push_result(@dialog, 'check_summary',
                              'ok' => false, 'updates' => 0,
                              'fetched' => @sync_status['fetched'].to_i,
                              'total' => @sync_status['total'].to_i,
                              'failed' => Array(@sync_status['failed']),
                              'message' => 'Проверка заняла больше 2 минут — возможно, нет сети или GitHub недоступен. Показаны сохранённые данные.')
                else
                  push_state(@dialog, collect_products_data(false, check_releases: false))
                end
              rescue StandardError => e
                Dn1sup::Updater.log_error(e)
              end
            end
          end
        rescue StandardError => e
          Dn1sup::Updater.log_error(e)
          progress_timer = nil
        end
      end
      stop_progress = lambda do
        if progress_timer && defined?(UI) && UI.respond_to?(:stop_timer)
          begin
            UI.stop_timer(progress_timer)
          rescue StandardError
            nil
          end
        end
      end
      Dn1sup::Updater.defer_async(
        lambda do
          result = { 'releases' => {}, 'discovered' => nil, 'stale' => {}, 'changelogs' => {}, 'failed' => [], 'dead' => [],
                     'remote_registry' => nil, 'registry_meta' => {}, 'remote_failed' => false, 'all_repos' => Array(repos) }
          now = Time.now.to_i
          # 1. Каталог: центральный реестр — основа, per-repo — дополнения.
          # Работает и для неустановленных: список и описания обновляются
          # без установки. Неудача сети прежние данные не затирает.
          if remote_registry_due?(force)
            fetched_remote = fetch_remote_registry_list
            if fetched_remote.is_a?(Array)
              result['remote_registry'] = fetched_remote
            else
              result['remote_failed'] = true
            end
          end
          base_list = begin
            load_registry
          rescue StandardError
            []
          end
          provisional = Array(base_list) + Array(result['remote_registry'])
          id_by_repo = {}
          provisional.each do |e|
            next unless e.is_a?(Hash) && !e['repo'].to_s.empty? && !e['id'].to_s.empty?
            next if id_by_repo.key?(e['repo'].to_s)

            id_by_repo[e['repo'].to_s] = e['id'].to_s
          end
          Array(result['remote_registry']).each do |e|
            next unless e.is_a?(Hash) && !e['repo'].to_s.empty?
            next if id_by_repo.key?(e['repo'].to_s)

            id_by_repo[e['repo'].to_s] = e['id'].to_s.empty? ? e['repo'].to_s.split('/').last.to_s : e['id'].to_s
          end
          all_repos = (Array(repos) + id_by_repo.keys).map(&:to_s).reject(&:empty?).uniq
          result['all_repos'] = all_repos
          done_count = 0
          bump = lambda do
            begin
              CACHE_MUTEX.synchronize do
                done_count += 1
                @sync_status['fetched'] = done_count
                @sync_status['total'] = all_repos.size
              end
            rescue StandardError
              nil
            end
          end
          # Параллельный опрос: каждый репозиторий — независимый набор
          # сетевых запросов (meta/релизы/registry/CHANGELOG). Число запросов
          # то же, что в последовательном обходе, — лимиты GitHub не растут,
          # а время стремится к самому медленному репозиторию, а не к сумме.
          parallel_each(all_repos) do |repo|
            repo_str = repo.to_s
            if repo_str.empty?
              bump.call
              next
            end

            # Существование репозитория: раз в сутки, при force — не чаще раза
            # в REPO_CHECK_TTL (экономия квоты GitHub API).
            info = @stale_repos[repo_str]
            meta = nil
            meta_due = force ? (!info.is_a?(Hash) || (now - info['checked_at'].to_i) >= REPO_CHECK_TTL) : (!info.is_a?(Hash) || (now - info['checked_at'].to_i) >= DISCOVERY_INTERVAL)
            if meta_due
              meta = Dn1sup::Updater.repo_meta(repo_str)
              CACHE_MUTEX.synchronize { result['stale'][repo_str] = meta }
            end
            dead = meta.is_a?(Hash) ? (meta[:exists] == false || meta[:renamed]) : stale?(repo_str)
            # Мёртвый/перемещённый репозиторий на релизы не опрашиваем:
            # редирект переименования вернул бы релизы нового репозитория
            # под старым именем. Репозиторий считается обработанным: счётчик
            # fetched растёт, иначе UI навсегда висел на 0/9.
            if dead
              CACHE_MUTEX.synchronize { result['dead'] << repo_str }
              bump.call
              next
            end

            # Per-repo дополнение каталога: свежие name/description/version
            # из registry.json самого расширения. Работает и для
            # неустановленных — карточка обновляется без установки.
            begin
              guess_id = id_by_repo[repo_str].to_s
              guess_id = repo_str.split('/').last.to_s if guess_id.empty?
              if registry_meta_due?(guess_id, force, now)
                per = Dn1sup::Updater.registry_entry(repo_str, guess_id)
                if per.is_a?(Hash) && !per['id'].to_s.empty?
                  CACHE_MUTEX.synchronize { result['registry_meta'][per['id'].to_s] = per }
                end
              end
            rescue StandardError => e
              Dn1sup::Updater.log_error(e)
            end

            list = releases_list(repo_str, force)
            if list.empty?
              # Пустой список — это неуспех (сеть/лимиты), а не «релизов нет»:
              # фиксируем для сводки, успешный кэш при этом не затёрт.
              CACHE_MUTEX.synchronize { result['failed'] << repo_str }
            else
              CACHE_MUTEX.synchronize { result['releases'][repo_str] = list }
            end

            # Резерв «Что нового»: CHANGELOG.md из ветки main — раз за сессию
            # на репозиторий. Сеть — только в этом фоновом потоке. nil (таймаут,
            # другая сетевая ошибка) не кэшируем — retry при следующем обновлении.
            unless @changelog_md_cache.key?(repo_str)
              md = Dn1sup::Updater.fetch_text(
                "https://raw.githubusercontent.com/#{repo_str}/main/CHANGELOG.md"
              )
              CACHE_MUTEX.synchronize { result['changelogs'][repo_str] = md } unless md.nil?
            end
            bump.call
          end
          # Однократный повтор — только сетевых неуспехов, в том же обходе:
          # итоги (fetched/total) относятся ко всему списку repos, рекурсивный
          # перезапуск ломал сводку (показывал итоги подмножества, напр. 1/1
          # вместо 3/3). Мёртвые (gone/renamed) не повторяем.
          if attempts_left > 0 && result['failed'].any?
            retry_list = nil
            CACHE_MUTEX.synchronize do
              retry_list = result['failed'].dup
              result['failed'].clear
            end
            dead_snapshot = result['dead'].dup
            parallel_each(retry_list) do |retry_repo|
              next if retry_repo.to_s.empty? || dead_snapshot.include?(retry_repo)
              retry_list_rel = releases_list(retry_repo, force)
              CACHE_MUTEX.synchronize do
                if retry_list_rel.empty?
                  result['failed'] << retry_repo
                else
                  result['releases'][retry_repo] = retry_list_rel
                end
              end
            end
          end
          renamed_found = result['stale'].values.any? { |m| m.is_a?(Hash) && m[:renamed] }
          # Переименование обнаружено вне окна автопоиска — новый репозиторий
          # ищем сразу, не дожидаясь следующего суточного скана.
          result['discovered'] = discover_repos if want_discovery || renamed_found
          result
        end,
        lambda do |fetched_raw|
          begin
            fetched = fetched_raw.is_a?(Hash) ? fetched_raw : {}
            lists = fetched['releases'].is_a?(Hash) ? fetched['releases'] : {}
            failed = fetched['failed'].is_a?(Array) ? fetched['failed'] : []
            dead = fetched['dead'].is_a?(Array) ? fetched['dead'] : []
            all = fetched['all_repos'].is_a?(Array) && !fetched['all_repos'].empty? ? fetched['all_repos'] : repos
            total_n = all.size
            # Сводка видна и без debug-флага: иначе тихий 403 выглядел как
            # «обновлений нет».
            store_log("проверка обновлений: получено #{lists.size}/#{total_n}" \
                      "#{(failed + dead).any? ? " (недоступны: #{(failed + dead).join(', ')})" : ''}")
            store_log("каталог обновлён с GitHub") if fetched['remote_registry'].is_a?(Array) || (fetched['registry_meta'].is_a?(Hash) && !fetched['registry_meta'].empty?)

          # Каталог применяем ДО статусов релизов и найденного: свежие
          # записи видят и неустановленные карточки, и автопоиск.
          apply_registry_refresh(fetched['remote_registry'], fetched['registry_meta'])
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
          processed = lists.size + failed.size + dead.size
          @sync_status['fetched'] = processed
          @sync_status['total'] = total_n
          @sync_status['failed'] = (failed + dead).uniq
          @sync_status['checked_at'] = now
          if @dialog
            push_state(dlg, collect_products_data(false, check_releases: false))
          end

          # Новонайденные расширения (в т.ч. на новом имени после
          # переименования) подтягивают релизы сразу, иначе карточки
          # появятся только при следующем открытии каталога.
          if added_repos.any? && @dialog
            fetch_and_render(dlg, added_repos, force, attempts_left: 0,
                                                  first_scan: false, notify_summary: notify_summary)
          else
            stop_progress.call
            @fetching = false
            @sync_status['fetching'] = false
            @sync_status['first_scan'] = false
            products = []
            if @dialog
              products = collect_products_data(false, check_releases: false)
              push_state(dlg, products)
              fetch_commits_async(dlg)
            end
            if notify_summary && @dialog
              push_check_summary(dlg, products, processed, total_n, (failed + dead).uniq, first_scan)
            end
            store_log("первое сканирование завершено: #{processed}/#{total_n}") if first_scan
            if @pending_force && @dialog
              @pending_force = false
              send_products_to_dialog(force: true)
            else
              @pending_force = false
            end
          end
          rescue StandardError => e
            Dn1sup::Updater.log_error(e)
            begin
              stop_progress.call
            rescue StandardError
              nil
            end
            @fetching = false
            @sync_status['fetching'] = false
            @sync_status['first_scan'] = false
            push_state(@dialog, collect_products_data(false, check_releases: false)) if @dialog
          end
        end
      )
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      begin
        stop_progress.call if defined?(stop_progress) && stop_progress
      rescue StandardError
        nil
      end
      @fetching = false
      @sync_status['fetching'] = false
      @sync_status['first_scan'] = false
    end

    # Сводка проверки для кнопки «Проверить обновления»: сколько обновлений
    # найдено, сколько репозиториев не ответило. Уходит тостом в диалог.
    def push_check_summary(dlg, products, fetched, total, failed, first_scan)
      list = Array(products)
      updates = list.select { |p| p.is_a?(Hash) && (p['has_update'] || p['status'] == 'switch') }
      names = updates.first(5).map { |p| p['name'].to_s.empty? ? p['id'].to_s : p['name'].to_s }
      if updates.empty?
        text = first_scan ? "Первое сканирование завершено: проверено #{fetched}/#{total}, обновлений нет." : "Проверено #{fetched}/#{total}: обновлений нет."
        push_result(dlg, 'check_summary', 'ok' => true, 'updates' => 0,
                                               'fetched' => fetched, 'total' => total,
                                               'failed' => Array(failed), 'message' => text)
      else
        extra = updates.size > names.size ? " и ещё #{updates.size - names.size}" : ''
        text = "Доступно обновлений: #{updates.size} (#{names.join(', ')}#{extra})."
        text += " Не ответили: #{Array(failed).size}." if Array(failed).any?
        text = "Первое сканирование завершено. #{text}" if first_scan
        push_result(dlg, 'check_summary', 'ok' => true, 'updates' => updates.size,
                                               'fetched' => fetched, 'total' => total,
                                               'failed' => Array(failed), 'message' => text)
      end
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
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
          # Теги фиксируем заранее: full_tag_name читает @releases_cache,
          # параллельным воркерам отдаём готовые строки (без общего состояния).
          tagged = pending.map do |item|
            item.merge('base_tag' => full_tag_name(item['repo'], item['installed']),
                       'head_tag' => full_tag_name(item['repo'], item['offered']))
          end
          parallel_each(tagged) do |item|
            msgs = Dn1sup::Updater.compare_commits(
              item['repo'],
              item['base_tag'],
              item['head_tag'],
              limit: 15
            )
            CACHE_MUTEX.synchronize { result[item['repo']] = item.merge('messages' => msgs) } unless msgs.empty?
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
      when 'install_all'
        ids = extract_ids(param)
        notify_action_result('__bulk__', 'install_all', perform_install_all(ids, dlg))
        send_products_to_dialog(force: false)
      when 'confirm_uninstall_all'
        ids = extract_ids(param)
        ids = default_uninstall_targets if ids.empty?
        ids = ids.reject { |iid| iid == ID }
        if ids.empty?
          notify_action_result('__bulk__', 'uninstall_all',
                               'ok' => false, 'error' => 'Нет установленных расширений для удаления.')
        else
          msg = "Удалить #{ids.size} расширений из SketchUp?\n#{ids.map { |iid| "• #{product_name(iid)}" }.join("\n")}"
          yes = defined?(UI) && UI.messagebox(msg, MB_YESNO) == IDYES
          push_result(dlg, 'confirm_uninstall_all', 'ids' => ids, 'ok' => !!yes)
        end
      when 'uninstall_all'
        ids = extract_ids(param)
        notify_action_result('__bulk__', 'uninstall_all', perform_uninstall_all(ids, dlg))
        send_products_to_dialog(force: false)
      when 'hide'
        # Скрыть найденное на GitHub расширение (не из реестра)
        repo = parse_json(param)['repo']
        hide_repo(repo)
        store_log("скрыт найденный репозиторий #{repo}")
        send_products_to_dialog(force: false)
      when 'confirm_restart'
        # Новая несохранённая сцена: сначала Да/Нет/Отмена про сохранение.
        # Отмена (или незавершённое сохранение) — прерываем рестарт.
        if model_needs_first_save?
          decision = prompt_first_save
          if decision == :cancel
            push_result(dlg, 'confirm_restart', 'ok' => false)
          else
            # Вопрос после нажатия кнопки в шапке — через нативный диалог
            # SketchUp (window.confirm в HtmlDialog на части сборок подавлен).
            yes = defined?(UI) && UI.messagebox(restart_confirm_message, MB_YESNO) == IDYES
            push_result(dlg, 'confirm_restart', 'ok' => !!yes)
          end
        else
          # Вопрос после нажатия кнопки в шапке — через нативный диалог
          # SketchUp (window.confirm в HtmlDialog на части сборок подавлен).
          yes = defined?(UI) && UI.messagebox(restart_confirm_message, MB_YESNO) == IDYES
          push_result(dlg, 'confirm_restart', 'ok' => !!yes)
        end
      when 'restart'
        res = perform_restart
        # При успехе приложение закрывается (уведомлять некого);
        # при неудаче показываем ошибку тостом.
        notify_action_result('__restart__', 'restart', res) unless res && res['ok']
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

    # Автоуведомление при старте SketchUp: фоново проверяем установленные
    # расширения (только их репозитории — экономия квоты API, не чаще раза
    # в сутки) и показываем ненавязчивое уведомление, если есть обновления.
    # Без модальных диалогов, без открытия каталога.
    def maybe_notify_updates_on_startup
      return unless defined?(Sketchup) && defined?(UI)

      begin
        last = Sketchup.read_default('DN1Sup ExtManager', 'last_startup_notice', 0)
        return if (Time.now.to_i - last.to_i) < DISCOVERY_INTERVAL
      rescue StandardError
        nil
      end
      begin
        Sketchup.write_default('DN1Sup ExtManager', 'last_startup_notice', Time.now.to_i)
      rescue StandardError
        nil
      end
      load_release_snapshot if @release_cache.empty?
      installed = merged_entries.select { |e| installed_version(e) }
      repos = installed.map { |e| e['repo'].to_s }.uniq.reject(&:empty?)
      return if repos.empty?

      store_debug("стартовая проверка обновлений: #{repos.size} установленных")
      Dn1sup::Updater.defer_async(
        lambda do
          found = []
          # Снапшот записей — воркеры не ходят в merged_entries параллельно.
          entries_by_repo = {}
          merged_entries.each { |e| entries_by_repo[e['repo'].to_s] ||= e }
          parallel_each(repos) do |repo|
            list = begin
              releases_list(repo, false)
            rescue StandardError => e
              Dn1sup::Updater.log_error(e)
              []
            end
            next if list.empty?

            offered = Dn1sup::Updater.choose_release(list)
            next unless offered

            entry = entries_by_repo[repo.to_s]
            next unless entry

            inst = installed_version(entry)
            next if inst.to_s.empty?

            status = begin
              safe_product_status(inst, offered, list, Dn1sup::Updater.installed_at(entry['id'].to_s))
            rescue StandardError
              nil
            end
            if status == 'update' || status == 'switch'
              label = entry['name'].to_s.empty? ? entry['id'].to_s : entry['name'].to_s
              CACHE_MUTEX.synchronize { found << label }
            end
          end
          found
        end,
        lambda do |names_raw|
          names = Array(names_raw).map(&:to_s).reject(&:empty?)
          next if names.empty?
          next unless defined?(UI)

          text = names.size == 1 ? "Доступно обновление: #{names.first}. Откройте Extension Store." : "Доступно обновлений: #{names.size} (#{names.first(3).join(', ')}#{names.size > 3 ? '…' : ''}). Откройте Extension Store."
          store_log("стартовая проверка: #{text}")
          begin
            if UI.respond_to?(:notification_available?) && UI.notification_available?
              note = UI::Notification.new('DN1Sup Extension Store', text)
              note.show
            end
          rescue StandardError => e
            Dn1sup::Updater.log_error(e)
          end
        end
      )
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
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

    # ---- Перезапуск SketchUp с тем же файлом (кнопка в шапке) -------------

    # Путь текущей модели ('' = новая несохранённая сцена).
    def current_model_path
      return '' unless defined?(Sketchup) && Sketchup.respond_to?(:active_model)

      Sketchup.active_model&.path.to_s
    rescue StandardError
      ''
    end

    # Версия запущенного SketchUp: [год_папки, строка_версии].
    # '26.2.243' -> [2026, '26.2.243']; вне SketchUp -> [0, ''].
    def running_version
      v = defined?(Sketchup) && Sketchup.respond_to?(:version) ? Sketchup.version.to_s : ''
      major = v.to_i
      year = major >= 100 ? major : (major > 0 ? 2000 + major : 0)
      [year, v]
    rescue StandardError
      [0, '']
    end

    # Человеческая подпись версии для вопроса: 'SketchUp 2026 (26.2.243)'.
    def running_version_label
      year, v = running_version
      label = year > 0 ? "SketchUp #{year}" : 'SketchUp'
      v.empty? ? label : "#{label} (#{v})"
    end

    # Точный exe текущего процесса через Win32 (не эвристика по папкам:
    # при нескольких установленных версиях рестарт обязан поднять ту же).
    # '' = недоступно (не-Windows, нет fiddle) — дальше работают эвристики.
    def running_process_exe
      require 'fiddle'
      require 'fiddle/import'
      mod = Module.new do
        extend Fiddle::Importer
        dlload 'kernel32.dll'
        extern 'unsigned long GetModuleFileNameW(void*, char*, unsigned long)', :stdcall
      end
      buf = "\0".encode('UTF-16LE') * 260
      len = mod.GetModuleFileNameW(0, buf, 260)
      return '' if len.to_i <= 0

      buf.encode('UTF-8', 'UTF-16LE').split("\0").first.to_s
    rescue LoadError, StandardError
      ''
    end

    # Новая сцена без пути и с изменениями — перед рестартом предлагаем
    # сначала сохранить (иначе данные потеряются: откроется пустая сцена).
    # false = сохранять нечего (пути нет, но сцена чистая) или модели нет.
    def model_needs_first_save?
      return false unless defined?(Sketchup) && Sketchup.respond_to?(:active_model)

      model = Sketchup.active_model
      return false unless model
      path = begin
        model.path.to_s
      rescue StandardError
        ''
      end
      return false unless path.empty?

      begin
        return true if model.respond_to?(:modified?) && !!model.modified?
      rescue StandardError
        nil
      end
      # Фолбэк, когда modified? недоступен: непустая сцена считается грязной.
      begin
        if model.respond_to?(:entities)
          ents = model.entities
          return true if ents.respond_to?(:count) && ents.count.to_i > 0
          return true if ents.respond_to?(:length) && ents.length.to_i > 0
          return true if ents.respond_to?(:empty?) && !ents.empty?
        end
      rescue StandardError
        nil
      end
      false
    rescue StandardError
      false
    end

    # Диалог «Сохранить перед перезапуском?» (Да/Нет/Отмена).
    # :saved — сохранено, идём дальше к вопросу о рестарте;
    # :skip — без сохранения (как раньше, откроется пустая сцена);
    # :cancel — прерываем рестарт.
    def prompt_first_save
      return :skip unless defined?(UI) && UI.respond_to?(:messagebox)

      mb_ync = defined?(MB_YESNOCANCEL) ? MB_YESNOCANCEL : 3
      idyes = defined?(IDYES) ? IDYES : 6
      idno = defined?(IDNO) ? IDNO : 7
      answer = UI.messagebox(
        "Текущая сцена ещё ни разу не сохранялась.\nСохранить её перед перезапуском?",
        mb_ync
      )
      return :skip if answer == idno
      return :cancel unless answer == idyes
      return :skip unless UI.respond_to?(:savepanel)

      file = UI.savepanel('Сохранить модель перед перезапуском', '', 'Без названия.skp')
      return :cancel if file.to_s.strip.empty?

      saved = begin
        Sketchup.active_model.save(file.to_s)
      rescue StandardError => e
        Dn1sup::Updater.log_error(e)
        false
      end
      unless saved
        mb_ok = defined?(MB_OK) ? MB_OK : 0
        UI.messagebox("Не удалось сохранить файл — перезапуск отменён:\n#{file}", mb_ok)
        return :cancel
      end
      store_log("модель сохранена перед перезапуском: #{file}")
      :saved
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      :cancel
    end

    # Текст нативного вопроса после нажатия кнопки — с версией SketchUp
    # и именем файла, чтобы было видно, что именно перезапускается
    # и что откроется после.
    def restart_confirm_message
      path = current_model_path
      app = running_version_label
      if path.empty?
        "Перезапустить #{app}? Текущая сцена не сохранена в файл — " \
          'после перезапуска откроется пустая сцена. Продолжить?'
      else
        "Перезапустить #{app} и заново открыть файл?\n#{path}\n" \
          'Несохранённые изменения предложат сохранить при закрытии.'
      end
    end

    # Поиск SketchUp.exe: сначала точный exe текущего процесса (при
    # нескольких установленных версиях рестарт поднимает ту же), затем
    # точный путь от самого SketchUp (find_support_file знает актуальную
    # раскладку — с 2025 exe живёт в подпапке SketchUp/, раньше лежал
    # рядом), затем годовые кандидаты запущенной версии в обеих
    # раскладках, затем glob. nil = не найден (тогда только
    # честная ошибка в UI, без quit).
    def sketchup_exe_path
      roots = [ENV['ProgramW6432'], ENV['ProgramFiles'], ENV['ProgramFiles(x86)']].compact.uniq
      year, = running_version
      years = year > 0 ? [year, year - 1, year + 1] : []

      candidates = []
      begin
        via_proc = running_process_exe
        candidates << via_proc unless via_proc.empty?
      rescue StandardError
        nil
      end
      if defined?(Sketchup) && Sketchup.respond_to?(:find_support_file)
        begin
          via_api = Sketchup.find_support_file('SketchUp.exe').to_s
          candidates << via_api unless via_api.empty?
        rescue StandardError
          nil
        end
      end
      years.each do |y|
        roots.each do |root|
          candidates << File.join(root, 'SketchUp', "SketchUp #{y}", 'SketchUp', 'SketchUp.exe')
          candidates << File.join(root, 'SketchUp', "SketchUp #{y}", 'SketchUp.exe')
        end
      end
      hit = candidates.find { |p| File.file?(p) }
      return hit if hit

      found = []
      roots.each do |root|
        base = root.to_s.gsub('\\', '/')
        found.concat(Dir.glob("#{base}/SketchUp/SketchUp */SketchUp/SketchUp.exe"))
        found.concat(Dir.glob("#{base}/SketchUp/SketchUp */SketchUp.exe"))
      end
      found = found.select { |p| File.file?(p) }.uniq
      return nil if found.empty?

      # Приоритет — год запущенной версии, иначе свежайшая папка.
      with_year = found.map { |p| [p, p[/SketchUp (\d{4})/, 1].to_i] }
      same = with_year.select { |_, y| y == year }.map(&:first)
      return same.sort.last unless same.empty?

      with_year.sort_by { |_, y| y }.last[0]
    rescue StandardError
      nil
    end

    # Закрыть SketchUp и автоматически открыть заново с тем же файлом.
    # Гонка 0.22.2: новый процесс стартовал раньше quit и заставал файл
    # занятым старым процессом. Теперь запуск отложен: detached-наблюдатель
    # (PowerShell) ждёт реального выхода PID, держит паузу 3с и только
    # потом поднимает SketchUp с тем же файлом. Если пользователь отменил
    # выход в диалоге сохранения — процесс жив, повторный запуск не
    # происходит. Возвращает {'ok'=>true} при запланированном рестарте,
    # иначе {'ok'=>false,'error'=>..}.
    def perform_restart
      unless defined?(Sketchup) && Sketchup.respond_to?(:quit)
        return { 'ok' => false, 'error' => 'Перезапуск недоступен: Sketchup.quit не поддерживается.' }
      end
      exe = sketchup_exe_path
      if exe.to_s.empty?
        return { 'ok' => false, 'error' => 'Не найден SketchUp.exe — закройте и откройте SketchUp вручную.' }
      end

      path = current_model_path
      store_log("перезапуск SketchUp#{path.empty? ? '' : " с файлом #{path}"}")
      watcher = write_restart_watcher(exe, path, Process.pid)
      unless watcher && File.file?(watcher)
        return { 'ok' => false, 'error' => 'Не удалось запланировать перезапуск — закройте и откройте SketchUp вручную.' }
      end
      # start — встроенная команда cmd.exe: наблюдатель отцепляется и
      # переживает quit текущего процесса.
      launched = system(%(cmd /c start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "#{watcher}"),
                        out: File::NULL, err: File::NULL)
      unless launched
        FileUtils.rm_f(watcher)
        return { 'ok' => false, 'error' => 'Не удалось запланировать перезапуск — закройте и откройте SketchUp вручную.' }
      end
      Sketchup.quit
      { 'ok' => true }
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      { 'ok' => false, 'error' => "Не удалось перезапустить: #{e.message}" }
    end

    # PowerShell-наблюдатель рестарта: ждёт выхода PID (до 120с), пауза 3с
    # на освобождение файлового лока, затем Start-Process с тем же файлом.
    # Отмена выхода (процесс жив) — запуск не происходит. Скрипт пишется
    # с BOM (кириллица в путях), после срабатывания удаляет сам себя.
    def write_restart_watcher(exe, path, pid)
      dir = defined?(Sketchup) && Sketchup.respond_to?(:temp_dir) ? Sketchup.temp_dir.to_s : Dir.tmpdir.to_s
      watcher = File.join(dir, "dn1sup_restart_#{pid}.ps1")
      q = ->(s) { s.to_s.gsub("'", "''") }
      # Путь модели — в двойных кавычках внутри '-строки: без них путь
      # с пробелом («Тестовый файл.skp») резался по первому слову и новый
      # процесс отвечал «Failed to open ...Тестовый».
      launch = if path.to_s.empty?
                 "Start-Process -FilePath '#{q.call(exe)}'"
               else
                 %Q(Start-Process -FilePath '#{q.call(exe)}' -ArgumentList '"#{q.call(path)}"')
               end
      script = <<~PS
        $p = Get-Process -Id #{pid.to_i} -ErrorAction SilentlyContinue
        $gone = $true
        if ($p) { $gone = $p.WaitForExit(120000) }
        if ($gone) {
          Start-Sleep -Seconds 3
          #{launch}
        }
        Remove-Item -LiteralPath '#{q.call(watcher)}' -Force -ErrorAction SilentlyContinue
      PS
      File.write(watcher, "\uFEFF" + script, encoding: 'UTF-8')
      watcher
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
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
      menu.add_item('Проверить обновления') do
        open_store
        UI.start_timer(0.5, false) { send_products_to_dialog(force: true) if @dialog }
      end
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
      # Плюс автоуведомление обо всех установленных расширениях.
      UI.start_timer(20, false) do
        Dn1sup::Updater.check_local_first!({ id: ID, repo: REPO, version: VERSION, asset: ASSET, dev_dir: DEV_DIR, async: true })
        maybe_notify_updates_on_startup
      end

      file_loaded(__FILE__)
    end
  end
end
