import { reactive } from 'vue'
import { applyMockAction, mockPayload } from '../mocks'

/**
 * Мост Ruby ↔ JS (единый паттерн с dn1sup_create_project / dn1sup_save_settings):
 *  — JS → Ruby: sketchup.call_ruby(name, param) — один экшен-колбэк 'call_ruby';
 *  — Ruby → JS: window.pushState(state) и window.pushResult(kind, payload).
 *
 * Вне SketchUp (npm run dev в браузере) включается mock-режим.
 */

function getSketchup() {
  if (typeof sketchup !== 'undefined' && sketchup && typeof sketchup.call_ruby === 'function') {
    return sketchup
  }
  if (typeof window !== 'undefined' && window.sketchup && typeof window.sketchup.call_ruby === 'function') {
    return window.sketchup
  }
  return null
}

const isMock = !getSketchup()

// -- общее состояние UI -------------------------------------------------------

const state = reactive({
  ready: false,
  version: '…',
  products: [],  // [{id,name,description,author,repo,asset,discovered,installed_version,is_installed,latest_version,has_update,has_asset,status,dev_available,dev_version,changelog,commits,release_url,published_at}]
  sync: { fetching: false, fetched: 0, total: 0, failed: [], checked_at: 0, snapshot_saved_at: 0, first_scan: false },
  busy: null,    // { id, action, text } — длительная операция над карточкой
  toast: null,   // { kind: 'ok' | 'err' | 'info', text }
  bulk: null     // { action, current, total, done: [{id,name}], failed: [{id,name}] } — прогресс «установить/удалить все»
})

let toastTimer = null
function toast(kind, text, ms = 4500) {
  state.toast = { kind, text }
  if (toastTimer) clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { state.toast = null }, ms)
}

let bulkTimer = null
function resetBulk(action, total) {
  if (bulkTimer) clearTimeout(bulkTimer)
  state.bulk = { action, current: 0, total: Number(total) || 0, done: [], failed: [] }
}
function clearBulkDelayed(ms = 12000) {
  if (bulkTimer) clearTimeout(bulkTimer)
  bulkTimer = setTimeout(() => { state.bulk = null }, ms)
}

function clearBusy(id) {
  if (state.busy && (!id || state.busy.id === id)) state.busy = null
}

// -- обработчики пушей Ruby (регистрируются до монтирования Vue) --------------

if (typeof window !== 'undefined') {
  window.pushState = function (payload) {
    if (!payload) return
    state.ready = true
    state.version = payload.version || '—'
    state.products = payload.products || []
    if (payload.sync && typeof payload.sync === 'object') {
      state.sync = {
        fetching: !!payload.sync.fetching,
        fetched: Number(payload.sync.fetched) || 0,
        total: Number(payload.sync.total) || 0,
        failed: Array.isArray(payload.sync.failed) ? payload.sync.failed : [],
        checked_at: Number(payload.sync.checked_at) || 0,
        snapshot_saved_at: Number(payload.sync.snapshot_saved_at) || 0,
        first_scan: !!payload.sync.first_scan
      }
    }
    clearBusy(null)
  }
  window.pushResult = function (kind, payload) {
    emitResult(kind, payload || {})
  }
}

function emitResult(kind, payload) {
  if (kind === 'error') {
    clearBusy(null)
    toast('err', payload.message || 'Ошибка Ruby', 7000)
    return
  }
  if (kind === 'action_result') {
    if (payload.id === '__bulk__') {
      clearBusy('__bulk__')
      // Итоговая сводка уже отражена в state.bulk из bulk_progress;
      // тост + автоскрытие панели через 12с.
      if (payload.ok) {
        toast('ok', payload.message || 'Операция успешно завершена!')
      } else {
        toast('err', payload.error || 'Произошла ошибка при выполнении операции.', 7000)
      }
      clearBulkDelayed()
    } else {
      clearBusy(payload.id)
      if (payload.ok) {
        toast('ok', payload.message || 'Операция успешно завершена!')
      } else {
        toast('err', payload.error || 'Произошла ошибка при выполнении операции.', 7000)
      }
    }
    return
  }
  if (kind === 'bulk_progress') {
    const b = state.bulk
    if (b && (payload.action === b.action || !b.action)) {
      b.current = Number(payload.current) || b.current
      b.total = Number(payload.total) || b.total
      const entry = { id: String(payload.id || ''), name: String(payload.name || payload.id || '') }
      if (payload.ok) b.done.push(entry)
      else b.failed.push(entry)
    } else {
      state.bulk = {
        action: String(payload.action || ''),
        current: Number(payload.current) || 0,
        total: Number(payload.total) || 0,
        done: payload.ok ? [{ id: String(payload.id || ''), name: String(payload.name || payload.id || '') }] : [],
        failed: payload.ok ? [] : [{ id: String(payload.id || ''), name: String(payload.name || payload.id || '') }]
      }
    }
    return
  }
  if (kind === 'check_summary') {
    // Сводка кнопки «Проверить обновления» / первого сканирования.
    if (payload.message) {
      toast(payload.updates && Number(payload.updates) > 0 ? 'info' : 'ok', payload.message, 7000)
    }
    return
  }
  if (kind === 'confirm_uninstall') {
    if (payload.ok) {
      state.busy = { id: payload.id, action: 'uninstall', text: 'Удаление…' }
      if (isMock) applyMockAction('uninstall', { id: payload.id })
      else callRubyJson('uninstall', { id: payload.id })
    } else {
      clearBusy(payload.id)
    }
    return
  }
  if (kind === 'confirm_uninstall_all') {
    if (payload.ok) {
      const ids = Array.isArray(payload.ids) ? payload.ids : []
      state.busy = { id: '__bulk__', action: 'uninstall_all', text: 'Удаление…' }
      if (isMock) applyMockAction('uninstall_all', { ids })
      else callRubyJson('uninstall_all', { ids })
    } else {
      clearBusy('__bulk__')
      clearBusy(null)
    }
    return
  }
}

