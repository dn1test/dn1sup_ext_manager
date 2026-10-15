/**
 * Mock-режим для разработки интерфейса в браузере (npm run dev).
 * Имитирует ответы Ruby: pushState / pushResult.
 * Демо-данные нейтральные: реальные данные расширений берутся из registry.json
 * и GitHub Releases — здесь их дублировать нельзя.
 */

let mockProducts = [
  {
    id: 'demo_extension_one',
    name: 'Demo Extension One',
    description: 'Нейтральная демо-карточка для предпросмотра интерфейса в браузере.',
    author: 'DN1Sup Demo',
    repo: 'example/demo-extension-one',
    asset: 'demo_extension_one.rbz',
    installed_version: '1.0.0',
    is_installed: true,
    latest_version: '1.0.0',
    has_update: false,
    changelog: 'Демо-лог изменений: первая строка показывается на карточке.\nВторая строка видна только в раскрытом логе.',
    release_url: 'https://example.com/demo-extension-one/releases',
    published_at: ''
  },
  {
    id: 'demo_extension_two',
    name: 'Demo Extension Two',
    description: 'Нейтральная демо-карточка с доступным обновлением.',
    author: 'DN1Sup Demo',
    repo: 'example/demo-extension-two',
    asset: 'demo_extension_two.rbz',
    installed_version: '0.9.0',
    is_installed: true,
    latest_version: '1.0.0',
    has_update: true,
    status: 'update',
    changelog: 'Демо-лог изменений: первая строка показывается на карточке.\nВторая строка видна только в раскрытом логе.',
    release_url: 'https://example.com/demo-extension-two/releases',
    published_at: ''
  },
  {
    id: 'demo_extension_three',
    name: 'Demo Extension Three',
    description: 'Демо-карточка смены версии: релиз новее по дате, но ниже по номеру.',
    author: 'DN1Sup Demo',
    repo: 'example/demo-extension-three',
    asset: 'demo_extension_three.rbz',
    installed_version: '2.4.1',
    is_installed: true,
    latest_version: '0.4.1',
    has_update: false,
    status: 'switch',
    changelog: 'Демо-лог изменений: первая строка показывается на карточке.\nВторая строка видна только в раскрытом логе.',
    commits: ['feat: демо-коммит — сменена схема нумерации', 'fix: демо-коммит — мелкие правки'],
    release_url: 'https://example.com/demo-extension-three/releases',
    published_at: ''
  },
  {
    id: 'demo_extension_four',
    name: 'Demo Extension Four',
    description: 'Демо-карточка расширения, найденного автоматически на GitHub.',
    author: 'DN1Sup Demo',
    repo: 'example/demo-extension-four',
    asset: 'demo_extension_four.rbz',
    discovered: true,
    installed_version: '',
    is_installed: false,
    latest_version: '0.1.0',
    has_update: false,
    status: '',
    changelog: 'Демо-лог изменений: первая строка показывается на карточке.\nВторая строка видна только в раскрытом логе.',
    commits: [],
    release_url: 'https://example.com/demo-extension-four/releases',
    published_at: ''
  }
]

export function mockPayload() {
  return {
    version: '0.5.0-mock',
    products: mockProducts,
    sync: { fetching: false, fetched: mockProducts.length, total: mockProducts.length, failed: [], checked_at: Date.now() / 1000 | 0, snapshot_saved_at: 0, first_scan: false }
  }
}

function findProduct(id) {
  return mockProducts.find(p => p.id === id)
}

function withVersion(release) {
  return (release || '1.0.0').replace(/^v/, '')
}

