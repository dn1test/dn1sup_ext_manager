<template>
  <div class="h-full flex flex-col bg-slate-50 dark:bg-slate-950 text-slate-800 dark:text-slate-100 transition-colors relative">
    <Header
      :version="state.version"
      :refreshing="headerRefreshing"
      :progress-title="headerProgressTitle"
      :filter="filter"
      :counts="counts"
      v-model:view="view"
      @refresh="onRefresh"
      @restart="onRestart"
      @update:filter="filter = $event"
    />

    <!-- Блокирующее первое сканирование после установки -->
    <div
      v-if="isFirstScan"
      class="absolute inset-0 z-40 flex flex-col items-center justify-center gap-3 bg-slate-50/95 dark:bg-slate-950/95 backdrop-blur-sm px-6 text-center"
    >
      <Loader2 class="w-8 h-8 animate-spin text-brand-500" />
      <div class="text-sm font-semibold text-slate-600 dark:text-slate-200">Первое сканирование расширений…</div>
      <div class="text-xs text-slate-400 dark:text-slate-500">
        Ищем последние версии на GitHub. Это займёт меньше минуты.
      </div>
      <div class="w-64 max-w-full h-2 rounded-full bg-slate-200 dark:bg-slate-800 overflow-hidden">
        <div
          class="h-full rounded-full bg-brand-500 transition-all duration-300"
          :style="{ width: firstScanPercent + '%' }"
        ></div>
      </div>
      <div class="text-[11px] tabular-nums text-slate-400 dark:text-slate-500">{{ firstScanText }}</div>
    </div>

    <!-- Поиск и массовые действия -->
    <div class="px-3.5 pt-2 pb-2 flex items-center gap-2 shrink-0">
      <div class="relative flex-1 min-w-[160px]">
        <Search class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-slate-400 dark:text-slate-500 pointer-events-none" />
        <input
          v-model="searchQuery"
          type="text"
          class="es-input !pl-8"
          placeholder="Поиск расширения по названию или ID…"
          autocomplete="off"
          spellcheck="false"
        >
      </div>

      <button
        class="flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs font-medium transition-colors whitespace-nowrap shrink-0
               bg-brand-500 hover:bg-brand-600 text-white shadow-sm disabled:opacity-50 disabled:cursor-not-allowed"
        :disabled="!installCandidates.length || bulkBusy"
        :title="installCandidates.length ? `Установить и обновить: ${installCandidates.length}` : 'Все расширения уже установлены и актуальны'"
        @click="onInstallAll"
      >
        <Download :size="14" />
        <span>Установить все</span>
      </button>
      <button
        class="flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs font-medium transition-colors whitespace-nowrap shrink-0
               bg-slate-200/70 hover:bg-red-100 dark:bg-slate-800 dark:hover:bg-red-900/40
               text-slate-600 hover:text-red-600 dark:text-slate-300 dark:hover:text-red-400
               disabled:opacity-50 disabled:cursor-not-allowed"
        :disabled="!uninstallCandidates.length || bulkBusy"
        :title="uninstallCandidates.length ? `Удалить установленные: ${uninstallCandidates.length}` : 'Нет установленных расширений'"
        @click="onUninstallAll"
      >
        <Trash2 :size="14" />
        <span>Удалить все</span>
      </button>
    </div>

    <!-- Прогресс массовой установки/удаления -->
    <div
      v-if="state.bulk"
      class="mx-3.5 mb-2 rounded-lg border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 px-2.5 py-2 shrink-0"
    >
      <div class="flex items-center gap-2 text-xs font-medium">
        <Loader2 v-if="bulkBusy" class="w-3.5 h-3.5 animate-spin text-brand-500 shrink-0" />
        <CheckCircle2 v-else class="w-3.5 h-3.5 text-emerald-500 shrink-0" />
        <span class="flex-1 min-w-0 truncate">{{ bulkTitle }}</span>
        <span class="tabular-nums text-slate-400 dark:text-slate-500 shrink-0">{{ bulkPercent }}%</span>
      </div>
      <div class="mt-1.5 h-1.5 rounded-full bg-slate-200 dark:bg-slate-800 overflow-hidden">
        <div
          class="h-full rounded-full bg-brand-500 transition-all duration-300"
          :style="{ width: bulkPercent + '%' }"
        ></div>
      </div>
      <ul v-if="state.bulk.done.length || state.bulk.failed.length" class="mt-1.5 max-h-24 overflow-y-auto space-y-0.5 text-[11px] leading-tight">
        <li
          v-for="entry in state.bulk.done"
          :key="'ok-' + entry.id"
          class="flex items-center gap-1.5 text-emerald-600 dark:text-emerald-400"
        >
          <CheckCircle2 :size="11" class="shrink-0" />
          <span class="truncate">{{ entry.name }}</span>
        </li>
        <li
          v-for="entry in state.bulk.failed"
          :key="'fail-' + entry.id"
          class="flex items-center gap-1.5 text-red-500 dark:text-red-400"
        >
          <AlertCircle :size="11" class="shrink-0" />
          <span class="truncate">{{ entry.name }} — не удалось</span>
        </li>
      </ul>
    </div>

    <!-- Каталог -->
    <main class="flex-1 min-h-0 overflow-y-auto px-3.5 pb-5 space-y-2">
      <template v-if="view === 'cards'">
        <ProductCard
          v-for="p in filteredProducts"
          :key="p.id"
          :product="p"
        />
      </template>
      <template v-else>
        <ProductRow
          v-for="p in filteredProducts"
          :key="p.id"
          :product="p"
        />
      </template>

      <!-- Каталог загружается -->
      <div
        v-if="!state.ready && !loadTimedOut"
        class="flex flex-col items-center justify-center gap-2 py-16 text-slate-400 dark:text-slate-500"
      >
        <Loader2 class="w-6 h-6 animate-spin text-brand-500" />
        <span class="text-xs">Загрузка каталога продуктов…</span>
      </div>

      <!-- Страховочный таймаут: данные не пришли -->
      <div
        v-else-if="!state.ready && loadTimedOut"
        class="flex flex-col items-center justify-center gap-1.5 py-16 text-slate-400 dark:text-slate-500"
      >
        <Hourglass :size="28" />
        <span class="text-sm font-semibold text-slate-500 dark:text-slate-300">Загрузка каталога заняла больше времени, чем обычно</span>
        <span class="text-xs text-center max-w-sm">Возможно, проверяются обновления через интернет или сеть недоступна.</span>
        <button class="es-btn-primary mt-2" @click="onRefresh">
          <RotateCw :size="14" />
          Повторить загрузку
        </button>
      </div>

      <!-- Ничего не найдено -->
      <div
        v-else-if="state.ready && !filteredProducts.length"
        class="flex flex-col items-center justify-center gap-1.5 py-16 text-slate-400 dark:text-slate-500"
      >
        <SearchX :size="28" />
        <span class="text-sm font-semibold text-slate-500 dark:text-slate-300">Ничего не найдено</span>
        <span class="text-xs">Попробуйте изменить поисковый запрос или фильтр</span>
      </div>
    </main>

    <!-- Подвал: состояние моста -->
    <footer
      class="px-3.5 py-1.5 bg-white/70 dark:bg-slate-900/70 border-t border-slate-200/70 dark:border-slate-800/70
             flex items-center justify-between text-[10px] text-slate-400 dark:text-slate-500 shrink-0"
    >
      <div class="flex items-center gap-1">
        <span class="w-1.5 h-1.5 rounded-full" :class="state.ready ? 'bg-emerald-400' : 'bg-slate-300'"></span>
        <span>Управление расширениями SketchUp из GitHub Releases</span>
      </div>
      <div class="flex items-center gap-3 tabular-nums">
        <span v-if="syncText" :title="Array.isArray(state.sync.failed) && state.sync.failed.length ? 'Не ответили: ' + state.sync.failed.join(', ') : 'Все репозитории ответили'">{{ syncText }}</span>
        <span>всего: {{ counts.all }}</span>
        <span>установлено: {{ counts.installed }}</span>
        <span>обновлений: {{ counts.updates }}</span>
      </div>
    </footer>

    <!-- Тост -->
    <transition name="toast">
      <div
        v-if="state.toast"
        class="fixed bottom-10 left-1/2 -translate-x-1/2 px-3.5 py-2 rounded-lg shadow-lg text-xs font-medium flex items-center gap-2 z-50"
        :class="state.toast.kind === 'ok'
          ? 'bg-emerald-500 text-white'
          : state.toast.kind === 'err'
            ? 'bg-red-500 text-white'
            : 'bg-slate-700 text-white'"
      >
        <CheckCircle2 v-if="state.toast.kind === 'ok'" class="w-3.5 h-3.5" />
        <AlertCircle v-else-if="state.toast.kind === 'err'" class="w-3.5 h-3.5" />
        <Info v-else class="w-3.5 h-3.5" />
        <span class="max-w-[420px] whitespace-pre-line">{{ state.toast.text }}</span>
      </div>
    </transition>
  </div>
