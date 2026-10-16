# frozen_string_literal: true
# =============================================================================
# tools/apply_icons.rb — установка фирменных знаков тулбара из icons/products/
# в репозитории расширений DN1Sup: копирование под конвенции каждого репо,
# удаление осиротевших файлов, подъём версии (код + registry.json) и запись
# в CHANGELOG. Репозитории ищутся в SKETCHUP_EXT_ROOT или на уровень выше.
#
#   ruby tools/apply_icons.rb --dry   # показать план без изменений
#   ruby tools/apply_icons.rb         # применить
#
# После скрипта по каждому репо: тесты, коммит и push — вручную.
# =============================================================================

require 'fileutils'

ROOT = ENV['SKETCHUP_EXT_ROOT'] || File.expand_path('../..', __dir__)
SRC  = File.expand_path('../icons/products', __dir__)
DRY  = ARGV.include?('--dry')
DATE = Time.now.strftime('%Y-%m-%d')

def repo(*parts)
  File.join(ROOT, *parts)
end

# Первый существующий путь из кандидатов (конвенции вложенности различаются).
def first_existing(candidates)
  candidates.find { |p| File.exist?(repo(p)) }
end

ENTRY_BODY = <<~TXT
  - **Фирменный знак тулбара DN1Sup** — единый стиль каталога Extension
    Store: %<note>s, прозрачный фон, вырезы — настоящая прозрачность
    (SVG-маска; PNG 16/24 — альфа-канал). Источник знака —
    `dn1sup_extensions` → `icons/products/` (`tools/make_icons.rb`).
TXT

