# Список содержимого .rbz для проверки сборки: ruby tools/list_rbz.rb packages/<id>.rbz
require 'zip'

ARGV.each do |path|
  puts "=== #{path}"
  Zip::File.open(path) do |z|
    z.entries.sort_by(&:name).each { |e| puts "  #{e.name}  (#{e.size})" }
  end
end
