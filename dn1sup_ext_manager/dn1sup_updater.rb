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
# Проверка и установка — только с GitHub (GitHub Releases + registry.json).
# Локальные источники обновления (папка разработки, сборка .rbz на лету)
# удалены; для менеджеров старых версий оставлены заглушки совместимости.
#
# Прогресс для HtmlDialog: передайте в cfg proc status_cb — апдейтер зовёт
# его на главном потоке на каждом этапе:
#   { stage: 'checking' }                              — запрос к GitHub ушёл
#   { stage: 'found', latest:, current: }               — есть что ставить
#   { stage: 'downloading', percent:, received:, total: } — скачивание .rbz
#   { stage: 'installing' }                             — установка архива
#   { stage: 'done', latest:, current: }                — установлено
#   { stage: 'current', current: }                      — уже актуально
#   { stage: 'dismissed' }                              — пользователь отказался
#   { stage: 'error', message:, code: }                 — сеть/установка упала;
#     code 'github_unreachable' — GitHub не отвечает (проверьте позднее),
#     code 'dev_copy' — рабочая копия, проверка GitHub отключена
# При переданном status_cb нативные messagebox для промежуточных/конечных
# состояний не показываются (диалог сам показывает тосты); вопрос
# «скачать и установить сейчас?» остаётся нативным ask.
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

    # Версия общего апдейтера. Копия файла лежит в КАЖДОМ расширении, в память
    # SketchUp загружается одна (кто последний встал — того и методы), поэтому
    # после обновления менеджера в Plugins могут соседствовать копии разных
    # версий. Менеджер сравнивает константу загруженного модуля со своей
    # bundled-копией и догружает свою, если она новее (см. ensure_updater!).
    # Методы при этом обратно совместимы (позиционный Hash опций + kwargs),
    # чтобы старые и новые копии не роняли друг друга с
    # "wrong number of arguments (given 4, expected 3)".
    # v4: только GitHub + status_cb с прогрессом для HtmlDialog.
    # v5: локальные источники обновления удалены (заглушки совместимости);
    # единая копия для всех расширений вместо веток v3/v4.
    UPDATER_VERSION = 5 unless defined?(UPDATER_VERSION) && UPDATER_VERSION.to_i >= 5

    # Причина, по которой рабочая копия не проверяет GitHub (текст для UI):
    # обновления такой копии идут через reload из рабочей папки.
    DEV_COPY_REASON = 'Это рабочая копия из папки разработки: обновления ' \
                      'подтягиваются через reload из рабочей папки, ' \
                      'а проверка GitHub для неё отключена.' unless defined?(DEV_COPY_REASON)

    @checking ||= {}
    @registry_cache ||= {}
    @last_fetch_error ||= nil

    # --- public ------------------------------------------------------------

    # Проверяет обновление только с GitHub. Никогда не бросает исключений наружу.
    # Синхронно возвращает Hash-сводку, если есть более свежая версия, иначе nil.
    # При async: true внутри живого SketchUp сеть уходит в фоновый поток,
    # UI показывается по готовности на главном потоке — метод сразу возвращает nil.
    # cfg[:status_cb] (proc) — этапы проверки/установки для HtmlDialog
    # (см. шапку файла); вызывается всегда на главном потоке.
    def check!(cfg)
      id_str = cfg[:id].to_s
      status_cb = status_cb_of(cfg)
      silent = !!(cfg[:silent] || cfg['silent'])
      if @checking[id_str]
        # Повторное нажатие во время проверки: спиннер в диалоге уже крутится,
        # подтверждаем stage, чтобы UI не завис без ответа.
        emit_status(status_cb, { stage: 'checking', id: id_str }) if status_cb && !silent
        return nil
      end
      if dev_source?
        # Рабочая копия разработки: обновления идут через reload из рабочей
        # папки, а не с GitHub. Молчаливый возврат вешал спиннер кнопки
        # в диалоге навсегда — отдаём явный завершающий stage.
        if status_cb && !silent
          emit_status(status_cb, { stage: 'error', id: id_str, code: 'dev_copy',
                                              message: DEV_COPY_REASON })
        end
        return nil
      end

      @checking[id_str] = true

      force  = !!(cfg[:force] || cfg['force'])
      async  = !!(cfg[:async] || cfg['async']) && async_ui?

      unless force || throttle_ok?(id_str)
        @checking[id_str] = false
        return nil
      end

      emit_status(status_cb, { stage: 'checking', id: id_str })
      work = -> { fetch_latest(cfg) }
      done = lambda do |fetched|
        result = nil
        begin
          result = apply_check(cfg, fetched, force: force, silent: silent,
                                              fetch_error: last_fetch_error)
        rescue StandardError, ScriptError => e
          log_error(e)
          emit_status(status_cb, { stage: 'error', id: id_str, message: e.message.to_s })
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

    # Рабочая копия разработки (один id + reload): код загружен не из
    # папки Plugins SketchUp, а из рабочей папки репозитория — обновления
    # такой копии приходят из рабочей папки через reload, а не из
    # GitHub Releases, поэтому self-update отключён.
    def dev_source?
      dir = File.expand_path(File.dirname(__FILE__))
      !dir.include?('Plugins')
    rescue StandardError
      false
    end

    # Proc прогресса из cfg (:status_cb / 'status_cb', фолбэк :on_status).
    # nil — обычный режим с нативными messagebox.
    def status_cb_of(cfg)
      return nil unless cfg.is_a?(Hash)

      cb = cfg[:status_cb] || cfg['status_cb'] || cfg[:on_status] || cfg['on_status']
      cb.respond_to?(:call) ? cb : nil
    end

    # Безопасный вызов прогресса: никогда не бросает исключений наружу.
    def emit_status(cb, payload)
      return unless cb.respond_to?(:call)
      return unless payload.is_a?(Hash)

      begin
        cb.call(payload)
      rescue StandardError, ScriptError => e
        log_error(e)
      end
    end

    # GET https://api.github.com/repos/{owner}/{repo}/releases/latest
    # Возвращает Hash JSON или {} при любой ошибке (сеть, лимиты и т.п.).
    # Причина недоступности запоминается в last_fetch_error, чтобы проверка
    # могла честно сказать «GitHub не отвечает, проверьте позднее» вместо
    # молчания или ложного «обновлений нет».
    def latest_release(repo)
      require 'net/http'
      require 'json'
      @last_fetch_error = nil
      uri = URI.parse("#{GITHUB_API}/repos/#{repo}/releases/latest")
      res = http_get(uri)
      unless res.is_a?(Net::HTTPSuccess)
        code = res.respond_to?(:code) ? res.code.to_i : 0
        if code == 403 || code == 429
          @last_fetch_error = { kind: 'rate_limit', code: code,
                                retry_after: rate_limit_retry_after(res) }
        else
          @last_fetch_error = { kind: 'http', code: code }
        end
        log_debug("latest_release(#{repo}): HTTP #{res.respond_to?(:code) ? res.code : '?'}")
        return {}
      end
      json = JSON.parse(res.body)
      log_debug("latest_release(#{repo}): OK #{json['tag_name'].to_s}")
      json
    rescue StandardError, ScriptError => e
      @last_fetch_error = { kind: 'network' }
      log_error(e)
      {}
    end

    # Причина последней недоступности GitHub API
    # ({ kind: 'rate_limit'/'network'/'http', code:, retry_after: } в минутах)
    # или nil, если последний запрос релиза прошёл успешно.
    def last_fetch_error
      err = @last_fetch_error
      err.is_a?(Hash) ? err : nil
    end

    # Минут до сброса лимита GitHub API по заголовку x-ratelimit-reset.
    # nil, если заголовка нет или срок уже прошёл.
    def rate_limit_retry_after(res)
      reset = res.respond_to?(:[]) ? res['x-ratelimit-reset'].to_s : ''
      return nil unless reset =~ /\A\d+\z/

      secs = reset.to_i - Time.now.to_i
      return nil unless secs > 0

      (secs / 60) + 1
    rescue StandardError
      nil
    end

    # Короткая причина недоступности GitHub (без «проверьте позднее» —
    # этот призыв добавляет вызывающая сторона на своём языке).
    def github_unreachable_reason(err = nil)
      err = last_fetch_error if err.nil?
      err = {} unless err.is_a?(Hash)
      case err[:kind].to_s
      when 'rate_limit'
        mins = err[:retry_after].to_i
        base = 'превышен лимит запросов к GitHub API'
        mins > 0 ? "#{base} (повторите примерно через #{mins} мин.)" : base
      when 'network'
        'нет соединения с GitHub'
      when 'http'
        code = err[:code].to_i
        code > 0 ? "GitHub вернул ошибку HTTP #{code}" : 'GitHub вернул ошибку'
      else
        'релиз на GitHub недоступен'
      end
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
    # /orgs/{owner}/repos. Постранично: per_page=100, до REPOS_MAX_PAGES
    # страниц — иначе при >100 репозиториях хвост молча терялся.
    # Возвращает Array JSON-объектов или [] при ошибке.
    REPOS_MAX_PAGES = 5 unless defined?(REPOS_MAX_PAGES)

    def repos_of_owner(owner)
      require 'net/http'
      require 'json'
      owner = owner.to_s
      %w[users orgs].each do |segment|
        repos = []
        REPOS_MAX_PAGES.times do |i|
          uri = URI.parse("#{GITHUB_API}/#{segment}/#{owner}/repos?per_page=100&page=#{i + 1}&sort=pushed")
          res = http_get(uri)
          break unless res.is_a?(Net::HTTPSuccess)

          json = JSON.parse(res.body)
          break unless json.is_a?(Array)

          repos.concat(json)
          break if json.size < 100
        end
        next if repos.empty?

        log_debug("repos_of_owner(#{owner}): OK #{repos.size} репозиториев (/#{segment}/)")
        return repos
      end
      log_debug("repos_of_owner(#{owner}): недоступно")
      []
    rescue StandardError, ScriptError => e
      log_error(e)
      []
    end

    # Статус репозитория на GitHub: существует, удалён или переименован
    # (для чистки каталога от «мёртвых» записей).
    # GET /repos/{owner}/{repo}: редиректы переименованных репозиториев
    # http_get проходит сам, поэтому итоговое full_name сравнивается с
    # запрошенным именем. Возвращает:
    #   { exists: true,  repo: 'owner/name', renamed: true/false }
    #   { exists: false }                     — HTTP 404 (репозиторий удалён)
    #   nil                                   — сеть/лимиты: статус неизвестен
    def repo_meta(repo)
      require 'net/http'
      require 'json'
      repo = repo.to_s
      uri = URI.parse("#{GITHUB_API}/repos/#{repo}")
      res = http_get(uri)
      unless res.is_a?(Net::HTTPSuccess)
        log_debug("repo_meta(#{repo}): HTTP #{res.respond_to?(:code) ? res.code : '?'}")
        return { exists: false } if res.respond_to?(:code) && res.code.to_i == 404

        return nil
      end
      json = JSON.parse(res.body)
      full = json.is_a?(Hash) ? json['full_name'].to_s : ''
      return nil if full.empty?

      renamed = !full.casecmp?(repo)
      log_debug("repo_meta(#{repo}): OK#{renamed ? " -> #{full}" : ''}")
      { exists: true, repo: renamed ? full : repo, renamed: renamed }
    rescue StandardError, ScriptError => e
      log_error(e)
      nil
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
    # progress — опциональный lambda (received_bytes, total_bytes) для
    # отображения процесса (при нём качает потоково с Content-Length).
    def download_to_temp(url, progress = nil)
      filename = File.basename(URI.parse(url).path.to_s)
      filename = 'download.rbz' if filename.to_s.empty?
      path = File.join(temp_dir, filename)
      if progress.respond_to?(:call)
        download_with_progress(url, path, progress)
      else
        download(url, path)
      end
    rescue StandardError, ScriptError => e
      log_error(e)
      nil
    end

    # Потоковое скачивание с прогрессом: progress.call(received, total)
    # на каждом чанке. Редиректы (GitHub-архивы) проходит сам.
    # Возвращает путь или nil.
    def download_with_progress(url, dest_path, progress = nil)
      require 'net/http'
      require 'uri'
      uri = URI.parse(url.to_s)
      redirects_left = 5
      loop do
        outcome = nil
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == 'https')
        http.open_timeout = 4
        http.read_timeout = 60
        req = Net::HTTP::Get.new(uri.request_uri, HEADERS)
        http.request(req) do |res|
          case res
          when Net::HTTPRedirection
            location = res['location'].to_s
            if location.empty? || redirects_left <= 0
              log_error(RuntimeError.new("HTTP-редирект без location при скачивании #{url}"))
              outcome = :fail
            else
              redirects_left -= 1
              uri = URI.join(uri.to_s, location)
              outcome = :redirect
            end
          when Net::HTTPSuccess
            total = res['content-length'].to_i
            received = 0
            begin
              File.open(dest_path, 'wb') do |f|
                res.read_body do |chunk|
                  f.write(chunk)
                  received += chunk.bytesize
                  begin
                    progress.call(received, total) if progress.respond_to?(:call)
                  rescue StandardError, ScriptError
                    nil
                  end
                end
              end
              outcome = (File.file?(dest_path) && File.size(dest_path) > 200) ? :ok : :fail
            rescue StandardError, ScriptError => e
              log_error(e)
              outcome = :fail
            end
          else
            code = res.respond_to?(:code) ? res.code : 'unknown'
            log_error(RuntimeError.new("HTTP #{code} при скачивании #{url}"))
            outcome = :fail
          end
        end
        case outcome
        when :ok
          return dest_path
        when :redirect
          next
        else
          return nil
        end
      rescue StandardError, ScriptError => e
        log_error(e)
        return nil
      end
    end

    # Загружает текст по URL (для JSON-реестров и т.п.). nil при ошибке.
    def fetch_text(url)
      require 'net/http'
      res = http_get(url)
      # Тело без charset приходит в ASCII-8BIT, а тексты GitHub (registry.json,
      # CHANGELOG.md) — UTF-8: приводим явно, иначе кириллица ломает regex/сравнения.
      res.is_a?(Net::HTTPSuccess) ? res.body.to_s.force_encoding(Encoding::UTF_8) : nil
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
    # opts — позиционный Hash опций ({ installed_at: ... }): так Ruby 2.7
    # упаковывает kwargs при вызове старого 3-аргументного метода, а также
    # явный Hash от совместимых вызывающих. Приоритет — у явных kwargs.
    def product_status(installed_ver, offered, list = nil, opts = nil, installed_at: nil)
      if installed_at.nil? && opts.is_a?(Hash)
        installed_at = opts[:installed_at] if opts.key?(:installed_at)
        installed_at = opts['installed_at'] if installed_at.nil? && opts.key?('installed_at')
      end
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
    # opts — позиционный Hash опций ({ id: ... }): совместимость со старыми
    # вызывающими и упаковкой kwargs на Ruby 2.7. Приоритет — у явного kwargs.
    # status_cb (там же или kwarg) — этапы для HtmlDialog: downloading
    # (percent), installing, done/error. При нём конечные нативные messagebox
    # не показываются — итог рисует диалог.
    def install_from_url(url, what = 'расширение', silent = false, opts = nil, id: nil, progress: nil, status_cb: nil)
      if opts.is_a?(Hash)
        id ||= opts[:id] || opts['id'] if opts.key?(:id) || opts.key?('id')
        progress ||= opts[:progress] || opts['progress']
        status_cb ||= opts[:status_cb] || opts['status_cb'] || opts[:on_status] || opts['on_status']
      end
      status_cb = nil unless status_cb.respond_to?(:call)
      url = url.to_s
      if url.empty?
        log_debug("install_from_url(#{what}): пустой URL — отмена")
        return false
      end
      unless defined?(Sketchup) && Sketchup.respond_to?(:install_from_archive)
        log_debug("install_from_url(#{what}): install_from_archive недоступен")
        inform("#{what}: Sketchup.install_from_archive недоступен в этой версии SketchUp.") unless silent
        emit_status(status_cb, { stage: 'error', id: id, message: 'install_from_archive недоступен' })
        return false
      end
      log_debug("install_from_url(#{what}): скачивание #{url}")
      emit_status(status_cb, { stage: 'downloading', id: id, percent: 0 })
      chunk_cb = nil
      if status_cb
        last_pct = -1
        chunk_cb = lambda do |received, total|
          pct = total.to_i > 0 ? (received.to_f / total * 100).round : 0
          pct = 0 if pct < 0
          pct = 100 if pct > 100
          if pct >= last_pct + 5 || pct >= 100
            last_pct = pct
            emit_status(status_cb, { stage: 'downloading', id: id, percent: pct, received: received, total: total })
          end
        end
      elsif progress.respond_to?(:call)
        chunk_cb = progress
      end
      path = chunk_cb ? download_with_progress(url, File.join(temp_dir, File.basename(URI.parse(url).path.to_s).then { |n| n.empty? ? 'download.rbz' : n }), chunk_cb) : download_to_temp(url)
      unless path
        log_debug("install_from_url(#{what}): скачивание не удалось")
        inform("#{what}: не удалось скачать обновление.\n" \
               'Проверьте соединение или скачайте .rbz вручную со страницы релиза.') unless silent || status_cb
        emit_status(status_cb, { stage: 'error', id: id, message: 'не удалось скачать обновление' })
        return false
      end
      unless rbz?(path)
        log_debug("install_from_url(#{what}): файл #{File.basename(path)} не похож на .rbz")
        inform("#{what}: скачанный файл не похож на .rbz — вероятно, ошибка сети. Попробуйте позже.") unless silent || status_cb
        emit_status(status_cb, { stage: 'error', id: id, message: 'скачанный файл не похож на .rbz' })
        return false
      end
      emit_status(status_cb, { stage: 'installing', id: id, percent: 100 })
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
               'Перезапустите SketchUp, чтобы новый код загрузился.') unless silent || status_cb
        emit_status(status_cb, { stage: 'done', id: id })
      else
        inform("#{what}: SketchUp не удалось установить архив. Скачайте .rbz вручную с GitHub.") unless silent || status_cb
        emit_status(status_cb, { stage: 'error', id: id, message: 'SketchUp не удалось установить архив' })
      end
      ok
    ensure
      File.delete(path) if path && File.file?(path) rescue nil
    end

    # --- совместимость с Extension Store ------------------------------------
    #
    # Обновление — только из GitHub Releases: локальные источники (папка
    # разработки, ENV-переменные, сборка .rbz на лету, копирование в Plugins)
    # удалены. Менеджер расширений старых версий вызывает перечисленные ниже
    # методы без защиты respond_to? — оставляем заглушки «локального
    # источника нет», чтобы каталог менеджера не падал.

    # Раньше — проверка с приоритетом локальной папки; теперь обычная
    # GitHub-проверка (тот же код, что и check!).
    def check_local_first!(cfg)
      check!(cfg)
    end

    def resolve_dev_dir(_cfg)
      nil
    end

    def local_dev_version(_dev_dir, _id)
      ''
    end

    def local_dev_mtime(_dev_dir, _id)
      nil
    end

    def install_from_local_dir(_dev_dir, _id, _display_name = nil)
      log_debug('install_from_local_dir: локальные источники удалены — обновление только из GitHub')
      false
    end

    # Любую дату к unixtime: Time / Integer / строка ISO-8601 / nil -> Integer.
    # Неизвестное/битое — 0 («время неизвестно»).
    def to_unixtime(value)
      return 0 if value.nil?
      return value.to_i if value.is_a?(Numeric)
      return value.to_i if value.is_a?(Time)

      s = value.to_s.strip
      return 0 if s.empty?
      return s.to_i if s =~ /\A\d+\z/

      Time.parse(s).to_i
    rescue StandardError, ArgumentError
      0
    end

    # Источник свежее установленного? Номер версии выше — да; при равном
    # номере — дата/время источника позже даты установки (переизпуск без
    # бампа версии); при более низком номере, но более поздней дате — тоже
    # да (смена схемы нумерации, зеркалит product_status 'switch').
    # Без даты установки — только по номеру версии (как раньше).
    def source_fresher?(installed_norm, source_norm, installed_at_i, source_time_i)
      return true if newer?(source_norm, installed_norm)
      return false unless installed_at_i.to_i > 0 && source_time_i.to_i > installed_at_i.to_i

      true
    end

    # Чистое сравнение трёх источников: :local / :github / :current / :unknown.
    # Локаль и GitHub сравниваются между собой — ставится свежайший.
    # Версии равны, а дата/время источника свежее даты установки
    # (installed_at:, github_time:, local_time:) — тоже свежее, ставится
    # источник с более поздней датой. Без дат — старое поведение (только
    # номера версий). Даты молча игнорируются, когда установка неизвестна.
    # opts — позиционный Hash опций ({ installed_at:, github_time:,
    # local_time: }): так Ruby 2.7 упаковывает kwargs при вызове старого
    # 3-аргументного метода, а также явный Hash от совместимых вызывающих.
    # Приоритет — у явных kwargs.
    def pick_freshest(installed_ver, local_ver, github_ver, opts = nil, installed_at: nil, github_time: nil, local_time: nil)
      if opts.is_a?(Hash)
        if installed_at.nil?
          installed_at = opts[:installed_at] if opts.key?(:installed_at)
          installed_at = opts['installed_at'] if installed_at.nil? && opts.key?('installed_at')
        end
        if github_time.nil?
          github_time = opts[:github_time] if opts.key?(:github_time)
          github_time = opts['github_time'] if github_time.nil? && opts.key?('github_time')
        end
        if local_time.nil?
          local_time = opts[:local_time] if opts.key?(:local_time)
          local_time = opts['local_time'] if local_time.nil? && opts.key?('local_time')
        end
      end
      inst = installed_ver.to_s.sub(/\Av/i, '')
      loc = local_ver.to_s.sub(/\Av/i, '')
      gh = github_ver.to_s.sub(/\Av/i, '')
      return :unknown if loc.empty? && gh.empty?

      inst_at_i = to_unixtime(installed_at)
      gh_t_i = to_unixtime(github_time)
      loc_t_i = to_unixtime(local_time)

      if inst.empty?
        return :github if loc.empty?
        return :local if gh.empty?

        return newer?(norm_version(loc), norm_version(gh)) ? :local : :github
      end

      inst_n = norm_version(inst)
      loc_fresh = loc.empty? ? false : source_fresher?(inst_n, norm_version(loc), inst_at_i, loc_t_i)
      gh_fresh = gh.empty? ? false : source_fresher?(inst_n, norm_version(gh), inst_at_i, gh_t_i)
      # Равная версия без известной даты установки — не свежее (как раньше).
      loc_fresh = false if !loc.empty? && loc == inst && !(newer?(norm_version(loc), inst_n)) && inst_at_i <= 0
      gh_fresh = false if !gh.empty? && gh == inst && !(newer?(norm_version(gh), inst_n)) && inst_at_i <= 0
      return :current unless loc_fresh || gh_fresh
      return :local if loc_fresh && !gh_fresh
      return :github if gh_fresh && !loc_fresh

      loc_n = norm_version(loc)
      gh_n = norm_version(gh)
      return :local if newer?(loc_n, gh_n)
      return :github if newer?(gh_n, loc_n)

      # Версии равны и оба свежее по дате — ставим источник с более поздней
      # датой; при равных датах — локаль (правки разработчика приоритетнее).
      loc_t_i >= gh_t_i ? :local : :github
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
    # При cfg[:status_cb] конечные состояния («актуально» / «сеть упала»)
    # отдаются в диалог этапами current/error без нативных messagebox.
    # Недоступность GitHub — всегда явный error «не отвечает, проверьте
    # позднее», никогда молчание и никогда ложное «обновлений нет».
    def apply_check(cfg, fetched, force: false, silent: false, fetch_error: nil)
      id_str = cfg[:id].to_s
      status_cb = status_cb_of(cfg)
      unless fetched
        reason = github_unreachable_reason(fetch_error)
        if force && !silent && status_cb.nil?
          inform("#{id_str}: GitHub не отвечает (#{reason}). Проверьте позднее.")
        end
        if force && !silent && status_cb
          emit_status(status_cb, { stage: 'error', id: id_str, code: 'github_unreachable',
                                                message: reason })
        end
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
          if force && !silent && status_cb.nil?
            inform("#{id_str}: у вас уже установлена актуальная версия (#{cfg[:version]}).")
          end
          emit_status(status_cb, { stage: 'current', id: id_str, current: cfg[:version].to_s }) if force && !silent
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
      summary[:source] = 'github'
      emit_status(status_cb, { stage: 'found', id: id_str, latest: summary[:latest], current: summary[:current] })
      offer_install(summary, background: !force, status_cb: status_cb) unless silent
      summary
    end

    # Релиз издан позже установленной сборки? Сравнение возможно, только когда
    # известна дата установки текущей версии (пишется при установке через
    # апдейтер/Store) и релиз относится к этому расширению: в монорепо тег
    # релиза может описывать другое расширение, тогда его дата ничего не
    # говорит об этом расширении (версия из registry.json авторитетна).
    def release_newer_than_install?(cfg, fetched)
      return false if fetched[:from_registry] &&
                      fetched[:latest].to_s != fetched[:release]['tag_name'].to_s.sub(/\Av/i, '')

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
    # status_cb — этапы для HtmlDialog (прокидывается в offer_dialog).
    def offer_install(summary, background: false, status_cb: nil)
      return nil if background && notify_background(summary)

      offer_dialog(summary, status_cb: status_cb)
    end

    # Уведомление в системном центре (SU2017+). false, если недоступно.
    def notify_background(summary)
      return false unless defined?(UI) && UI.respond_to?(:notification_available?) &&
                          UI.notification_available?

      note = UI::Notification.new(
        summary[:id].to_s,
        summary[:page_url].to_s.empty? ? "#{update_headline(summary)}Откройте расширение и нажмите «Проверить обновление»." : "#{update_headline(summary)}Нажмите, чтобы открыть страницу релиза."
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
    # При status_cb отказ пользователя отдаётся этапом dismissed, а процесс
    # скачивания/установки — этапами downloading/installing/done/error.
    def offer_dialog(summary, status_cb: nil)
      status_cb = nil unless status_cb.respond_to?(:call)
      if summary[:asset_url].to_s.empty?
        unless ask("#{summary[:id]}: #{update_headline(summary)}" \
                          'Открыть страницу релизов?')
          emit_status(status_cb, { stage: 'dismissed', id: summary[:id] })
          return
        end
        open_url(summary[:page_url])
        emit_status(status_cb, { stage: 'dismissed', id: summary[:id] })
        return
      end
      msg = "#{summary[:id]}: #{update_headline(summary)}" \
            "\n#{short_notes(summary[:notes])}\n" \
            "\nСкачать и установить обновление сейчас?"
      unless ask(msg)
        emit_status(status_cb, { stage: 'dismissed', id: summary[:id] })
        return
      end
      install_from_url(summary[:asset_url], summary[:id], false, id: summary[:id], status_cb: status_cb)
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
        old  = "#{path}.old"
        # Windows: File.rename не перезаписывает существующий .old (Errno::EEXIST),
        # без удаления ротация падала бы и логи замолкали навсегда.
        File.delete(old) if File.file?(old)
        File.rename(path, old) if File.file?(path) && File.size(path) > LOG_SIZE_LIMIT
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
