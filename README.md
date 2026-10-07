# DN1Sup SketchUp Extensions & Store

Система дистрибуции, каталога и автоматического обновления расширений для SketchUp через GitHub Releases:
- **DN1Sup Extension Store** — встроенный менеджер и каталог расширений с мгновенным открытием (0 мс), поиском, фильтрами, персональными логами изменений и установкой в один клик;
- **Автоматическая проверка обновлений** через модуль [Dn1sup::Updater](shared/dn1sup_updater.rb) (потокобезопасные запросы, таймауты 4–6 с, ненавязчивые уведомления `UI::Notification`);
- **Прямая установка** по постоянным ссылкам на последние релизы GitHub без ручного поиска файлов;
- **Автоматизированная сборка** `.rbz` пакетов напрямую из рабочих директорий проектов (`tools/pack.rb`) с очисткой от dev-файлов.

---

## Состав каталога

| Расширение | Версия | Описание |
|---|---|---|
| [`dn1sup_ext_manager`](src/dn1sup_ext_manager) | `0.3.0` | **Extension Store**: каталог расширений по [registry.json](registry.json), установка и обновление с GitHub в один клик |
| `dn1sup_create_project` | `1.1.0` | **Create Project**: создание и оформление мебельных проектов, структура папок, YAML-карточки, файлы и генерация артикулов (Vue 3) |
| `dn1sup_time_project2` | `2.4.0` | **Time Project 2**: учёт активного рабочего времени, статистика хранится внутри файла модели `.skp` (Vue 3 + Tailwind CSS) |
| `dn1sup_autoselect_tag` | `0.3.0` | **AutoSelect Tag**: автоматическое назначение тегов `Dimension` и `Label` размерам и выноскам с диалогом настроек |
| `dn1sup_comp_add_view` | `1.3.0` | **Component Add View**: создание копий компонентов со сдвигом/поворотом по осям Z и X, проекции видов сверху и сбоку |
| `dn1sup_save_settings` | `0.1.0` | **Save Settings**: резервные копии параметров SketchUp в zip-архив и восстановление, история сохранений с датами (Vue 3 + Tailwind) |

---

## Архитектура обновления

```text
GitHub Release (тег v*)
        │  Сборщик прикрепляет собранные .rbz пакеты к релизу
        ▼
  .rbz в релизе  ──►  https://github.com/dn1test/dn1sup_ext_manager/releases/latest/download/{ID}.rbz
        │             (постоянная прямая ссылка на последний релиз)
        ▼
  Dn1sup::Updater ──► raw.githubusercontent.com/.../registry.json (версия конкретного расширения)
        │             fallback: api.github.com/.../releases/latest
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
1. В верхнем меню выберите: **Extensions → DN1Sup Extension Store → «Каталог расширений…»**.
2. В открывшемся окне каталога нажмите кнопку **«Установить»** напротив нужного расширения.

---

## Структура репозитория и сборка

### Расположение исходников
- Исходный код каталога **Extension Store** находится локально в папке [src/dn1sup_ext_manager](src/dn1sup_ext_manager).
- Исходный код целевых расширений разрабатывается в независимых внешних проектах:
  - `../dn1sup_autoselect_tag`
  - `../dn1sup_comp_add_view`
  - `../dn1sup_create_project`
  - `../dn1sup_time_project2`
- Общий модуль обновления: [shared/dn1sup_updater.rb](shared/dn1sup_updater.rb) (автоматически подставляется в каждый `.rbz` при сборке).

### Команды сборки

```powershell
# Собрать все расширения из registry.json в папку packages/
ruby tools/pack.rb

# Собрать конкретное расширение
ruby tools/pack.rb dn1sup_ext_manager

# Проверить содержимое созданных .rbz архивов
ruby tools/list_rbz.rb
```

Сборщик [tools/pack.rb](tools/pack.rb):
- автоматически извлекает версию из лоадеров проектов;
- синхронизирует версии в [registry.json](registry.json) и во встроенный каталог Store;
- копирует свежий `dn1sup_updater.rb`;
- исключает dev-файлы (`test/`, `.git`, `.zcode`, `node_modules`, `frontend`, `.sketchup_dev.json`).

---

## Версионирование

- **Монорепозиторий**: теги релизов вида `vMAJOR.MINOR.PATCH` (текущий: `v0.5.1`).
- **Расширения**: каждое расширение имеет собственную семантическую версию в `registry.json` и лоадере:
  - **PATCH** (`x.x.+1`): мелкие исправления и багфиксы;
  - **MINOR** (`x.+1.0`): новый функционал, редизайн, доработки интерфейса;
  - **MAJOR** (`+1.0.0`): мажорные изменения архитектуры (только по согласованию).
- Подробные правила описаны в [.agents/rules/versioning.md](.agents/rules/versioning.md).

---

## Тестирование

Набор автоматических тестов для валидации логики версионирования, парсинга реестра и API SketchUp:

```powershell
# Smoke-тесты (симулятор API SketchUp, Updater, кэши, реестр, 404, fallback)
ruby test/smoke_test.rb

# Офлайн-загрузка собранных .rbz в эмуляторе SketchUp API
ruby test/rbz_load_test.rb

# Тесты расширений autoselect_tag и comp_add_view (наблюдатели, тегирование, настройки)
ruby test/new_extensions_mock_test.rb

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
  меню **Extensions → DN1Sup Extension Store → «Проверить обновления менеджера»**.

---

## Подпись и безопасность

Пакеты распространяются напрямую через GitHub Releases без цифровой подписи Trimble Extension Warehouse. При первой установке в SketchUp 2017+ появляется стандартный системный диалог подтверждения доверия — это нормальная практика для расширений сторонних разработчиков.

### Цифровая подпись (перспектива)

Возможна подача пакетов на подпись Trimble (SketchUp 2022+ показывает «подписанный издатель») через [extensions.sketchup.com/extension/sign](https://extensions.sketchup.com/extension/sign); решений о её использовании пока не принималось.