PLAN = [
  {
    repo: 'dn1sup_time_project', name: 'DN1Sup Time Project',
    from: '0.7.4', to: '0.7.5', note: 'часы со стрелками (sky)',
    files: {
      'dn1sup_time_project.svg'    => 'dn1sup_time_project/dn1sup_time_project/dn1sup_time_project/icons/timer.svg',
      'dn1sup_time_project_16.png' => 'dn1sup_time_project/dn1sup_time_project/dn1sup_time_project/icons/timer_16.png',
      'dn1sup_time_project_24.png' => 'dn1sup_time_project/dn1sup_time_project/dn1sup_time_project/icons/timer_24.png'
    },
    version_files: [
      'dn1sup_time_project/dn1sup_time_project/dn1sup_time_project/main.rb',
      'dn1sup_time_project/dn1sup_time_project/dn1sup_time_project.rb'
    ]
  },
  {
    repo: 'dn1sup_create_project', name: 'DN1Sup Create Project',
    from: '0.5.3', to: '0.5.4', note: 'папка проекта с плюсом (emerald)',
    files: {
      'dn1sup_create_project.svg'    => 'dn1sup_create_project/dn1sup_create_project/dn1sup_create_project/icons/cp.svg',
      'dn1sup_create_project_16.png' => 'dn1sup_create_project/dn1sup_create_project/dn1sup_create_project/icons/cp_16.png',
      'dn1sup_create_project_24.png' => 'dn1sup_create_project/dn1sup_create_project/dn1sup_create_project/icons/cp_24.png',
      'dn1sup_create_project_32.png' => 'dn1sup_create_project/dn1sup_create_project/dn1sup_create_project/icons/cp_32.png'
    },
    remove: [
      'dn1sup_create_project/dn1sup_create_project/dn1sup_create_project/icons/cp_48.png',
      'dn1sup_create_project/dn1sup_create_project/dn1sup_create_project/icons/cp_64.png'
    ],
    extra: ['- Удалены неиспользуемые кодом `cp_48.png` / `cp_64.png` (старый стиль).'],
    version_files: [
      'dn1sup_create_project/dn1sup_create_project/dn1sup_create_project/main.rb',
      'dn1sup_create_project/dn1sup_create_project/dn1sup_create_project.rb'
    ]
  },
  {
    repo: 'dn1sup_autoselect_tag', name: 'DN1Sup AutoSelect Tag',
    from: '0.6.2', to: '0.6.3', note: 'бирка с искрой «авто» (violet)',
    files: {
      'dn1sup_autoselect_tag.svg' => 'dn1sup_autoselect_tag/dn1sup_autoselect_tag/dn1sup_autoselect_tag/icons/tag.svg'
    },
    version_files: [
      'dn1sup_autoselect_tag/dn1sup_autoselect_tag/dn1sup_autoselect_tag/main.rb',
      'dn1sup_autoselect_tag/dn1sup_autoselect_tag/dn1sup_autoselect_tag.rb'
    ]
  },
  {
    repo: 'dn1sup_comp_add_view', name: 'DN1Sup Comp Add View',
    from: '0.8.2', to: '0.8.3', note: 'плитка-копия и плитка с плюсом (amber)',
    files: {
      'dn1sup_comp_add_view.svg' => 'dn1sup_comp_add_view/dn1sup_comp_add_view/resources/panel.svg'
    },
    version_files: [
      'dn1sup_comp_add_view/dn1sup_comp_add_view/main.rb',
      'dn1sup_comp_add_view/dn1sup_comp_add_view.rb'
    ]
  },
  {
    repo: 'dn1sup_save_settings', name: 'DN1Sup Save Settings',
    from: '0.14.5', to: '0.14.6', note: 'ползунки настроек (slate)',
    files: {
      'dn1sup_save_settings.svg'    => 'dn1sup_save_settings/dn1sup_save_settings/dn1sup_save_settings/icons/ss.svg',
      'dn1sup_save_settings_16.png' => 'dn1sup_save_settings/dn1sup_save_settings/dn1sup_save_settings/icons/ss_16.png',
      'dn1sup_save_settings_24.png' => 'dn1sup_save_settings/dn1sup_save_settings/dn1sup_save_settings/icons/ss_24.png'
    },
    version_files: [
      'dn1sup_save_settings/dn1sup_save_settings/dn1sup_save_settings/main.rb',
      'dn1sup_save_settings/dn1sup_save_settings/dn1sup_save_settings.rb'
    ]
  },
  {
    repo: 'dn1sup_export_3d', name: 'DN1Sup Export 3D',
    from: '0.9.7', to: '0.9.8', note: 'изометрический куб (cyan)',
    files: {
      'dn1sup_export_3d.svg'    => 'dn1sup_export_3d/dn1sup_export_3d/icons/export.svg',
      'dn1sup_export_3d_16.png' => 'dn1sup_export_3d/dn1sup_export_3d/icons/export_16.png',
      'dn1sup_export_3d_24.png' => 'dn1sup_export_3d/dn1sup_export_3d/icons/export_24.png'
    },
    version_files: ['dn1sup_export_3d/dn1sup_export_3d/version.rb']
  },
  {
    repo: 'dn1sup_export_pdf2', name: 'DN1Sup Export PDF 2',
    from: '2.21.6', to: '2.21.7', note: 'три знака команд — диалог, быстрый экспорт (молния), рамка пропорций (rose)',
    files: {
      'dn1sup_export_pdf2__export_dialog.svg'    => 'dn1sup_export_pdf2/dn1sup_export_pdf2/ico/export_dialog.svg',
      'dn1sup_export_pdf2__export_dialog_16.png' => 'dn1sup_export_pdf2/dn1sup_export_pdf2/ico/export_dialog.png',
      'dn1sup_export_pdf2__export_dialog_24.png' => 'dn1sup_export_pdf2/dn1sup_export_pdf2/ico/export_dialog_large.png',
      'dn1sup_export_pdf2__quick_export.svg'     => 'dn1sup_export_pdf2/dn1sup_export_pdf2/ico/quick_export.svg',
      'dn1sup_export_pdf2__quick_export_16.png'  => 'dn1sup_export_pdf2/dn1sup_export_pdf2/ico/quick_export.png',
      'dn1sup_export_pdf2__quick_export_24.png'  => 'dn1sup_export_pdf2/dn1sup_export_pdf2/ico/quick_export_large.png',
      'dn1sup_export_pdf2__frame_overlay.svg'    => 'dn1sup_export_pdf2/dn1sup_export_pdf2/ico/frame_overlay.svg',
      'dn1sup_export_pdf2__frame_overlay_16.png' => 'dn1sup_export_pdf2/dn1sup_export_pdf2/ico/frame_overlay.png',
      'dn1sup_export_pdf2__frame_overlay_24.png' => 'dn1sup_export_pdf2/dn1sup_export_pdf2/ico/frame_overlay_large.png'
    },
    remove: [
      'dn1sup_export_pdf2/dn1sup_export_pdf2/ico/project_info.png',
      'dn1sup_export_pdf2/dn1sup_export_pdf2/ico/project_info.svg',
      'dn1sup_export_pdf2/dn1sup_export_pdf2/ico/project_info_large.png'
    ],
    extra: [
      '- Заодно исправлены битые PNG «Быстрого экспорта» (нестандартный IHDR,',
      '  GDI+ показывал «Out of memory» — иконка не отображалась).',
      '- Удалены осиротевшие `ico/project_info.*` (кодом не использовались).'
    ],
    version_files: ['dn1sup_export_pdf2/dn1sup_export_pdf2/version.rb']
  },
  {
    repo: 'dn1sup_sketchup_profiles', name: 'DN1Sup SketchUp Profiles',
    from: '0.6.3', to: '0.6.4', note: 'два профиля (indigo)',
    files: {
      'dn1sup_sketchup_profiles.svg' => 'dn1sup_sketchup_profiles/dn1sup_sketchup_profiles/icons/profiles.svg'
    },
    version_files: [
      'dn1sup_sketchup_profiles/dn1sup_sketchup_profiles/profile_core.rb',
      'dn1sup_sketchup_profiles/dn1sup_sketchup_profiles.rb'
    ]
  }
].freeze

