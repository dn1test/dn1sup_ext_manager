# AGENTS.md — DN1Sup Extension Store

> **ОБЯЗАТЕЛЬНО ПРОЧИТАТЬ ПЕРЕД РАБОТОЙ — общие правила каналов dev / prod**
> (dev-вариант против релизов, dev-цикл, публикация): мастер
> `U:\dn1code\sketchup_ext\AGENTS.md` — единственная полная копия правил
> (публикация: `U:\dn1code\sketchup_ext\PUBLISHING.md`).

- Расширение: `dn1sup_ext_manager` / dev-вариант: `dn1sup_ext_manager_dev` / имя: «DN1Sup Extension Store».
- Критичное, пока мастер не прочитан: id с суффиксом `_dev` никогда не
  публикуются; версию поднимать сразу в трёх местах (`ext.version` регистратора,
  `.sketchup_dev.json`, `registry.json`); релиз — только при зелёных тестах.
  Локальный чек-лист публикации — в `PUBLISHING.md` этого репозитория.

## Локальные правила репозитория

- **Версия менеджера** хранится в коде в двух местах: `src/dn1sup_ext_manager.rb`
  (`extension.version` в лоадере) и `src/dn1sup_ext_manager/main.rb` (`VERSION`);
  при расхождении — приводит к одному значению. `registry.json` обновляется
  скриптом `tools/pack.rb` (читает версию из лоадера).
- **Тесты:** `ruby test/smoke_test.rb`; после изменений — коммит и push.
- Версии других расширений DN1Sup ведутся в их собственных репозиториях —
  здесь их не дублировать.
