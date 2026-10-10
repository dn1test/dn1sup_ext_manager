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
  products: [],  // [{id,name,description,author,repo,asset,discovered,installed_version,is_installed,latest_version,has_update,status,changelog,commits,release_url,published_at}]
  busy: null,    // { id, action, text } — длительная операция над карточкой
  toast: null    // { kind: 'ok' | 'err' | 'info', text }
})

let toastTimer = null
function toast(kind, text, ms = 4500) {
  state.toast = { kind, text }
  if (toastTimer) clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { state.toast = null }, ms)
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
    clearBusy(payload.id)
    if (payload.ok) {
      toast('ok', payload.message || 'Операция успешно завершена!')
    } else {
      toast('err', payload.error || 'Произошла ошибка при выполнении операции.', 7000)
    }
    return
  }
  if (kind === 'confirm_uninstall') {
    if (payload.ok) {
      state.busy = { id: payload.id, action: 'uninstall', text: 'Удаление…' }
      callRubyJson('uninstall', { id: payload.id })
    } else {
      clearBusy(payload.id)
    }
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

export { state, isMock, toast, clearBusy }
