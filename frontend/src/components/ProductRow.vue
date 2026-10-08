<template>
  <article
    class="es-card es-row relative overflow-hidden"
    :class="{ 'es-card-update': p.has_update }"
  >
    <div class="flex items-center gap-2 px-3 py-1.5">
      <Puzzle :size="14" class="text-slate-400 dark:text-slate-500 shrink-0" :title="p.id" />

      <!-- Название + id -->
      <div class="flex items-center gap-2 min-w-0 flex-1" :title="p.description || p.id">
        <span class="text-xs font-semibold leading-tight truncate">{{ p.name }}</span>
        <span class="es-id-badge shrink-0">{{ p.id }}</span>
      </div>

      <!-- Статус + версия -->
      <div class="flex items-center gap-2 shrink-0">
        <span class="font-mono text-[11px] text-slate-400 dark:text-slate-500 whitespace-nowrap" :title="versionTitle">
          {{ versionText }}
        </span>
        <span
          class="inline-flex items-center gap-1 px-1.5 py-px rounded-full text-[11px] font-medium whitespace-nowrap"
          :class="statusCls"
        >
          <component :is="statusIcon" :size="11" />
          {{ statusText }}
        </span>
      </div>

      <!-- Действия -->
      <div class="flex items-center gap-1 shrink-0">
        <template v-if="isBusy">
          <span class="inline-flex items-center gap-1.5 px-2 h-[28px] text-xs font-medium text-slate-500 dark:text-slate-400">
            <Loader2 :size="13" class="animate-spin text-brand-500" />
            {{ busy.text }}
          </span>
        </template>
        <template v-else>
          <button
            v-if="p.has_update"
            class="es-btn-update !h-[28px] !px-2 !text-xs"
            :title="`Обновить расширение до ${p.latest_version}`"
            @click="update(p.id)"
          >
            <Zap :size="12" />
            Обновить
          </button>
          <button
            v-else-if="p.is_installed"
            class="es-btn-ghost !h-[28px] !px-2 !text-xs"
            title="Переустановить текущую версию"
            @click="install(p.id, 'Переустановка…')"
          >
            <RotateCw :size="12" />
            Переустановить
          </button>
          <button
            v-else
            class="es-btn-primary !h-[28px] !px-2 !text-xs"
            title="Скачать и установить в SketchUp"
            @click="install(p.id)"
          >
            <Download :size="12" />
            Установить
          </button>

          <button
            v-if="p.is_installed"
            class="p-1 rounded-lg h-[28px] w-[28px] flex items-center justify-center
                   text-slate-400 hover:text-red-500 hover:bg-red-50 dark:hover:bg-red-950/40 transition-colors"
            title="Удалить расширение"
            @click="confirmUninstall(p.id)"
          >
            <Trash2 :size="13" />
          </button>
        </template>
      </div>
    </div>
  </article>
</template>

<script setup>
import { computed } from 'vue'
import { Puzzle, Loader2, Zap, RotateCw, Download, Trash2, CircleCheck, Circle } from 'lucide-vue-next'
import { state, install, update, confirmUninstall } from '../composables/useSketchupBridge'
import { useProductStatus } from '../composables/useProductStatus'

const props = defineProps({ product: { type: Object, required: true } })
const p = computed(() => props.product)

const { statusText, statusCls, versionText, versionTitle } = useProductStatus(p)

const isBusy = computed(() => state.busy?.id === p.value.id)
const busy = computed(() => (isBusy.value ? state.busy : null))
</script>