/** Имитация действий Ruby: пушит результат и обновляет состояние. */
export function applyMockAction(name, params = {}) {
  const { id } = params
  const item = findProduct(id)

  if (name === 'refresh') {
    window.pushState({ version: '0.5.0-mock', products: mockProducts, sync: { fetching: true, fetched: 1, total: mockProducts.length, failed: [], checked_at: 0, snapshot_saved_at: 0, first_scan: false } })
    setTimeout(() => window.pushState(mockPayload()), 600)
    setTimeout(() => window.pushResult('check_summary', { ok: true, updates: 1, fetched: mockProducts.length, total: mockProducts.length, failed: [], message: 'Доступно обновлений: 1 (Demo Extension Two).' }), 700)
    return
  }

  if (name === 'install') {
    setTimeout(() => {
      if (item) {
        item.is_installed = true
        item.installed_version = withVersion(item.latest_version)
        item.has_update = false
        item.status = 'current'
      }
      window.pushResult('action_result', {
        id, action: 'install', ok: true,
        message: `Расширение «${item ? item.name : id}» успешно установлено!`
      })
      setTimeout(() => window.pushState(mockPayload()), 50)
    }, 800)
    return
  }

  if (name === 'update') {
    setTimeout(() => {
      if (item) {
        item.installed_version = withVersion(item.latest_version)
        item.has_update = false
        item.status = 'current'
      }
      window.pushResult('action_result', {
        id, action: 'update', ok: true,
        message: `Расширение «${item ? item.name : id}» успешно обновлено!`
      })
      setTimeout(() => window.pushState(mockPayload()), 50)
    }, 800)
    return
  }

  if (name === 'check_update') {
    setTimeout(() => {
      window.pushResult('action_result', {
        id, action: 'check_update', ok: true,
        message: `«${item ? item.name : id}»: у вас уже установлена актуальная версия.`
      })
      setTimeout(() => window.pushState(mockPayload()), 50)
    }, 800)
    return
  }

  if (name === 'confirm_uninstall') {
    // В браузере без SketchUp считаем подтверждённым
    setTimeout(() => window.pushResult('confirm_uninstall', { id, ok: true }), 100)
    return
  }

  if (name === 'install_all') {
    const ids = Array.isArray(params.ids) && params.ids.length
      ? params.ids
      : mockProducts.filter(p => !p.is_installed || p.has_update || p.status === 'switch').map(p => p.id)
    if (!ids.length) {
      setTimeout(() => window.pushResult('action_result', {
        id: '__bulk__', action: 'install_all', ok: false, error: 'Нет расширений для установки.'
      }), 200)
      return
    }
    // Пошаговый прогресс как в Ruby: bulk_progress после каждого расширения
    ids.forEach((pid, i) => {
      setTimeout(() => {
        const item = findProduct(pid)
        if (item) {
          item.is_installed = true
          item.installed_version = withVersion(item.latest_version)
          item.has_update = false
          item.status = 'current'
        }
        window.pushResult('bulk_progress', {
          action: 'install_all', current: i + 1, total: ids.length,
          id: pid, name: item ? item.name : pid, ok: true
        })
        if (i === ids.length - 1) {
          window.pushResult('action_result', {
            id: '__bulk__', action: 'install_all', ok: true,
            message: `Установлено/обновлено: ${ids.length}.`
          })
          setTimeout(() => window.pushState(mockPayload()), 50)
        }
      }, 400 * (i + 1))
    })
    return
  }

  if (name === 'confirm_uninstall_all') {
    const ids = Array.isArray(params.ids) && params.ids.length
      ? params.ids
      : mockProducts.filter(p => p.is_installed).map(p => p.id)
    setTimeout(() => window.pushResult('confirm_uninstall_all', { ids, ok: true }), 100)
    return
  }

  if (name === 'uninstall_all') {
    const ids = Array.isArray(params.ids) && params.ids.length
      ? params.ids
      : mockProducts.filter(p => p.is_installed).map(p => p.id)
    if (!ids.length) {
      setTimeout(() => window.pushResult('action_result', {
        id: '__bulk__', action: 'uninstall_all', ok: false, error: 'Нет установленных расширений для удаления.'
      }), 200)
      return
    }
    ids.forEach((pid, i) => {
      setTimeout(() => {
        const item = findProduct(pid)
        if (item) {
          item.is_installed = false
          item.installed_version = null
          item.has_update = false
        }
        window.pushResult('bulk_progress', {
          action: 'uninstall_all', current: i + 1, total: ids.length,
          id: pid, name: item ? item.name : pid, ok: true
        })
        if (i === ids.length - 1) {
          window.pushResult('action_result', {
            id: '__bulk__', action: 'uninstall_all', ok: true,
            message: `Удалено: ${ids.length}.`
          })
          setTimeout(() => window.pushState(mockPayload()), 50)
        }
      }, 300 * (i + 1))
    })
    return
  }

  if (name === 'uninstall') {
    setTimeout(() => {
      if (item) {
        item.is_installed = false
        item.installed_version = null
        item.has_update = false
      }
      window.pushResult('action_result', {
        id, action: 'uninstall', ok: true,
        message: `Расширение «${item ? item.name : id}» удалено.`
      })
      setTimeout(() => window.pushState(mockPayload()), 50)
    }, 600)
  }
}
