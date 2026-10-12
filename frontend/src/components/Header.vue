<template>
  <header
    class="px-3.5 py-2.5 flex items-center justify-between border-b border-slate-200/70 dark:border-slate-800/70 bg-white/70 dark:bg-slate-900/70 shrink-0"
  >
    <div class="flex items-center gap-2 min-w-0">
      <div class="w-8 h-8 rounded-lg bg-brand-500 flex items-center justify-center shrink-0">
        <Package class="w-4 h-4 text-white" />
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

    <div class="flex items-center gap-1">
      <!-- Переключатель канала dev/prod: выгружает расширения чужого канала
           и загружает нужные без перезапуска SketchUp -->
      <div
        class="flex items-center rounded-lg p-0.5 mr-1 shrink-0"
        :class="switching ? 'opacity-50 pointer-events-none' : ''"
        title="Канал расширений: PROD — релизы из Store, DEV — рабочие копии из sketchup-dev-mcp. Переключение без перезапуска SketchUp."
      >
        <button
          class="px-2 py-1 rounded-md text-[10px] font-bold tracking-wide transition-colors"
          :class="channel !== 'dev'
            ? 'bg-slate-700 text-white dark:bg-slate-600'
            : 'text-slate-400 hover:text-slate-600 dark:hover:text-slate-300'"
          @click="$emit('set-channel', 'prod')"
        >PROD</button>
        <button
          class="px-2 py-1 rounded-md text-[10px] font-bold tracking-wide transition-colors"
          :class="channel === 'dev'
            ? 'bg-amber-500 text-white'
            : 'text-slate-400 hover:text-amber-600 dark:hover:text-amber-400'"
          @click="$emit('set-channel', 'dev')"
        >DEV</button>
      </div>
      <Loader2 v-if="switching" :size="14" class="animate-spin text-amber-500 shrink-0" />
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
        title="Проверить обновления всех расширений"
        @click="$emit('refresh')"
      >
        <RotateCw class="w-4 h-4" :class="{ 'animate-spin': refreshing }" />
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
  </header>
</template>

<script setup>
import { Package, RotateCw, Sun, Moon, Rows3, LayoutGrid, Loader2 } from 'lucide-vue-next'
import { useTheme } from '../composables/useTheme'

defineProps({
  version: { type: String, default: '—' },
  refreshing: { type: Boolean, default: false },
  view: { type: String, default: 'cards' },
  channel: { type: String, default: 'prod' },
  switching: { type: Boolean, default: false }
})
defineEmits(['refresh', 'update:view', 'set-channel'])

const { isDark, toggleTheme } = useTheme()
</script>
