<template>
  <article class="es-card relative overflow-hidden" :class="{ 'es-card-update': p.has_update || p.status === 'switch' }">
    <div class="flex items-center gap-3 px-3 py-2.5">
      <!-- Иконка -->
      <div
        class="w-9 h-9 rounded-lg bg-slate-100 dark:bg-slate-950/60 border border-slate-200 dark:border-slate-700/60
               flex items-center justify-center shrink-0"
        :title="p.id"
      >
        <Puzzle :size="18" class="text-slate-400 dark:text-slate-500" />
      </div>

      <!-- Информация -->
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 flex-wrap mb-0.5">
          <span class="text-sm font-semibold leading-tight">{{ p.name }}</span>
          <span class="es-id-badge">{{ p.id }}</span>
          <span
            v-if="p.discovered"
            class="inline-flex items-center gap-1 px-1.5 py-px rounded-full text-[11px] font-medium whitespace-nowrap
                   bg-violet-100 dark:bg-violet-900/40 text-violet-700 dark:text-violet-300"
            title="Расширение найдено автоматически на GitHub — его нет в основном реестре каталога"
          >
            <Sparkles :size="11" />
            Найдено
          </span>
          <span
            class="inline-flex items-center gap-1 px-1.5 py-px rounded-full text-[11px] font-medium whitespace-nowrap"
            :class="statusCls"
          >
            <component :is="statusIcon" :size="11" />
            {{ statusText }}
          </span>
        </div>

        <p class="text-xs text-slate-500 dark:text-slate-400 leading-tight truncate mb-1" :title="p.description">
          {{ p.description || '—' }}
        </p>

        <div class="flex items-center gap-2.5 text-[11px] text-slate-400 dark:text-slate-500 mb-1">
          <span v-if="p.author" class="inline-flex items-center gap-1" :title="`Автор: ${p.author}`">
            <User :size="11" />
            {{ p.author }}
          </span>
          <span class="font-mono" :title="versionTitle">
            {{ versionText }}
          </span>
        </div>

        <button
          v-if="latestNote || commitList.length"
          class="w-full flex items-center gap-1 text-left text-[11px] leading-tight
                 text-slate-500 dark:text-slate-400 hover:text-brand-600 dark:hover:text-brand-400 transition-colors"
          :title="changelogText"
          @click="changelogOpen = !changelogOpen"
        >
          <span class="shrink-0 font-medium">Что нового:</span>
          <span class="truncate flex-1">{{ latestNote || `Изменения: ${commitList.length}` }}</span>
          <ChevronDown :size="11" class="shrink-0 transition-transform" :class="{ 'rotate-180': changelogOpen }" />
        </button>
      </div>

      <!-- Действия -->
      <div class="flex items-center gap-1.5 shrink-0">
        <template v-if="isBusy">
          <span class="inline-flex items-center gap-1.5 px-3 h-[30px] text-xs font-medium text-slate-500 dark:text-slate-400">
            <Loader2 :size="14" class="animate-spin text-brand-500" />
            {{ busy.text }}
          </span>
        </template>
        <template v-else>
          <button
            v-if="p.has_update"
            class="es-btn-update !h-[30px] !px-2.5 !text-xs"
            :title="`Обновить расширение до ${p.latest_version}`"
            @click="update(p.id)"
          >
            <Zap :size="13" />
            Обновить
          </button>
          <button
            v-else-if="p.status === 'switch'"
            class="es-btn-update !h-[30px] !px-2.5 !text-xs"
            :title="`Установить v${p.latest_version}: релиз новее по дате, но ниже по номеру (смена схемы нумерации)`"
            @click="update(p.id)"
          >
            <ArrowLeftRight :size="13" />
            Установить
          </button>
          <button
            v-else-if="p.is_installed && !p.repo_status"
            class="es-btn-ghost !h-[30px] !px-2.5 !text-xs"
            title="Переустановить текущую версию"
            @click="install(p.id, 'Переустановка…')"
          >
            <RotateCw :size="13" />
            Переустановить
          </button>
          <button
            v-else
            class="es-btn-primary !h-[30px] !px-2.5 !text-xs"
            title="Скачать и установить в SketchUp"
            @click="install(p.id)"
          >
            <Download :size="13" />
            Установить
          </button>

          <button
            v-if="p.is_installed"
            class="p-1.5 rounded-lg h-[30px] w-[30px] flex items-center justify-center
                   text-slate-400 hover:text-red-500 hover:bg-red-50 dark:hover:bg-red-950/40 transition-colors"
            title="Удалить расширение"
            @click="confirmUninstall(p.id)"
          >
            <Trash2 :size="14" />
          </button>

          <button
            v-if="p.discovered"
            class="p-1.5 rounded-lg h-[30px] w-[30px] flex items-center justify-center
                   text-slate-400 hover:text-slate-600 dark:hover:text-slate-200 hover:bg-slate-100 dark:hover:bg-slate-800 transition-colors"
            title="Скрыть это расширение из каталога (вернуть: меню DN1Sup → Extension Store → Показать скрытые расширения)"
            @click="hide(p.repo)"
          >
            <EyeOff :size="14" />
          </button>
        </template>
      </div>
    </div>

    <!-- Разворачиваемый лог изменений -->
    <transition
      enter-active-class="transition duration-150 ease-out"
      enter-from-class="opacity-0 -translate-y-1"
      leave-active-class="transition duration-100 ease-in"
      leave-to-class="opacity-0 -translate-y-1"
    >
      <div v-if="changelogOpen" class="px-3 pb-2.5 space-y-1.5">
        <div
          class="max-h-[120px] overflow-y-auto rounded-lg bg-slate-50 dark:bg-slate-950/75
                 border border-slate-200 dark:border-slate-800 px-3 py-2
                 text-[11px] text-slate-600 dark:text-slate-300 leading-relaxed whitespace-pre-line"
        >{{ changelogText }}</div>
        <div
          v-if="commitList.length"
          class="max-h-[120px] overflow-y-auto rounded-lg bg-slate-50 dark:bg-slate-950/75
                 border border-slate-200 dark:border-slate-800 px-3 py-2
                 text-[11px] text-slate-600 dark:text-slate-300 leading-relaxed"
        >
          <div class="font-semibold mb-1">Изменения ({{ commitList.length }}):</div>
          <ul class="list-disc list-inside space-y-0.5">
            <li v-for="(msg, i) in commitList" :key="i" class="truncate" :title="msg">{{ msg }}</li>
          </ul>
        </div>
      </div>
    </transition>
  </article>
