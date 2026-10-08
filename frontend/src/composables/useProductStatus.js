import { computed } from 'vue'
import { Circle, Zap, CircleCheck } from 'lucide-vue-next'

export function useProductStatus(productRef) {
  const statusText = computed(() => {
    const p = productRef.value
    if (!p.is_installed) return 'Не установлено'
    if (p.has_update) return 'Обновление'
    return 'Установлено'
  })

  const statusCls = computed(() => {
    const p = productRef.value
    if (!p.is_installed) {
      return 'bg-slate-100 dark:bg-slate-800 text-slate-500 dark:text-slate-400 border border-slate-200 dark:border-slate-700'
    }
    if (p.has_update) {
      return 'bg-amber-100 dark:bg-amber-900/60 text-amber-700 dark:text-amber-300 border border-amber-200 dark:border-amber-800 font-semibold'
    }
    return 'bg-emerald-100 dark:bg-emerald-900/60 text-emerald-700 dark:text-emerald-300 border border-emerald-200 dark:border-emerald-800'
  })

  const statusIcon = computed(() => {
    const p = productRef.value
    return !p.is_installed ? Circle : (p.has_update ? Zap : CircleCheck)
  })

  const versionText = computed(() => {
    const p = productRef.value
    const inst = p.installed_version
    const latest = p.latest_version
    if (p.has_update && inst) return `Версия: v${inst} → v${latest}`
    if (p.is_installed && inst) return `Версия: v${inst}`
    return `Доступно: v${latest || '—'}`
  })

  const versionTitle = computed(() => {
    const p = productRef.value
    const inst = p.installed_version
    return [
      inst ? `установлена: v${inst}` : null,
      p.latest_version ? `доступна: v${p.latest_version}` : null,
      p.published_at ? `релиз: ${p.published_at}` : null
    ].filter(Boolean).join(' · ')
  })

  return {
    statusText,
    statusCls,
    statusIcon,
    versionText,
    versionTitle
  }
}
