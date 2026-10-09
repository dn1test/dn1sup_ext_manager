<template>
  <div class="h-full flex flex-col bg-slate-50 dark:bg-slate-950 text-slate-800 dark:text-slate-100 transition-colors">
    <Header :version="state.version" :refreshing="refreshing" v-model:view="view" @refresh="onRefresh" />

    <!-- Поиск и фильтры -->
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

      <div class="flex gap-0.5 bg-slate-200/60 dark:bg-slate-900 rounded-lg p-0.5 shrink-0">
        <button
          v-for="tab in tabs"
          :key="tab.id"
          class="flex items-center gap-1.5 px-2.5 py-1.5 rounded-md text-xs font-medium transition-colors whitespace-nowrap"
          :class="filter === tab.id
            ? 'bg-white dark:bg-slate-700 text-brand-600 dark:text-brand-400 shadow-sm'
            : 'text-slate-500 dark:text-slate-400 hover:text-slate-700 dark:hover:text-slate-200'"
          @click="filter = tab.id"
        >
          <span>{{ tab.label }}</span>
          <span
            class="px-1.5 py-px rounded-full text-[10px] font-semibold tabular-nums"
            :class="filter === tab.id
              ? 'bg-brand-100 dark:bg-brand-900/60 text-brand-700 dark:text-brand-300'
              : 'bg-slate-100 dark:bg-slate-800 text-slate-500 dark:text-slate-400'"
          >{{ tab.count }}</span>
        </button>
      </div>
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
import { Search, SearchX, Loader2, Hourglass, RotateCw, CheckCircle2, AlertCircle, Info } from 'lucide-vue-next'
import Header from './components/Header.vue'
import ProductCard from './components/ProductCard.vue'
import ProductRow from './components/ProductRow.vue'
import { state, refresh, loadState } from './composables/useSketchupBridge'
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

function onRefresh() {
  armLoadTimeout()
  refreshing.value = true
  refresh()
  setTimeout(() => { refreshing.value = false }, 1200)
}

// -- фильтры и поиск -------------------------------------------------------------

const filter = ref('all')
const searchQuery = ref('')

const tabs = computed(() => [
  { id: 'all', label: 'Все', count: counts.value.all },
  { id: 'installed', label: 'Установленные', count: counts.value.installed },
  { id: 'updates', label: 'Обновления', count: counts.value.updates }
])

const counts = computed(() => ({
  all: state.products.length,
  installed: state.products.filter(p => p.is_installed).length,
  updates: state.products.filter(p => p.has_update || p.status === 'switch').length
}))

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