</template>

<script setup>
import { computed, onMounted, ref, watch } from 'vue'
import { Search, SearchX, Loader2, Hourglass, RotateCw, CheckCircle2, AlertCircle, Info, Download, Trash2 } from 'lucide-vue-next'
import Header from './components/Header.vue'
import ProductCard from './components/ProductCard.vue'
import ProductRow from './components/ProductRow.vue'
import { state, refresh, loadState, toast, installAll, confirmUninstallAll, confirmRestart } from './composables/useSketchupBridge'
import { useTheme } from './composables/useTheme'

useTheme()

// -- вид каталога (карточки / список) --------------------------------------------

const view = ref('cards')

try {
  const savedView = localStorage.getItem('dn1sup_view')
  if (savedView === 'list' || savedView === 'cards') view.value = savedView
} catch {
  // ignore
}

watch(view, (v) => {
  try {
    localStorage.setItem('dn1sup_view', v)
  } catch {
    // ignore
  }
})

// -- загрузка -------------------------------------------------------------------
// Страховка: если данные не поступили за 3.5 сек — показываем «Повторить».

const loadTimedOut = ref(false)
watch(() => state.ready, (ready) => {
  if (ready) loadTimedOut.value = false
})
let timeoutTimer = null
function armLoadTimeout() {
  clearTimeout(timeoutTimer)
  loadTimedOut.value = false
  timeoutTimer = setTimeout(() => {
    if (!state.ready) loadTimedOut.value = true
  }, 3500)
}

