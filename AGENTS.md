# AGENTS.md — DN1Sup Extension Store

> **ОБЯЗАТЕЛЬНО ПРОЧИТАТЬ ПЕРЕД РАБОТОЙ — общие правила разработки:**
> мастер `U:\dn1code\sketchup_ext\AGENTS.md` — единственная полная копия
> (публикация: `U:\dn1code\sketchup_ext\PUBLISHING.md`).

- Расширение: `dn1sup_ext_manager` / имя: «DN1Sup Extension Store».
- Критичное: один id без `_dev`-двойников; версию поднимать сразу в двух
  местах (`ext.version` регистратора, `registry.json`); релиз — только при
  зелёных тестах. Локальный чек-лист публикации — в `PUBLISHING.md` этого
  репозитория.

## Локальные правила репозитория

- **Версия менеджера** хранится в коде в двух местах: `src/dn1sup_ext_manager.rb`
  (`extension.version` в лоадере) и `src/dn1sup_ext_manager/main.rb` (`VERSION`);
  при расхождении — приводит к одному значению. `registry.json` обновляется
  скриптом `tools/pack.rb` (читает версию из лоадера).
- **Тесты:** `ruby test/smoke_test.rb`; после изменений — коммит и push.
- Версии других расширений DN1Sup ведутся в их собственных репозиториях —
  здесь их не дублировать.
