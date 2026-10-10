# frozen_string_literal: true

# Тело GitHub Release из верхней секции CHANGELOG.md — то, что карточка
# «DN1Sup Extension Store» показывает строкой «Что нового». Лог изменений —
# обязательная часть релиза: пользователь должен видеть, что изменилось;
# выпускать релизы без тела нельзя. Вызывается CI перед созданием релиза.
# Если в CHANGELOG.md нет секции с версией (забыли дописать) — берём
# последнюю известную секцию: это лучше пустого тела.

md = File.exist?('CHANGELOG.md') ? File.read('CHANGELOG.md', encoding: 'UTF-8') : ''
head = md.match(/^[#]{1,6}\s+[^\n]*\d+\.\d+[^\n]*$/)
body = ''
if head
  level = head.to_s[/\A#+/].length
  tail = md[head.end(0)..].to_s
  nxt = tail.match(/^#{'[#]' * level}\s+/)
  body = (nxt ? tail[0...nxt.begin(0)] : tail)
         .gsub(/^[#]{1,6}\s+[^\n]*(\n|\z)/, '')
         .strip
end
tag = ENV['GITHUB_REF_NAME'].to_s
body = "Обновление #{tag}." if body.empty? && !tag.empty?
File.write('release_body.md', body.empty? ? '' : body + "\n", encoding: 'UTF-8')