const refreshing = ref(false)
const syncFetching = computed(() => !!(state.sync && state.sync.fetching))
const headerRefreshing = computed(() => refreshing.value || syncFetching.value)
// Watchdog: зависший sync.fetching (Ruby не пушит из-за мёртвой сети)
// не должен крутиться молча — через 60с подсказываем проверить интернет.
// Кнопка при этом остаётся кликабельной (повтор коалесцируется в Ruby).
let stuckTimer = null
const stuckNotified = ref(false)
watch(syncFetching, (fetching) => {
  clearTimeout(stuckTimer)
  if (fetching) {
    stuckNotified.value = false
    stuckTimer = setTimeout(() => {
      if (state.sync && state.sync.fetching && !stuckNotified.value) {
        stuckNotified.value = true
        toast('info', 'Проверка длится дольше обычного — возможно, нет сети или GitHub недоступен. Повторите позже.', 7000)
      }
    }, 60000)
  }
})
const isFirstScan = computed(() => !!(state.sync && state.sync.first_scan && state.sync.fetching))
const firstScanPercent = computed(() => {
  const s = state.sync || {}
  if (!s.total || s.total <= 0) return 15
  return Math.min(100, Math.round((Number(s.fetched) || 0) / s.total * 100))
})
const firstScanText = computed(() => {
  const s = state.sync || {}
  if (s.total > 0) return `проверено ${s.fetched || 0}/${s.total}`
  return 'подключаемся к GitHub…'
})
const headerProgressTitle = computed(() => {
  const s = state.sync || {}
  if (!s.fetching) return ''
  if (s.total > 0) return s.first_scan ? `Сканирование… ${s.fetched || 0}/${s.total}` : `Проверка… ${s.fetched || 0}/${s.total}`
  return s.first_scan ? 'Сканирование…' : 'Проверка…'
})

