# frozen_string_literal: true

begin
  require 'sketchup.rb'
rescue LoadError
  # Standalone environment outside SketchUp
end
require 'net/http'
require 'uri'
require 'time'

# Dn1sup::Updater — общий модуль автообновления через GitHub Releases.
#
# Файл кладётся в каждое расширение при упаковке (tools/pack.rb) как <id>/dn1sup_updater.rb.
#
# Использование:
#   Dn1sup::Updater.check!(MANIFEST)                                # фоновая проверка (не чаще раза в сутки)
#   Dn1sup::Updater.check!(MANIFEST.merge(force: true))             # по кнопке «Проверить обновления»
#   Dn1sup::Updater.check!(MANIFEST.merge(silent: true))            # без UI (сервисные вызовы, тесты)
#
# MANIFEST = { id: 'my_extension', repo: 'owner/repo', version: '1.2.3', asset: 'my_extension.rbz' }
#
# Актуальная версия расширения берётся из registry.json репозитория (поле version
# конкретного расширения); общий тег релиза монорепо — fallback при недоступном
# реестре. Сетевые запросы выполняются в фоновом потоке, UI — на главном.
module Dn1sup
  module Updater
    module_function

    SECTION        = 'Dn1supUpdater' unless defined?(SECTION)
    CHECK_INTERVAL = 24 * 60 * 60 unless defined?(CHECK_INTERVAL)
    GITHUB_API     = 'https://api.github.com' unless defined?(GITHUB_API)
    LOG_SIZE_LIMIT = 1024 * 1024 unless defined?(LOG_SIZE_LIMIT)

    HEADERS = {
      'Accept'           => 'application/vnd.github+json',
      'User-Agent'       => 'SketchUp-DN1Sup-Updater/1.0',
      'Accept-Encoding'  => 'identity'
    }.freeze unless defined?(HEADERS)

    @checking ||= {}
    @registry_cache ||= {}

    # --- public ------------------------------------------------------------

    # Проверяет обновление. Никогда не бросает исключений наружу.
    # Синхронно возвращает Hash-сводку, если есть более свежая версия, иначе nil.
    # При async: true внутри живого SketchUp сеть уходит в фоновый поток,
    # UI показывается по готовности на главном потоке — метод сразу возвращает nil.
    def check!(cfg)
      id_str = cfg[:id].to_s
      return nil if @checking[id_str]

      @checking[id_str] = true

      force  = !!cfg[:force]
      silent = !!cfg[:silent]
      async  = !!cfg[:async] && async_ui?

      unless force || throttle_ok?(id_str)
        @checking[id_str] = false
        return nil
      end

      work = -> { fetch_latest(cfg) }
      done = lambda do |fetched|
        result = nil
        begin
          result = apply_check(cfg, fetched, force: force, silent: silent)
        rescue StandardError, ScriptError => e
          log_error(e)
        ensure
          @checking[id_str] = false
        end
        result
      end

      if async
        defer_async(work, done)
        nil
      else
        done.call(work.call)
      end
    end

    # GET https://api.github.com/repos/{owner}/{repo}/releases/latest
    # Возвращает Hash JSON или {} при любой ошибке (сеть, лимиты и т.п.).
    def latest_release(repo)
      require 'net/http'
      require 'json'
      uri = URI.parse("#{GITHUB_API}/repos/#{repo}/releases/latest")
      res = http_get(uri)
      unless res.is_a?(Net::HTTPSuccess)
        log_debug("latest_release(#{repo}): HTTP #{res.respond_to?(:code) ? res.code : '?'}")
        return {}
      end
      json = JSON.parse(res.body)
      log_debug("latest_release(#{repo}): OK #{json['tag_name'].to_s}")
      json
    rescue StandardError, ScriptError => e
      log_error(e)
      {}
    end

    # GET https://api.github.com/repos/{owner}/{repo}/releases?per_page=N
    # Возвращает Array JSON-объектов (новые раньше старых) или [] при любой
    # ошибке (сеть, лимиты и т.п.).
    def releases(repo, per_page: 20)
      require 'net/http'
      require 'json'
      uri = URI.parse("#{GITHUB_API}/repos/#{repo}/releases?per_page=#{per_page.to_i}")
      res = http_get(uri)
      unless res.is_a?(Net::HTTPSuccess)
        log_debug("releases(#{repo}): HTTP #{res.respond_to?(:code) ? res.code : '?'}")
        return []
      end
      json = JSON.parse(res.body)
      list = json.is_a?(Array) ? json : []
      log_debug("releases(#{repo}): OK #{list.size} релизов")
      list
    rescue StandardError, ScriptError => e
      log_error(e)
      []
    end

    # Все репозитории аккаунта/организации (для автопоиска расширений).
    # GET /users/{owner}/repos, а если аккаунт — организация, фолбэк на
    # /orgs/{owner}/repos. Возвращает Array JSON-объектов или [] при ошибке.
    def repos_of_owner(owner)
      require 'net/http'
      require 'json'
      owner = owner.to_s
      %w[users orgs].each do |segment|
        uri = URI.parse("#{GITHUB_API}/#{segment}/#{owner}/repos?per_page=100&sort=pushed")
        res = http_get(uri)
        next unless res.is_a?(Net::HTTPSuccess)

        json = JSON.parse(res.body)
        if json.is_a?(Array)
          log_debug("repos_of_owner(#{owner}): OK #{json.size} репозиториев (/#{segment}/)")
          return json
        end
      end
      log_debug("repos_of_owner(#{owner}): недоступно")
      []
    rescue StandardError, ScriptError => e
      log_error(e)
      []
    end

    # Лог правок между двумя тегами: первые строки сообщений коммитов.
    # GET /repos/{repo}/compare/{base}...{head}. Возвращает Array строк
    # (до limit) или [] при любой ошибке (тега нет, сеть и т.п.).
    def compare_commits(repo, base, head, limit: 15)
      require 'net/http'
      require 'json'
      base_s = URI.encode_www_form_component(base.to_s)
      head_s = URI.encode_www_form_component(head.to_s)
      uri = URI.parse("#{GITHUB_API}/repos/#{repo}/compare/#{base_s}...#{head_s}")
      res = http_get(uri)
      return [] unless res.is_a?(Net::HTTPSuccess)

      json = JSON.parse(res.body)
      commits = json.is_a?(Hash) && json['commits'].is_a?(Array) ? json['commits'] : []
      msgs = commits.first(limit.to_i).map do |c|
        msg = c.is_a?(Hash) && c['commit'].is_a?(Hash) ? c['commit']['message'].to_s : ''
        first = msg.split(/\r?\n/).first.to_s.strip
        first.empty? ? nil : first
      end
      msgs.compact! || msgs
      log_debug("compare_commits(#{repo}, #{base}...#{head}): OK #{msgs.size} коммитов")
      msgs
    rescue StandardError, ScriptError => e
      log_error(e)
      []
    end

    # Скачивает произвольный URL в файл. Возвращает путь или nil.
    def download(url, dest_path)
      require 'net/http'
      require 'uri'
      res = http_get(url)
      if res.is_a?(Net::HTTPSuccess)
        save_file(res.body, dest_path)
      else
        code = res.respond_to?(:code) ? res.code : 'unknown'
        log_error(RuntimeError.new("HTTP #{code} при скачивании #{url}"))
        nil
      end
    rescue StandardError, ScriptError => e
      log_error(e)
      nil
    end

    # Скачивает файл во временную папку и возвращает путь (nil при ошибке).
    def download_to_temp(url)
      filename = File.basename(URI.parse(url).path.to_s)
      filename = 'download.rbz' if filename.to_s.empty?
      path = File.join(temp_dir, filename)
      download(url, path)
    rescue StandardError, ScriptError => e
      log_error(e)
      nil
    end

    # Загружает текст по URL (для JSON-реестров и т.п.). nil при ошибке.
    def fetch_text(url)
      require 'net/http'
      res = http_get(url)
      res.is_a?(Net::HTTPSuccess) ? res.body.to_s : nil
    rescue StandardError, ScriptError => e
      log_error(e)
      nil
    end

    # Выполняет work в фоне (поток) и вызывает callback с результатом на
    # главном потоке SketchUp. Вне живого SketchUp (тесты, CLI) — синхронно.
    def defer_async(work, callback)
      unless async_ui?
        result = begin
          work.call
        rescue StandardError, ScriptError => e
          log_error(e)
          nil
        end
        return callback.call(result)
      end

      queue = Queue.new
      Thread.new do
        result = begin
          work.call
        rescue StandardError, ScriptError => e
          log_error(e)
          nil
        end
        queue << result
      end

      timer = nil
      timer = UI.start_timer(0.25, true) do
        next if queue.empty?

        UI.stop_timer(timer)
        callback.call(queue.pop)
      end
      nil
    end

    # Сравнение версий: norm_version('v1.2.10-rc1') -> [1, 2, 10].
    # Pre-release/build-суффиксы отбрасываются: '0.3.0-rc1' не новее '0.3.0'.
    def norm_version(text)
      text.to_s.split(/[+-]/).first.to_s.scan(/\d+/).map(&:to_i)
    end

    # true, если a новее b (поэлементное сравнение с недостающими ~0).
    def newer?(a, b)
      count = [a.size, b.size].max
      (0...count).each do |i|
        x = a[i].to_i
        y = b[i].to_i
        return true  if x > y
        return false if x < y
      end
      false
    end

    # Время публикации релиза; неизвестное/битое — начало эпохи («самое старое»).
    def release_time(release)
      t = Time.parse(release['published_at'].to_s)
      t || Time.at(0)
    rescue StandardError, ArgumentError
      Time.at(0)
    end

    # Новейший стабильный релиз списка (без draft/prerelease) по дате публикации.
    # /releases/latest у GitHub возвращает последний ОПУБЛИКОВАННЫЙ релиз, поэтому
    # после нестандартной публикации (напр. 0.4.1 поверх серии 2.4.x) «latest»
    # может оказаться ниже установленной версии — предлагаемый релиз выбираем
    # сами из полного списка.
    def choose_release(list)
      stable = list.to_a.find_all do |r|
        r.is_a?(Hash) && !r['tag_name'].to_s.empty? && !r['draft'] && !r['prerelease']
      end
      stable.max_by { |r| release_time(r) }
    end

    # Статус установленной версии относительно предлагаемого (новейшего по дате)
    # релиза:
    #   'update'  — предлагаемый релиз новее по номеру версии;
    #   'switch'  — релиз новее по ДАТЕ публикации, но не выше по номеру (смена
    #               схемы нумерации, напр. 2.4.1 -> 0.4.1, либо переизпуск той
    #               же версии): предлагаем установку, если дата установленной
    #               сборки определена — по релизу из списка, а при его
    #               отсутствии по дате установки (installed_at, unixtime);
    #   'current' — версии совпадают;
    #   nil       — нет данных (релизы недоступны или расширение не установлено).
    def product_status(installed_ver, offered, list = nil, installed_at: nil)
      return nil if installed_ver.to_s.empty? || offered.nil? || offered['tag_name'].to_s.empty?

      tag  = offered['tag_name'].to_s.sub(/\Av/i, '')
      inst = installed_ver.to_s.sub(/\Av/i, '')
      if tag == inst
        # Переизпуск той же версии: релиз опубликован позже установленной сборки.
        return 'switch' if installed_at.to_i > 0 && release_time(offered).to_i > installed_at.to_i

        return 'current'
      end
      return 'update'  if newer?(norm_version(tag), norm_version(inst))

      inst_release = list.to_a.find do |r|
        r.is_a?(Hash) && r['tag_name'].to_s.sub(/\Av/i, '') == inst
      end
      if inst_release
        return release_time(offered) > release_time(inst_release) ? 'switch' : nil
      end

      # Релиз установленной версии не найден в списке (снапшот хранит лишь
      # последние 10, установка давно) — fallback на дату установки.
      return nil unless installed_at.to_i > 0

      release_time(offered).to_i > installed_at.to_i ? 'switch' : nil
    end

    # Установка .rbz с любого URL через официальный Sketchup.install_from_archive.
    # id — идентификатор расширения: при успешной установке фиксируется дата
    # сборки (installed_at_<id>), по которой потом распознаются переизданные
    # релизы без бампа версии.
    def install_from_url(url, what = 'расширение', silent = false, id: nil)
      url = url.to_s
      if url.empty?
        log_debug("install_from_url(#{what}): пустой URL — отмена")
        return false
      end
      unless defined?(Sketchup) && Sketchup.respond_to?(:install_from_archive)
        log_debug("install_from_url(#{what}): install_from_archive недоступен")
        inform("#{what}: Sketchup.install_from_archive недоступен в этой версии SketchUp.") unless silent
        return false
      end
      log_debug("install_from_url(#{what}): скачивание #{url}")
      path = download_to_temp(url)
      unless path
        log_debug("install_from_url(#{what}): скачивание не удалось")
        inform("#{what}: не удалось скачать обновление.\n" \
               'Проверьте соединение или скачайте .rbz вручную со страницы релиза.') unless silent
        return false
      end
      unless rbz?(path)
        log_debug("install_from_url(#{what}): файл #{File.basename(path)} не похож на .rbz")
        inform("#{what}: скачанный файл не похож на .rbz — вероятно, ошибка сети. Попробуйте позже.") unless silent
        return false
      end
      ok = begin
        # false = без собственного диалога SketchUp: итог покажет вызывающая сторона
        Sketchup.install_from_archive(path, false)
      rescue StandardError => e
        log_error(e)
        false
      end
      log_debug("install_from_url(#{what}): install_from_archive -> #{ok ? 'OK' : 'FAIL'}")
      if ok
        mark_installed(id) if id
        inform("#{what}: обновление установлено.\n\n" \
               'Перезапустите SketchUp, чтобы новый код загрузился.') unless silent
      else
        inform("#{what}: SketchUp не удалось установить архив. Скачайте .rbz вручную с GitHub.") unless silent
      end
      ok
    ensure
      File.delete(path) if path && File.file?(path) rescue nil
    end

    # --- internals ---------------------------------------------------------

    # Сетевая часть проверки (может выполняться в фоне):
    # { release:, latest:, from_registry: } или nil.
    # latest — per-extension версия из registry.json либо тег релиза;
    # from_registry показывает источник latest — от него зависит, можно ли
    # сравнивать дату релиза с датой установки (в монорепо тег релиза может
    # описывать другое расширение).
    def fetch_latest(cfg)
      release = latest_release(cfg[:repo].to_s)
      return nil unless release.is_a?(Hash) && release.key?('tag_name')

      entry = registry_entry(cfg[:repo].to_s, cfg[:id].to_s)
      ver   = entry.is_a?(Hash) ? entry['version'].to_s : ''
      if ver != ''
        { release: release, latest: ver, from_registry: true }
      else
        { release: release, latest: release['tag_name'].to_s, from_registry: false }
      end
    end

    # UI-часть проверки (главный поток). Возвращает summary или nil.
    def apply_check(cfg, fetched, force: false, silent: false)
      id_str = cfg[:id].to_s
      unless fetched
        inform("#{id_str}: не удалось проверить релизы на GitHub.\n" \
               'Проверьте соединение с интернетом или настройки репозитория.') if force && !silent
        return nil
      end
      mark_checked(id_str)

      latest  = norm_version(fetched[:latest])
      current = norm_version(cfg[:version].to_s)
      same_version = false
      unless newer?(latest, current)
        # Номер версии не новее — смотрим на дату публикации релиза: релиз,
        # изданный позже установленной сборки (переизпуск без бампа версии,
        # смена схемы нумерации), тоже считается обновлением.
        unless release_newer_than_install?(cfg, fetched)
          inform("#{id_str}: у вас уже установлена актуальная версия (#{cfg[:version]}).") if force && !silent
          return nil
        end
        same_version = true
      end

      release = fetched[:release]
      summary = {
        id:        id_str,
        latest:    fetched[:latest].to_s,
        current:   cfg[:version].to_s,
        notes:     release['body'].to_s,
        page_url:  release['html_url'].to_s,
        asset_url: asset_url(release, cfg[:asset].to_s)
      }
      summary[:same_version] = true if same_version
      offer_install(summary, background: !force) unless silent
      summary
    end

    # Релиз издан позже установленной сборки? Сравнение возможно, только когда
    # известна дата установки текущей версии (пишется при установке через
    # апдейтер/Store) и релиз относится к этому расширению: в монорепо тег
    # релиза может описывать другое расширение, тогда его дата ничего не
    # говорит об этом расширении (версия из registry.json авторитетна).
    def release_newer_than_install?(cfg, fetched)
      return false if fetched[:from_registry] &&
                      fetched[:latest].to_s != fetched[:release]['tag_name'].to_s.sub(/\Av/, '')

      inst_time = installed_at(cfg[:id])
      return false unless inst_time

      release_time(fetched[:release]).to_i > inst_time
    end

    # Запись расширения из registry.json репозитория (источник per-extension версий).
    # Успешно полученный список кэшируется на процесс; сетевая неудача не кэшируется.
    def registry_entry(repo, id)
      @registry_cache ||= {}
      cached = @registry_cache[repo]
      return find_registry_entry(cached, id) if cached

      require 'json'
      raw = fetch_text("https://raw.githubusercontent.com/#{repo}/main/registry.json")
      parsed = begin
        raw ? JSON.parse(raw) : nil
      rescue StandardError
        nil
      end
      parsed = parsed['extensions'] if parsed.is_a?(Hash) && parsed['extensions'].is_a?(Array)
      @registry_cache[repo] = parsed if parsed.is_a?(Array)
      find_registry_entry(parsed, id)
    rescue StandardError, ScriptError => e
      log_error(e)
      nil
    end

    def find_registry_entry(list, id)
      return nil unless list.is_a?(Array)

      list.find { |e| e.is_a?(Hash) && e['id'].to_s == id.to_s }
    end

    def throttle_ok?(id)
      return true unless defined?(Sketchup)
      last = Sketchup.read_default(SECTION, "last_#{id}", 0)
      (Time.now.to_i - last.to_i) >= CHECK_INTERVAL
    rescue StandardError
      true
    end

    def mark_checked(id)
      return unless defined?(Sketchup)
      Sketchup.write_default(SECTION, "last_#{id}", Time.now.to_i)
    rescue StandardError
      nil
    end

    # Дата установки текущей сборки расширения (unixtime) или nil, если
    # неизвестна (расширение ставилось не через апдейтер/Store).
    def installed_at(id)
      return nil unless defined?(Sketchup)
      v = Sketchup.read_default(SECTION, "installed_at_#{id}")
      v.to_i > 0 ? v.to_i : nil
    rescue StandardError
      nil
    end

    def mark_installed(id, time = Time.now)
      return unless defined?(Sketchup)
      Sketchup.write_default(SECTION, "installed_at_#{id}", time.to_i)
    rescue StandardError
      nil
    end

    # Асинхронный режим имеет смысл только в живом SketchUp с таймерами UI.
    def async_ui?
      defined?(UI) && UI.respond_to?(:start_timer) &&
        defined?(Sketchup) && Sketchup.respond_to?(:temp_dir)
    end

    def http_get(uri_or_str, redirects_left = 5)
      uri = uri_or_str.is_a?(URI) ? uri_or_str : URI.parse(uri_or_str.to_s)
      loop do
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == 'https')
        http.open_timeout = 4
        http.read_timeout = 6
        req = Net::HTTP::Get.new(uri.request_uri, HEADERS)
        if uri.host == 'api.github.com' && ENV['GITHUB_TOKEN'] && !ENV['GITHUB_TOKEN'].empty?
          req['Authorization'] = "Bearer #{ENV['GITHUB_TOKEN']}"
        end
        res = http.request(req)
        case res
        when Net::HTTPRedirection
          location = res['location'].to_s
          return res if location.empty? || (redirects_left -= 1) < 0
          uri = URI.join(uri.to_s, location)
        else
          return res
        end
      end
    end

    def asset_url(release, wanted)
      assets = release['assets'].is_a?(Array) ? release['assets'] : []
      hit = assets.find { |a| a.is_a?(Hash) && a['name'].to_s.casecmp?(wanted.to_s) }
      hit ||= assets.find do |a|
        next false unless a.is_a?(Hash)
        name = a['name'].to_s
        base = wanted.to_s.sub(/\.rbz\z/i, '')
        name.end_with?('.rbz') && name.downcase.include?(base.downcase)
      end
      return hit['browser_download_url'].to_s if hit && hit['browser_download_url'].to_s != ''
      ''
    end

    # Фоновая (незапрошенная) проверка — ненавязчивое уведомление вместо модалки;
    # YES/NO-диалог остаётся для проверки по явному запросу (force).
    def offer_install(summary, background: false)
      return nil if background && notify_background(summary)

      offer_dialog(summary)
    end

    # Уведомление в системном центре (SU2017+). false, если недоступно.
    def notify_background(summary)
      return false unless defined?(UI) && UI.respond_to?(:notification_available?) &&
                          UI.notification_available?

      note = UI::Notification.new(
        summary[:id].to_s,
        "#{update_headline(summary)}Нажмите, чтобы открыть страницу релиза."
      )
      note.onclick { open_url(summary[:page_url]) }
      note.show
      true
    rescue StandardError => e
      log_error(e)
      false
    end

    # Заголовок уведомления об обновлении. При переизпуске той же версии
    # «доступна версия X (у вас X)» сбивает с толку — формулируем через дату.
    def update_headline(summary)
      if summary[:same_version]
        "Опубликована обновлённая сборка версии #{summary[:latest]} " \
          "(ваша установлена раньше).\n"
      else
        "Доступна версия #{summary[:latest]} (у вас #{summary[:current]}).\n"
      end
    end

    # Диалог установки (YES/NO) — по явному запросу пользователя.
    def offer_dialog(summary)
      if summary[:asset_url].to_s.empty?
        return unless ask("#{summary[:id]}: #{update_headline(summary)}" \
                          'Открыть страницу релизов?')
        open_url(summary[:page_url])
        return
      end
      msg = "#{summary[:id]}: #{update_headline(summary)}" \
            "\n#{short_notes(summary[:notes])}\n" \
            "\nСкачать и установить обновление сейчас?"
      return unless ask(msg)
      install_from_url(summary[:asset_url], summary[:id], false, id: summary[:id])
    end

    # .rbz — это zip: начинается с "PK".
    def rbz?(path)
      File.open(path, 'rb') { |f| f.read(2) == 'PK' }
    rescue StandardError
      false
    end

    def save_file(body, dest_path)
      return nil unless body.is_a?(String) && body.bytesize > 200
      File.binwrite(dest_path, body)
      dest_path
    rescue StandardError => e
      log_error(e)
      nil
    end

    def temp_dir
      return Sketchup.temp_dir if defined?(Sketchup) && Sketchup.respond_to?(:temp_dir)
      require 'tmpdir'
      Dir.tmpdir
    end

    # Краткая суть изменений для показа пользователю (уведомления, "Что нового"
    # в каталоге): 1-3 строки без markdown, максимум ~200 символов.
    # Подробности остаются в CHANGELOG.md/странице релиза GitHub.
    def short_notes(text, max_len = 200)
      t = text.to_s
      t = t.gsub(/\r/, '')
      t = t.gsub(/!\[[^\]]*\]\([^)]*\)/, '')          # ![img](…)
      t = t.gsub(/\[([^\]]+)\]\([^)]*\)/, '\1')       # [text](url) -> text
      t = t.gsub(/^#{Regexp.escape('#')}+\s*/, '')    # заголовки "# "
      t = t.gsub(/^>\s*/, '')                         # цитаты
      t = t.gsub(/^[-*+]\s+/, '')                     # маркеры списков
      t = t.gsub(/\*\*/, '')                          # жирный
      t = t.gsub(/[*`~]/, '')                         # курсив/код/зачёркивание


      t = t.gsub(/<\/?[a-z][^>]*>/i, '')              # html-теги
      lines = t.split(/\n+/).map { |l| l.squeeze(' ').strip }.reject(&:empty?)
      out = lines.first(3).join("\n")
      return '' if out.empty?
      if out.length > max_len
        cut = out[0, max_len].sub(/\s+\S*\z/, '')
        "#{cut} …"
      else
        out
      end
    end

    def ask(msg)
      return false unless defined?(UI) && UI.respond_to?(:messagebox)
      mb_yesno = defined?(MB_YESNO) ? MB_YESNO : 4
      idyes    = defined?(IDYES) ? IDYES : 6
      UI.messagebox(msg, mb_yesno) == idyes
    end

    def inform(msg)
      return unless defined?(UI) && UI.respond_to?(:messagebox)
      mb_ok = defined?(MB_OK) ? MB_OK : 0
      UI.messagebox(msg, mb_ok)
    end

    def open_url(url)
      return if url.to_s.empty?
      return unless defined?(UI) && UI.respond_to?(:openURL)
      UI.openURL(url)
    end

    # Ошибки всегда дописываются в лог-файл (Sketchup.temp_dir/dn1sup_updater.log);
    # в консоль — только при включённом флаге debug в privatepref.
    def log_error(err)
      append_log("#{Time.now.strftime('%Y-%m-%d %H:%M:%S')} [ERROR] #{err.class}: #{err.message}",
                 err.backtrace.to_a.first(5))
      return unless debug?

      puts "DN1Sup Updater error: #{err.class}: #{err.message}"
      puts(err.backtrace.to_a.first(5).join("\n"))
    rescue StandardError
      nil
    end

    # Информационные записи о ключевых событиях (изменения, установка/удаление,
    # открытие каталога) — всегда пишутся в краткий прикладной лог.
    def log_info(message)
      append_log("#{Time.now.strftime('%Y-%m-%d %H:%M:%S')} [INFO] #{message}", [])
      return unless debug?

      puts "DN1Sup Updater: #{message}"
    rescue StandardError
      nil
    end

    # Подробные записи (каждая команда UI, каждый сетевой запрос, отрисовка) —
    # только в dev-режиме (Sketchup.write_default('Dn1supUpdater', 'debug', true))
    # или в консоль при debug. В обычном прикладном логе не мусорят.
    def log_debug(message)
      return unless debug?

      append_log("#{Time.now.strftime('%Y-%m-%d %H:%M:%S')} [DEBUG] #{message}", [])
      puts "DN1Sup Updater (debug): #{message}"
    rescue StandardError
      nil
    end

    def debug?
      defined?(Sketchup) && Sketchup.respond_to?(:read_default) &&
        Sketchup.read_default(SECTION, 'debug', false)
    end

    def append_log(line, backtrace = [])
      @log_mutex ||= Mutex.new
      @log_mutex.synchronize do
        path = File.join(temp_dir, 'dn1sup_updater.log')
        File.rename(path, "#{path}.old") if File.file?(path) && File.size(path) > LOG_SIZE_LIMIT
        File.open(path, 'a') { |f| f.puts(line, *backtrace) }
      end
    rescue StandardError
      nil
    end

    def log_last_error(err)
      log_error(err)
    end
  end
end