# Пути с различающейся вложенностью ищем по кандидатам.
VERSION_CANDIDATES = {
  'dn1sup_export_3d/version.rb' => %w[dn1sup_export_3d/dn1sup_export_3d/version.rb dn1sup_export_3d/version.rb],
  'dn1sup_export_pdf2/dn1sup_export_pdf2/version.rb' => %w[dn1sup_export_pdf2/dn1sup_export_pdf2/version.rb dn1sup_export_pdf2/version.rb],
  'dn1sup_comp_add_view/dn1sup_comp_add_view.rb' => %w[dn1sup_comp_add_view/dn1sup_comp_add_view.rb dn1sup_comp_add_view/dn1sup_comp_add_view/dn1sup_comp_add_view.rb],
  'dn1sup_sketchup_profiles/dn1sup_sketchup_profiles.rb' => %w[dn1sup_sketchup_profiles/dn1sup_sketchup_profiles.rb dn1sup_sketchup_profiles/dn1sup_sketchup_profiles/dn1sup_sketchup_profiles.rb]
}.freeze

def resolve(rel)
  return rel if File.exist?(repo(rel))

  first_existing(VERSION_CANDIDATES[rel] || [rel]) || rel
end

def replace_version!(path, from, to)
  s = File.read(path, encoding: 'UTF-8')
  unless s.include?(from)
    warn "  !! #{path}: версия #{from} не найдена — пропущено"
    return
  end
  File.write(path, s.gsub(from, to), encoding: 'UTF-8')
  puts "  ↺ версия #{from} → #{to}: #{path}"
end

def patch_changelog!(item)
  path = repo(item[:repo], 'CHANGELOG.md')
  unless File.file?(path)
    warn "  !! CHANGELOG.md не найден: #{path}"
    return
  end
  s = File.read(path, encoding: 'UTF-8')
  return if s.include?("## [#{item[:to]}]")

  entry = <<~TXT
    ## [#{item[:to]}] — #{DATE}

    ### #{item[:name]} (v#{item[:to]})
    #{format(ENTRY_BODY, note: item[:note])}#{(item[:extra] || []).join("\n")}

  TXT
  idx = s.index(/^## \[/)
  s = idx ? s.insert(idx, entry) : s + "\n" + entry
  File.write(path, s, encoding: 'UTF-8')
  puts "  + CHANGELOG: ## [#{item[:to]}]"
end

PLAN.each do |item|
  puts "#{item[:repo]} (v#{item[:from]} → v#{item[:to]}):"

  item[:files].each do |src, dst|
    src_path = File.join(SRC, src)
    dst_path = repo(dst)
    raise "нет источника #{src_path}" unless File.file?(src_path)

    if DRY
      puts "  · #{src} → #{dst_path.sub(ROOT + File::SEPARATOR, '')}"
    else
      raise "нет папки назначения #{File.dirname(dst_path)}" unless File.directory?(File.dirname(dst_path))

      FileUtils.cp(src_path, dst_path)
      puts "  ✓ #{File.basename(dst_path)}"
    end
  end

  (item[:remove] || []).each do |rel|
    p = repo(rel)
    if File.exist?(p)
      if DRY
        puts "  · удалить #{rel}"
      else
        File.delete(p)
        puts "  − удалён #{File.basename(p)}"
      end
    end
  end

  next if DRY

  item[:version_files].each do |rel|
    replace_version!(repo(resolve(rel)), item[:from], item[:to])
  end
  replace_version!(repo(item[:repo], 'registry.json'), "\"version\": \"#{item[:from]}\"", "\"version\": \"#{item[:to]}\"")
  patch_changelog!(item)
end

puts DRY ? "\nDry-run: изменения не применены." : "\nГотово: знаки установлены, версии и CHANGELOG обновлены." \
