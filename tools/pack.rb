#!/usr/bin/env ruby
# frozen_string_literal: true

# tools/pack.rb — сборка .rbz-архивов для каждого расширения.
#
#   ruby tools/pack.rb                  # собрать все расширения из registry.json
#   ruby tools/pack.rb dn1sup_time_project2 # собрать одно
#
# Исходники расширений:
# - dn1sup_ext_manager: хранится локально в репозитории (src/)
# - dn1sup_autoselect_tag, dn1sup_comp_add_view, dn1sup_time_project2:
#   берутся напрямую из внешних рабочих директорий (../dn1sup_*)
#   и НЕ хранятся внутри репозитория dn1sup_extensions.
#
# В корень .rbz кладётся loader-файл <id>.rb, а папка <id>/ копируется целиком.
# Версии автоматически считываются из лоадеров внешних проектов и обновляются в registry.json.
# Общие файлы из shared/ (dn1sup_updater.rb) синхронизируются в архив автоматически.

require 'json'
require 'fileutils'
require 'tmpdir'

reg_path       = File.expand_path('../registry.json', __dir__)
shared_updater = File.expand_path('../shared/dn1sup_updater.rb', __dir__)
id_filter      = ARGV[0]

# Базовый путь к внешним папкам проектов расширений
EXT_BASE = ENV['SKETCHUP_EXT_ROOT'] || File.expand_path('../..', __dir__)

# Что не должно попадать в релизный .rbz
DEV_EXCLUDE_FILES = %w[
  dev_updater.rb
  .sketchup_dev.json
  README.md
  README.MD
  .gitignore
  package.json
].freeze

DEV_EXCLUDE_DIRS = %w[
  test
  tests
  .git
  .zcode
  archive
  node_modules
  frontend
].freeze

# Конфигурация источников: в репозитории менеджера собирается только сам менеджер
SOURCES = {
  'dn1sup_ext_manager' => {
    loader: File.expand_path('../src/dn1sup_ext_manager.rb', __dir__),
    dir:    File.expand_path('../src/dn1sup_ext_manager', __dir__)
  }
}.freeze

def resolve_source(id)
  cfg = SOURCES[id]
  return nil unless cfg

  loader = cfg[:loader]
  dir    = cfg[:dir]
  return cfg if File.file?(loader) && File.directory?(dir)
  nil
end

def extract_version(loader_path, dir_path)
  if File.file?(loader_path)
    content = File.read(loader_path)
    if content =~ /(?:extension|ext)\.version\s*=\s*['"]([^'"]+)['"]/i
      return Regexp.last_match(1)
    end
    if content =~ /VERSION\s*=\s*['"]([^'"]+)['"]/
      return Regexp.last_match(1)
    end
  end

  main_rb = File.join(dir_path, 'main.rb')
  if File.file?(main_rb)
    content = File.read(main_rb)
    if content =~ /VERSION\s*=\s*['"]([^'"]+)['"]/
      return Regexp.last_match(1)
    end
  end

  nil
end

def pack(id, source, shared_updater, reg_path)
  src_loader = source[:loader]
  src_dir    = source[:dir]
  target_loader_name = source[:target_loader_name] || "#{id}.rb"
  target_dir_name    = source[:target_dir_name] || id
  out        = File.expand_path("../packages/#{id}.rbz", __dir__)

  raise "нет loader-файла #{src_loader}" unless File.file?(src_loader)
  raise "нет директории плагина #{src_dir}" unless File.directory?(src_dir)

  FileUtils.mkdir_p(File.dirname(out))
  FileUtils.rm_f(out)

  Dir.mktmpdir do |tmp|
    stage = File.join(tmp, 'stage')
    FileUtils.mkdir_p(stage)

    # 1. Лоадер
    stage_loader = File.join(stage, target_loader_name)
    if source[:target_loader_name] && source[:target_loader_name] != File.basename(src_loader)
      content = File.read(src_loader)
      content = content.gsub(/File\.join\(['"][^'"]+['"],\s*['"]main['"]\)/, "File.join('#{target_dir_name}', 'main')")
      content = content.gsub(/'ComponentAddViews'/, "'DN1Sup Component Add View'")
      File.write(stage_loader, content)
    else
      FileUtils.cp(src_loader, stage_loader)
    end

    # 2. Папка плагина
    stage_plugin_dir = File.join(stage, target_dir_name)
    FileUtils.cp_r(src_dir, stage_plugin_dir)

    # 3. Синхронизация dn1sup_updater.rb в упаковываемый архив
    if File.file?(shared_updater)
      FileUtils.cp(shared_updater, File.join(stage_plugin_dir, 'dn1sup_updater.rb'))
    end

    # 4. Для dn1sup_ext_manager: комплектуем актуальный data/registry.json
    if id == 'dn1sup_ext_manager' && File.file?(reg_path)
      data_dir = File.join(stage_plugin_dir, 'data')
      FileUtils.mkdir_p(data_dir)
      FileUtils.cp(reg_path, File.join(data_dir, 'registry.json'))
    end

    # 5. Выкидываем dev-файлы из архива
    DEV_EXCLUDE_FILES.each { |f| FileUtils.rm_f(File.join(stage_plugin_dir, f)) }
    DEV_EXCLUDE_DIRS.each  { |d| FileUtils.rm_rf(File.join(stage_plugin_dir, d)) }

    # 6. Архивация в .rbz
    zip_ok = false
    if system('zip', '-qr', out, '.', chdir: stage)
      zip_ok = true
    else
      begin
        require 'zip'
      rescue LoadError
        raise 'Не найден ни системный zip, ни гем rubyzip. Установите zip в PATH или `gem install rubyzip`.'
      end
      Zip::File.open(out, create: true) do |zipfile|
        Dir[File.join(stage, '**', '*')].each do |path|
          next if File.directory?(path)
          zipfile.add(path.delete_prefix("#{stage}/"), path)
        end
      end
      zip_ok = true
    end

    raise "Ошибка архивации #{out}" unless zip_ok && File.file?(out)
  end

  puts "  -> packages/#{id}.rbz (#{File.size(out)} bytes)"
end

registry = JSON.parse(File.read(reg_path))
built = 0
registry_updated = false

registry.each do |entry|
  id = entry['id']
  next if id_filter && id != id_filter

  source = resolve_source(id)
  next unless source && File.file?(source[:loader]) && File.directory?(source[:dir])

  detected_ver = extract_version(source[:loader], source[:dir])
  if detected_ver && detected_ver != entry['version']
    puts "Обновление версии #{id}: #{entry['version']} -> #{detected_ver}"
    entry['version'] = detected_ver
    registry_updated = true
  end

  print "Packing #{id} (v#{entry['version']})..."
  pack(id, source, shared_updater, reg_path)
  built += 1
end

# Всегда синхронизируем актуальный registry.json в src/dn1sup_ext_manager/data/registry.json
local_reg = File.expand_path('../src/dn1sup_ext_manager/data/registry.json', __dir__)
if File.directory?(File.dirname(local_reg))
  FileUtils.cp(reg_path, local_reg)
end

if registry_updated
  File.write(reg_path, JSON.pretty_generate(registry) + "\n")
  FileUtils.cp(reg_path, local_reg) if File.directory?(File.dirname(local_reg))
  puts "Обновлён registry.json с актуальными версиями."
end

if built.zero?
  warn "Ошибка: не найдено ни одного расширения для сборки#{id_filter ? " по фильтру '#{id_filter}'" : ''}."
  exit 1
end

puts "\nГотово: #{built} .rbz в packages/."
