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
    repo: 'example/demo-extension-one',
    asset: 'demo_extension_one.rbz',
    installed_version: '1.0.0',
    is_installed: true,
    latest_version: '1.0.0',
    has_update: false,
    changelog: 'Демо-лог изменений.',
    release_url: 'https://example.com/demo-extension-one/releases',
    published_at: ''
  },
  {
    id: 'demo_extension_two',
    name: 'Demo Extension Two',
    description: 'Нейтральная демо-карточка с доступным обновлением.',
    repo: 'example/demo-extension-two',
    asset: 'demo_extension_two.rbz',
    installed_version: '0.9.0',
    is_installed: true,
    latest_version: '1.0.0',
    has_update: true,
    status: 'update',
    changelog: 'Демо-лог изменений.',
    release_url: 'https://example.com/demo-extension-two/releases',
    published_at: ''
  },
  {
    id: 'demo_extension_three',
    name: 'Demo Extension Three',
    description: 'Демо-карточка смены версии: релиз новее по дате, но ниже по номеру.',
    repo: 'example/demo-extension-three',
    asset: 'demo_extension_three.rbz',
    installed_version: '2.4.1',
    is_installed: true,
    latest_version: '0.4.1',
    has_update: false,
    status: 'switch',
    changelog: 'Демо-лог изменений.',
    commits: ['feat: демо-коммит — сменена схема нумерации', 'fix: демо-коммит — мелкие правки'],
    release_url: 'https://example.com/demo-extension-three/releases',
    published_at: ''
  },
  {
    id: 'demo_extension_four',
    name: 'Demo Extension Four',
    description: 'Демо-карточка расширения, найденного автоматически на GitHub.',
    repo: 'example/demo-extension-four',
    asset: 'demo_extension_four.rbz',
    discovered: true,
    installed_version: '',
    is_installed: false,
    latest_version: '0.1.0',
    has_update: false,
    status: '',
    changelog: 'Демо-лог изменений.',
    commits: [],
    release_url: 'https://example.com/demo-extension-four/releases',
    published_at: ''
  }
]

export function mockPayload() {
  return {
    version: '0.5.0-mock',
    products: mockProducts
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
    setTimeout(() => window.pushState(mockPayload()), 300)
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

  if (name === 'confirm_uninstall') {
    // В браузере без SketchUp считаем подтверждённым
    setTimeout(() => window.pushResult('confirm_uninstall', { id, ok: true }), 100)
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
