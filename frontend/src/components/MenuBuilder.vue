<template>
  <div class="flex-1 min-h-0 flex flex-col gap-2 px-3.5 pb-3">
    <div class="rounded-lg border border-amber-200 dark:border-amber-900/60 bg-amber-50 dark:bg-amber-950/40 px-2.5 py-2 text-[11px] leading-snug text-amber-800 dark:text-amber-200 shrink-0">
      Свои подменю внутри <b>DN1Sup</b> из команд установленных плагинов. Источник команд — кнопки общей панели.
      Применятся <b>после перезапуска SketchUp</b> (пункты меню удалить в рантайме API не позволяет).
    </div>

    <div class="flex items-center gap-2 shrink-0">
      <input
        v-model="newTitle"
        type="text"
        maxlength="64"
        placeholder="Название нового меню…"
        class="es-input !pl-2.5 flex-1 min-w-0"
        @keyup.enter="addMenu"
      >
      <button class="es-btn-primary !px-2.5" :disabled="!newTitle.trim() || menus.length >= 10" @click="addMenu">
        <Plus :size="14" />
        <span>Меню</span>
      </button>
    </div>

    <div v-if="!menus.length" class="flex flex-col items-center gap-1 py-8 text-slate-400 dark:text-slate-500">
      <UtensilsCrossed :size="24" />
      <span class="text-xs font-medium">Пока нет своих меню — создайте первое</span>
    </div>

    <div v-else class="flex-1 min-h-0 overflow-y-auto space-y-2">
      <div
        v-for="(m, mi) in menus"
        :key="m.id"
        class="rounded-lg border bg-white dark:bg-slate-900"
        :class="mi === selected ? 'border-brand-400 dark:border-brand-600' : 'border-slate-200 dark:border-slate-800'"
      >
        <div class="flex items-center gap-1.5 px-2.5 py-2">
          <button class="flex-1 min-w-0 text-left text-xs font-semibold truncate" @click="selected = mi" :title="m.title">
            {{ m.title }}
            <span class="ml-1 font-normal text-slate-400">{{ (m.items || []).length }} п.</span>
          </button>
          <button class="p-1 rounded text-slate-400 hover:text-slate-600 dark:hover:text-slate-200" title="Вверх" :disabled="mi === 0" @click="moveMenu(mi, -1)">
            <ChevronUp :size="14" />
          </button>
          <button class="p-1 rounded text-slate-400 hover:text-slate-600 dark:hover:text-slate-200" title="Вниз" :disabled="mi === menus.length - 1" @click="moveMenu(mi, 1)">
            <ChevronDown :size="14" />
          </button>
          <button class="p-1 rounded text-slate-400 hover:text-red-500" title="Удалить меню" @click="removeMenu(mi)">
            <Trash2 :size="14" />
          </button>
        </div>

        <div v-if="mi === selected" class="px-2.5 pb-2.5 space-y-1.5 border-t border-slate-100 dark:border-slate-800 pt-2">
          <input
            v-model="m.title"
            type="text"
            maxlength="64"
            class="es-input !pl-2.5 !py-1 !text-xs"
            placeholder="Название меню"
          >
          <ul v-if="(m.items || []).length" class="space-y-1">
            <li
              v-for="(itemId, ii) in m.items"
              :key="ii"
              class="flex items-center gap-1.5 px-2 py-1 rounded-md text-xs"
              :class="isSep(itemId) ? 'bg-slate-100 dark:bg-slate-800 text-slate-400 justify-center' : 'bg-slate-50 dark:bg-slate-800/70'"
            >
              <template v-if="isSep(itemId)">
                <span class="tracking-widest">— — —</span>
              </template>
              <template v-else>
                <span class="flex-1 min-w-0 truncate" :title="cmdTooltip(itemId)">
                  {{ cmdTitle(itemId) }}
                  <span v-if="!isAvailable(itemId)" class="text-amber-600 dark:text-amber-400">(нет)</span>
                </span>
              </template>
              <button class="p-0.5 rounded text-slate-400 hover:text-slate-600" title="Вверх" :disabled="ii === 0" @click="moveItem(m, ii, -1)">▲</button>
              <button class="p-0.5 rounded text-slate-400 hover:text-slate-600" title="Вниз" :disabled="ii === m.items.length - 1" @click="moveItem(m, ii, 1)">▼</button>
              <button class="p-0.5 rounded text-slate-400 hover:text-red-500" title="Убрать" @click="removeItem(m, ii)">
                <X :size="13" />
              </button>
            </li>
          </ul>
          <div v-else class="text-[11px] text-slate-400">Пустое меню — добавьте команды справа.</div>

          <div class="flex items-center gap-1.5 pt-1">
            <select v-model="addPick[mi]" class="es-input !pl-2.5 !py-1 !text-xs flex-1 min-w-0">
              <option :value="''" disabled>Команда…</option>
              <option v-for="c in sortedCommands" :key="c.id" :value="c.id" :disabled="!c.available || (m.items || []).includes(c.id)">
                {{ c.title }}{{ c.available ? '' : ' (нет)' }}
              </option>
            </select>
            <button class="es-btn-primary !px-2 !py-1 !text-[11px]" :disabled="!addPick[mi] || (m.items || []).length >= 20" @click="addItem(m, mi)">
              Добавить
            </button>
            <button class="px-2 py-1 rounded-lg text-[11px] border border-slate-200 dark:border-slate-700 text-slate-500" :disabled="(m.items || []).length >= 20" @click="addSep(m)" title="Добавить разделитель">
              ───
            </button>
          </div>
        </div>
      </div>
    </div>

    <div class="flex items-center gap-2 shrink-0 pt-1">
      <button class="es-btn-primary flex-1" :disabled="!dirty || saving" @click="save">
        <Save :size="14" />
        Сохранить меню
      </button>
      <button class="px-2.5 py-1.5 rounded-lg text-xs border border-slate-200 dark:border-slate-700 text-slate-500" :disabled="saving" @click="reset">
        Сбросить
      </button>
    </div>
  </div>