</template>

<script setup>
import { computed, ref } from 'vue'
import {
  Puzzle, ChevronDown, Loader2, Zap, RotateCw, Download, Trash2, ArrowLeftRight, Sparkles, EyeOff, User
} from 'lucide-vue-next'
import { state, install, update, confirmUninstall, hide } from '../composables/useSketchupBridge'
import { useProductStatus } from '../composables/useProductStatus'

const props = defineProps({ product: { type: Object, required: true } })
const p = computed(() => props.product)

const CHANGELOG_FALLBACK = 'Лог изменений для этого расширения отсутствует.'

const changelogOpen = ref(false)

const changelogText = computed(() =>
  (p.value.changelog || '').trim() || CHANGELOG_FALLBACK
)

// Строка «Что нового» на карточке: первая строка последнего лога. Заглушка
// «лог отсутствует» (нет данных о релизах — оффлайн-старт) строку не показывает.
const latestNote = computed(() => {
  const raw = (p.value.changelog || '').trim()
  return raw && raw !== CHANGELOG_FALLBACK ? raw.split('\n')[0].trim() : ''
})

const commitList = computed(() => (Array.isArray(p.value.commits) ? p.value.commits : []))

const isBusy = computed(() => state.busy?.id === p.value.id)
const busy = computed(() => (isBusy.value ? state.busy : null))

const { statusText, statusCls, statusIcon, versionText, versionTitle } = useProductStatus(p)
</script>
