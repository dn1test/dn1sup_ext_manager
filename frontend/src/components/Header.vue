<template>
  <header
    class="px-3.5 pt-2.5 pb-2 flex flex-col gap-2 border-b border-slate-200/70 dark:border-slate-800/70 bg-white/70 dark:bg-slate-900/70 shrink-0"
  >
    <div class="flex items-center justify-between gap-2">
    <div class="flex items-center gap-2 min-w-0">
      <div class="w-8 h-8 rounded-lg bg-white flex items-center justify-center shrink-0 border border-slate-200/70">
        <svg viewBox="0 0 24 24" class="w-5 h-5" aria-hidden="true">
          <rect x="6.4" y="5.4" width="5.6" height="6.6" fill="#36abf7" stroke="#015995" stroke-width="1"/>
          <path d="M6.4 7.6h5.6" stroke="#015995" stroke-width="1"/>
          <rect x="12" y="3.8" width="5.6" height="8.2" fill="#7cc7fb" stroke="#015995" stroke-width="1"/>
          <path d="M12 6h5.6" stroke="#015995" stroke-width="1"/>
          <path d="M3 11.5h18l-2 9H5z" fill="#0c8ee9" stroke="#015995" stroke-width="1.2" stroke-linejoin="round"/>
          <path d="M12 13.5v4M10.2 15.7l1.8 1.8 1.8-1.8" stroke="#ffffff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
        </svg>
      </div>
      <div class="min-w-0">
        <div class="flex items-center gap-2">
          <h1 class="text-sm font-semibold leading-tight truncate">DN1Sup Extension Store</h1>
          <span
            class="px-1.5 py-0.5 rounded bg-slate-200/70 dark:bg-slate-800 text-[10px] font-mono text-slate-500 dark:text-slate-400"
          >v{{ version }}</span>
        </div>
        <p class="text-[10px] text-slate-400 dark:text-slate-500 leading-tight">
          каталог, установка и обновление расширений
        </p>
      </div>
    </div>

    <div class="flex items-center gap-1 shrink-0">
      <button
        class="p-1.5 rounded-lg text-slate-400 hover:text-brand-500 hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors"
        :title="view === 'cards' ? 'Переключить на список' : 'Переключить на карточки'"
        @click="$emit('update:view', view === 'cards' ? 'list' : 'cards')"
      >
        <Rows3 v-if="view === 'cards'" class="w-4 h-4" />
        <LayoutGrid v-else class="w-4 h-4" />
      </button>
      <button
        class="p-1.5 rounded-lg text-slate-400 hover:text-brand-500 hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors"
        :title="progressTitle || 'Проверить обновления всех расширений'"
        @click="$emit('refresh')"
      >
        <RotateCw class="w-4 h-4" :class="{ 'animate-spin': refreshing }" />
      </button>
      <button
        class="p-1.5 rounded-lg text-slate-400 hover:text-brand-500 hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors"
        title="Перезапустить SketchUp с тем же файлом"
        @click="$emit('restart')"
      >
        <Power class="w-4 h-4" />
      </button>
      <button
        class="p-1.5 rounded-lg text-slate-400 hover:text-brand-500 hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors"
        :title="isDark ? 'Светлая тема' : 'Тёмная тема'"
        @click="toggleTheme"
      >
        <Sun v-if="isDark" class="w-4 h-4" />
        <Moon v-else class="w-4 h-4" />
      </button>
    </div>
    </div>

    <nav class="flex gap-0.5 bg-slate-200/60 dark:bg-slate-900 rounded-lg p-0.5">
      <button
        v-for="tab in tabs"
        :key="tab.id"
        class="flex-1 flex items-center justify-center gap-1.5 px-2 py-1 rounded-md text-xs font-medium transition-colors whitespace-nowrap"
        :class="filter === tab.id
          ? 'bg-white dark:bg-slate-700 text-brand-600 dark:text-brand-400 shadow-sm'
          : 'text-slate-500 dark:text-slate-400 hover:text-slate-700 dark:hover:text-slate-200'"
        @click="$emit('update:filter', tab.id)"
      >
        <span>{{ tab.label }}</span>
        <span
          class="px-1.5 py-px rounded-full text-[10px] font-semibold tabular-nums"
          :class="filter === tab.id
            ? 'bg-brand-100 dark:bg-brand-900/60 text-brand-700 dark:text-brand-300'
            : 'bg-slate-100 dark:bg-slate-800 text-slate-500 dark:text-slate-400'"
        >{{ tab.count }}</span>
      </button>
    </nav>
  </header>
</template>

<script setup>
import { computed } from 'vue'
import { RotateCw, Sun, Moon, Rows3, LayoutGrid, Power } from 'lucide-vue-next'
import { useTheme } from '../composables/useTheme'

const props = defineProps({
  version: { type: String, default: '—' },
  refreshing: { type: Boolean, default: false },
  view: { type: String, default: 'cards' },
  progressTitle: { type: String, default: '' },
  filter: { type: String, default: 'all' },
  counts: { type: Object, default: () => ({ all: 0, installed: 0, updates: 0 }) }
})
defineEmits(['refresh', 'restart', 'update:view', 'update:filter'])

const { isDark, toggleTheme } = useTheme()

const tabs = computed(() => [
  { id: 'all', label: 'Все', count: props.counts.all ?? 0 },
  { id: 'installed', label: 'Установленные', count: props.counts.installed ?? 0 },
  { id: 'updates', label: 'Обновления', count: props.counts.updates ?? 0 }
])
</script>
