# frozen_string_literal: true

begin
  require 'sketchup.rb'
rescue LoadError
  # Standalone environment outside SketchUp
end
require 'net/http'
require 'uri'

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
      return {} unless res.is_a?(Net::HTTPSuccess)
      JSON.parse(res.body)
    rescue StandardError, ScriptError => e
      log_error(e)
      {}
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

    # Установка .rbz с любого URL через официальный Sketchup.install_from_archive.
    def install_from_url(url, what = 'расширение', silent = false)
      url = url.to_s
      return false if url.empty?
      unless defined?(Sketchup) && Sketchup.respond_to?(:install_from_archive)
        inform("#{what}: Sketchup.install_from_archive недоступен в этой версии SketchUp.") unless silent
        return false
      end
      path = download_to_temp(url)
      unless path
        inform("#{what}: не удалось скачать обновление.\n" \
               'Проверьте соединение или скачайте .rbz вручную со страницы релиза.') unless silent
        return false
      end
      unless rbz?(path)
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
      if ok
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

    # Сетевая часть проверки (может выполняться в фоне): { release:, latest: } или nil.
    # latest — per-extension версия из registry.json либо тег релиза.
    def fetch_latest(cfg)
      release = latest_release(cfg[:repo].to_s)
      return nil unless release.is_a?(Hash) && release.key?('tag_name')

      entry = registry_entry(cfg[:repo].to_s, cfg[:id].to_s)
      ver   = entry.is_a?(Hash) ? entry['version'].to_s : ''
      { release: release, latest: ver != '' ? ver : release['tag_name'].to_s }
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
      unless newer?(latest, current)
        inform("#{id_str}: у вас уже установлена актуальная версия (#{cfg[:version]}).") if force && !silent
        return nil
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
      offer_install(summary, background: !force) unless silent
      summary
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
        "Доступна версия #{summary[:latest]} (у вас #{summary[:current]}).\n" \
        'Нажмите, чтобы открыть страницу релиза.'
      )
      note.onclick { open_url(summary[:page_url]) }
      note.show
      true
    rescue StandardError => e
      log_error(e)
      false
    end

    # Диалог установки (YES/NO) — по явному запросу пользователя.
    def offer_dialog(summary)
      if summary[:asset_url].to_s.empty?
        return unless ask("#{summary[:id]}: доступна версия #{summary[:latest]} " \
                          "(у вас #{summary[:current]}).\nОткрыть страницу релизов?")
        open_url(summary[:page_url])
        return
      end
      msg = "#{summary[:id]}: доступна версия #{summary[:latest]} (у вас #{summary[:current]}).\n" \
            "\n#{short_notes(summary[:notes])}\n" \
            "\nСкачать и установить обновление сейчас?"
      return unless ask(msg)
      install_from_url(summary[:asset_url], summary[:id])
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

    def short_notes(text)
      t = text.to_s.gsub("\r", '').strip
      t = t.lines.first(8).join("\n")
      if t.length > 500
        t[0, 500].sub(/\s+\S*\z/, '').to_s + ' …'
      else
        t
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
      append_log("#{Time.now.strftime('%Y-%m-%d %H:%M:%S')} #{err.class}: #{err.message}",
                 err.backtrace.to_a.first(5))
      return unless debug?

      puts "DN1Sup Updater error: #{err.class}: #{err.message}"
      puts(err.backtrace.to_a.first(5).join("\n"))
    rescue StandardError
      nil
    end

    def debug?
      defined?(Sketchup) && Sketchup.respond_to?(:read_default) &&
        Sketchup.read_default(SECTION, 'debug', false)
    end

    def append_log(line, backtrace = [])
      path = File.join(temp_dir, 'dn1sup_updater.log')
      File.rename(path, "#{path}.old") if File.file?(path) && File.size(path) > LOG_SIZE_LIMIT
      File.open(path, 'a') { |f| f.puts(line, *backtrace) }
    rescue StandardError
      nil
    end

    def log_last_error(err)
      log_error(err)
    end
  end
end