// -- вызовы Ruby ---------------------------------------------------------------

function callRuby(name, param) {
  const bridge = getSketchup()
  if (bridge) {
    try {
      bridge.call_ruby(name, param === undefined ? '' : String(param))
      return true
    } catch (e) {
      console.warn('callRuby error:', e)
    }
  }
  return false
}

function callRubyJson(name, obj) {
  return callRuby(name, JSON.stringify(obj))
}

/** Загрузка каталога: мгновенный локальный сбор + фоновая проверка релизов в Ruby. */
export function loadState() {
  if (isMock) {
    setTimeout(() => window.pushState(mockPayload()), 150)
    return
  }
  callRuby('ready')
  // Повторный сигнал на случай, если мост SketchUp CEF инициализировался чуть позже
  setTimeout(() => {
    if (!state.ready) callRuby('ready')
  }, 350)
}

/** Принудительная проверка обновлений всех расширений (свежий запрос к GitHub). */
export function refresh() {
  if (isMock) {
    applyMockAction('refresh')
    return
  }
  callRuby('refresh')
}

/** Установка / переустановка расширения. */
export function install(id, text = 'Установка…') {
  if (isMock) {
    state.busy = { id, action: 'install', text }
    applyMockAction('install', { id })
    return
  }
  state.busy = { id, action: 'install', text }
  callRubyJson('install', { id })
}

/** Обновление расширения. */
export function update(id) {
  if (isMock) {
    state.busy = { id, action: 'update', text: 'Обновление…' }
    applyMockAction('update', { id })
    return
  }
  state.busy = { id, action: 'update', text: 'Обновление…' }
  callRubyJson('update', { id })
}

/** Проверка обновления: сначала локальная папка разработки, потом GitHub. */
export function checkUpdate(id) {
  if (isMock) {
    state.busy = { id, action: 'check_update', text: 'Проверка…' }
    applyMockAction('check_update', { id })
    return
  }
  state.busy = { id, action: 'check_update', text: 'Проверка…' }
  callRubyJson('check_update', { id })
}

/** Подтверждение удаления — через нативный диалог SketchUp (window.confirm
 *  в HtmlDialog на части сборок подавлен). */
export function confirmUninstall(id) {
  if (isMock) {
    state.busy = { id, action: 'uninstall', text: 'Ожидание подтверждения…' }
    applyMockAction('confirm_uninstall', { id })
    return
  }
  state.busy = { id, action: 'uninstall', text: 'Ожидание подтверждения…' }
  callRubyJson('confirm_uninstall', { id })
}

/** Скрыть найденное на GitHub расширение (не входит в registry.json). */
export function hide(repo) {
  if (isMock) {
    state.products = state.products.filter(p => p.repo !== repo)
    return
  }
  callRubyJson('hide', { repo })
}

/** Массовая установка/обновление: неустановленные + обновления. */
export function installAll(ids) {
  const list = Array.isArray(ids) ? ids : []
  resetBulk('install_all', list.length)
  if (isMock) {
    state.busy = { id: '__bulk__', action: 'install_all', text: 'Установка…' }
    applyMockAction('install_all', { ids: list })
    return
  }
  state.busy = { id: '__bulk__', action: 'install_all', text: 'Установка…' }
  callRubyJson('install_all', { ids: list })
}

/** Подтверждение массового удаления через нативный диалог SketchUp. */
export function confirmUninstallAll(ids) {
  const list = Array.isArray(ids) ? ids : []
  resetBulk('uninstall_all', list.length)
  if (isMock) {
    state.busy = { id: '__bulk__', action: 'uninstall_all', text: 'Ожидание подтверждения…' }
    applyMockAction('confirm_uninstall_all', { ids: list })
    return
  }
  state.busy = { id: '__bulk__', action: 'uninstall_all', text: 'Ожидание подтверждения…' }
  callRubyJson('confirm_uninstall_all', { ids: list })
}

export { state, isMock, toast, clearBusy }