</template>

<script setup>
import { computed, reactive, ref, watch } from 'vue'
import { ChevronDown, ChevronUp, Plus, Save, Trash2, UtensilsCrossed, X } from 'lucide-vue-next'
import { state, saveMenuConfig, resetMenuConfig } from '../composables/useSketchupBridge'

const SEP = '__sep__'
const menus = ref([])
const selected = ref(0)
const newTitle = ref('')
const addPick = reactive({})
const saving = ref(false)

function cloneMenus(src) {
  return JSON.parse(JSON.stringify(Array.isArray(src) ? src : []))
    .map((m, i) => ({
      id: String(m && m.id ? m.id : `menu_${Date.now()}_${i}`),
      title: String(m && m.title ? m.title : ''),
      items: Array.isArray(m && m.items) ? m.items.map(String) : []
    }))
}

watch(() => state.menu.menus, (v) => {
  // Не затираем черновик во время редактирования — только первая загрузка.
  if (!menus.value.length && Array.isArray(v) && v.length) {
    menus.value = cloneMenus(v)
  }
}, { immediate: true })

const commands = computed(() => (state.menu && Array.isArray(state.menu.commands) ? state.menu.commands : []))
const sortedCommands = computed(() => [...commands.value].sort((a, b) => String(a.title).localeCompare(String(b.title), 'ru')))

const dirty = computed(() => JSON.stringify(menus.value) !== JSON.stringify(state.menu.menus || []))

function cmdOf(id) {
  return commands.value.find(c => c.id === id)
}
function cmdTitle(id) {
  return cmdOf(id)?.title || id
}
function cmdTooltip(id) {
  return cmdOf(id)?.tooltip || id
}
function isAvailable(id) {
  const c = cmdOf(id)
  return !c || c.available !== false
}
function isSep(id) {
  return id === SEP
}

function addMenu() {
  const title = newTitle.value.trim().slice(0, 64)
  if (!title || menus.value.length >= 10) return
  menus.value.push({ id: `menu_${Date.now()}`, title, items: [] })
  selected.value = menus.value.length - 1
  newTitle.value = ''
}

function removeMenu(mi) {
  menus.value.splice(mi, 1)
  selected.value = Math.max(0, Math.min(selected.value, menus.value.length - 1))
}

function moveMenu(mi, dir) {
  const j = mi + dir
  if (j < 0 || j >= menus.value.length) return
  const [m] = menus.value.splice(mi, 1)
  menus.value.splice(j, 0, m)
  selected.value = j
}

function addItem(m, mi) {
  const id = addPick[mi]
  if (!id || (m.items || []).length >= 20 || (m.items || []).includes(id)) return
  m.items.push(id)
  addPick[mi] = ''
}

function addSep(m) {
  if ((m.items || []).length >= 20) return
  m.items.push(SEP)
}

function removeItem(m, ii) {
  m.items.splice(ii, 1)
}

function moveItem(m, ii, dir) {
  const j = ii + dir
  if (j < 0 || j >= m.items.length) return
  const [x] = m.items.splice(ii, 1)
  m.items.splice(j, 0, x)
}

function save() {
  saving.value = true
  try {
    saveMenuConfig(menus.value)
  } finally {
    setTimeout(() => { saving.value = false }, 800)
  }
}

function reset() {
  menus.value = []
  selected.value = 0
  resetMenuConfig()
}
</script>
