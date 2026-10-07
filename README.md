# DN1Sup Extension Store

Менеджер расширений для SketchUp: каталог, установка и автоматическое
обновление расширений DN1Sup напрямую из их индивидуальных GitHub-репозиториев
(`dn1test/dn1sup_*`) через GitHub Releases.

- **Каталог расширений** с мгновенным открытием (0 мс), поиском, фильтрами и установкой в один клик;
- **Кнопка на панели инструментов** с иконкой для быстрого вызова каталога;
- **Автоматическая проверка обновлений** через модуль [Dn1sup::Updater](shared/dn1sup_updater.rb) (потокобезопасные запросы, таймауты 4–6 с, ненавязчивые уведомления `UI::Notification`);
- **Данные расширений хранятся в их собственных репозиториях**: версии, описания, changelog'и и `.rbz`-ассеты — в релизах `dn1test/dn1sup_*`; здесь — только реестр ссылок.

---

## Реестр каталога

[registry.json](registry.json) содержит **минимум данных, необходимый для
установки и обновлений** других расширений: `id`, `name`, `repo`.
Всё остальное (версии, описания, логи изменений, иконки) ведётся в
репозиториях соответствующих расширений и подтягивается менеджером
динамически из GitHub Releases и raw-метаданных.

```json
[
  { "id": "dn1sup_ext_manager",   "name": "DN1Sup Extension Store",    "repo": "dn1test/dn1sup_ext_manager" },
  { "id": "dn1sup_time_project2", "name": "DN1Sup Time Project 2",     "repo": "dn1test/dn1sup_time_project2" },
  { "id": "dn1sup_create_project","name": "DN1Sup Create Project",     "repo": "dn1test/dn1sup_create_project" },
  { "id": "dn1sup_autoselect_tag","name": "DN1Sup AutoSelect Tag",     "repo": "dn1test/dn1sup_autoselect_tag" },
  { "id": "dn1sup_comp_add_view", "name": "DN1Sup Component Add View", "repo": "dn1test/dn1sup_comp_add_view" },
  { "id": "dn1sup_save_settings", "name": "DN1Sup Save Settings",      "repo": "dn1test/dn1sup_save_settings" }
]
```

Добавление нового расширения в каталог — новая запись `{id, name, repo}` в
[registry.json](registry.json); больше ничего не требуется.

---

## Архитектура обновления

```text
GitHub Release (тег v*) в репозитории каждого расширения
        │  Сборщик расширения прикрепляет .rbz к релизу
        ▼
  Dn1sup::Updater ──► api.github.com/repos/{repo}/releases/latest
        │             (версия, changelog, .rbz-ассет — из релиза расширения)
        │             сетевые запросы в фоновом потоке (defer_async) → уведомление UI::Notification
        ▼
  Sketchup.install_from_archive(path)   → установка расширения
```

---

## Установка

### 1. Первичная установка Extension Store

1. Скачайте актуальный файл [dn1sup_ext_manager.rbz](https://github.com/dn1test/dn1sup_ext_manager/releases/latest/download/dn1sup_ext_manager.rbz).
2. В SketchUp откройте: **Расширения (Extensions) → Extension Manager → Install Extension** и выберите скачанный `.rbz`.
3. Перезапустите SketchUp.

### 2. Установка остальных расширений

После установки менеджера дополнительные файлы вручную скачивать не требуется:
1. В верхнем меню выберите: **Extensions → DN1Sup → Extension Store → «Каталог расширений…»**
   или нажмите кнопку с иконкой на панели инструментов **DN1Sup Extension Store**.
2. В открывшемся окне каталога нажмите кнопку **«Установить»** напротив нужного расширения.

---

## Структура репозитория и сборка

```text
src/dn1sup_ext_manager/   Исходники Extension Store (main.rb, html/, data/, icons/)
src/dn1sup_ext_manager.rb Лоадер (регистрация в SketchUp)
shared/dn1sup_updater.rb  Общий модуль обновлений (копируется в .rbz при сборке)
tools/pack.rb             Сборка .rbz
tools/make_icons.rb       Генерация иконки тулбара (SVG + PNG)
test/                     Тесты менеджера
```

### Команды сборки

```powershell
# Собрать dn1sup_ext_manager.rbz в packages/
ruby tools/pack.rb

# Перегенерировать иконку тулбара
ruby tools/make_icons.rb

# Проверить содержимое созданного .rbz архива
ruby tools/list_rbz.rb
```

Сборщик [tools/pack.rb](tools/pack.rb):
- автоматически извлекает версию из лоадера;
- синхронизирует версии в [registry.json](registry.json) и встроенный кэш;
- копирует свежий `dn1sup_updater.rb` и реестр в архив;
- исключает dev-файлы (`test/`, `.git`, `.zcode`, `node_modules`, `frontend`, `.sketchup_dev.json`).

---

## Версионирование

- **Extension Store**: семантическая версия в лоадере `src/dn1sup_ext_manager.rb` и `main.rb`:
  - **PATCH** (`x.x.+1`): мелкие исправления и багфиксы;
  - **MINOR** (`x.+1.0`): новый функционал, редизайн, доработки интерфейса;
  - **MAJOR** (`+1.0.0`): мажорные изменения архитектуры (только по согласованию).
- **Репозиторий**: теги релизов вида `vMAJOR.MINOR.PATCH`.
- **Другие расширения**: версии и changelog'и ведутся в их собственных репозиториях — см. правила в [.agents/rules/versioning.md](.agents/rules/versioning.md).

---

## Тестирование

```powershell
# Smoke-тесты (симулятор API SketchUp, Updater, кэши, реестр, 404, fallback)
ruby test/smoke_test.rb

# Офлайн-загрузка собранного .rbz в эмуляторе SketchUp API
ruby test/rbz_load_test.rb

# Сетевые тесты к реальному GitHub API (при наличии интернет-соединения)
ruby test/live_github_test.rb
```

---

## Dev-режим

- В Ruby Console SketchUp можно перезагрузить файлы Extension Store без перезапуска программы:
  ```ruby
  Dn1sup::ExtManager.reload
  ```
- Для принудительной проверки обновлений менеджера:
  меню **Extensions → DN1Sup → Extension Store → «Проверить обновления менеджера»**.
- **Подробный (debug) лог**: в прикладной лог `Sketchup.temp_dir/dn1sup_updater.log`
  пишутся только ключевые события (`[INFO]`: открытие каталога, установка/обновление
  и удаление, ошибки `[ERROR]`). Подробные записи (`[DEBUG]`: каждая команда UI,
  каждый сетевой запрос, отрисовка) включаются флагом:
  ```ruby
  Sketchup.write_default('Dn1supUpdater', 'debug', true)
  Dn1sup::ExtManager.reload
  ```
  Подробная история изменений ведётся в [CHANGELOG.md](CHANGELOG.md) и релизах GitHub.

---

## Подпись и безопасность

Пакеты распространяются напрямую через GitHub Releases без цифровой подписи Trimble Extension Warehouse. При первой установке в SketchUp 2017+ появляется стандартный системный диалог подтверждения доверия — это нормальная практика для расширений сторонних разработчиков.

---

## Автор и лицензия

- **Автор**: DN1Sup <dn1codegen@gmail.com>
- **Лицензия**: MIT — см. файл [LICENSE](LICENSE)
