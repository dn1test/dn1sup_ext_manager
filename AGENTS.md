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
- **Иконки:** `icons/` в корне — источник (`store.svg` + PNG 16/24/32);
  `src/dn1sup_ext_manager/icons/` — копия для .rbz. Знак един для тулбара,
  меню (`catalog_command`) и шапки GUI (`Header.vue`). Знаки продуктов из
  `icons/products/` копируются в `src/dn1sup_ext_manager/icons/products/`
  скриптом `tools/make_icons.rb` (фолбэк-иконки общей панели
  `dn1sup_shared_toolbar.rb`) — ручной sync не нужен.
- **Общая панель «DN1Sup»:** модуль `Dn1sup::SharedToolbar`
  (`src/dn1sup_ext_manager/dn1sup_shared_toolbar.rb` + диалог
  `html/toolbar_settings.html`). Кнопки — таблица `BUTTONS`: `check`
  (константа установленного расширения) + `call` (его модульный метод);
  иконки — glob в папках расширений, фолбэк — плитки `icons/products/`.
  Удаление кнопок из тулбара SketchUp не поддерживает: включение
  применяется сразу, отключение — после перезапуска.
- **Параметр «Показывать отдельные тулбары расширений»**
  (pref `DN1Sup ExtManager` / `shared_toolbar_show_individual`, по
  умолчанию выключен): расширения с guard'ом (версии в таблице
  `INDIVIDUAL_TOOLBARS`) при выключенном параметре не создают свой
  тулбар — его нет в списке панелей SketchUp. Конструировать
  `UI::Toolbar.new` по имени для несуществующей панели нельзя — она
  регистрируется в списке («фантом»); см. `panel_may_exist?`.
- **Тесты:** `ruby test/smoke_test.rb`; после изменений — коммит и push.
- Версии других расширений DN1Sup ведутся в их собственных репозиториях —
  здесь их не дублировать.