const syncText = computed(() => {
  const s = state.sync || {}
  if (s.fetching) {
    if (s.total > 0) return `проверка обновлений… ${s.fetched}/${s.total}`
    return 'проверка обновлений…'
  }
  if (s.checked_at > 0 && s.total > 0) {
    const failed = Array.isArray(s.failed) ? s.failed.length : 0
    const base = `проверено ${s.fetched}/${s.total}`
    return failed > 0 ? `${base} · недоступны: ${failed}` : base
  }
  if (s.snapshot_saved_at > 0) return 'показаны сохранённые данные'
  return ''
})

function onRefresh() {
  armLoadTimeout()
  refreshing.value = true
  refresh()
  setTimeout(() => { refreshing.value = false }, 1200)
}

function onRestart() {
  confirmRestart()
}

// -- фильтры и поиск -------------------------------------------------------------

const filter = ref('all')
const searchQuery = ref('')

const counts = computed(() => ({
  all: state.products.length,
  installed: state.products.filter(p => p.is_installed).length,
  updates: state.products.filter(p => p.has_update || p.status === 'switch').length
}))

const bulkBusy = computed(() => !!(state.busy && state.busy.id === '__bulk__'))
const bulkPercent = computed(() => {
  const b = state.bulk
  if (!b || !b.total || b.total <= 0) return 0
  return Math.min(100, Math.round((Number(b.current) || 0) / b.total * 100))
})
const bulkTitle = computed(() => {
  const b = state.bulk
  if (!b) return ''
  const verb = b.action === 'uninstall_all' ? 'Удаление' : 'Установка'
  const fails = (b.failed || []).length
  const failSuffix = fails > 0 ? ` · ошибок: ${fails}` : ''
  if (bulkBusy.value) return `${verb}… ${b.current || 0}/${b.total || 0}${failSuffix}`
  const doneWord = b.action === 'uninstall_all' ? 'Удалено' : 'Установлено'
  return `${doneWord}: ${(b.done || []).length} из ${b.total || 0}${failSuffix}`
})
const installCandidates = computed(() => state.products.filter(p => !p.is_installed || p.has_update || p.status === 'switch'))
const uninstallCandidates = computed(() => state.products.filter(p => p.is_installed && p.id !== 'dn1sup_ext_manager'))

function onInstallAll() {
  if (!installCandidates.value.length || bulkBusy.value) return
  installAll(installCandidates.value.map(p => p.id))
}

function onUninstallAll() {
  if (!uninstallCandidates.value.length || bulkBusy.value) return
  confirmUninstallAll(uninstallCandidates.value.map(p => p.id))
}

const filteredProducts = computed(() => {
  const q = searchQuery.value.trim().toLowerCase()
  return state.products.filter(p => {
    if (filter.value === 'installed' && !p.is_installed) return false
    if (filter.value === 'updates' && !(p.has_update || p.status === 'switch')) return false
    if (q) {
      const matchName = (p.name || '').toLowerCase().includes(q)
      const matchId = (p.id || '').toLowerCase().includes(q)
      const matchDesc = (p.description || '').toLowerCase().includes(q)
      if (!matchName && !matchId && !matchDesc) return false
    }
    return true
  })
})

onMounted(() => {
  armLoadTimeout()
  loadState()
})
</script>

<style>
.toast-enter-active,
.toast-leave-active {
  transition: opacity 0.2s ease, transform 0.2s ease;
}
.toast-enter-from,
.toast-leave-to {
  opacity: 0;
  transform: translate(-50%, 8px);
}
</style>
