import { computed } from 'vue'
import { Circle, Zap, CircleCheck, ArrowLeftRight, CircleAlert } from 'lucide-vue-next'

// p.status приходит из Ruby (Dn1sup::Updater.product_status):
//   'update'  — есть релиз новее по номеру версии;
//   'switch'  — релиз новее по дате, но ниже по номеру (смена схемы нумерации);
//   'current' — установлена актуальная версия;
//   ''        — нет данных / не установлено.
// p.repo_status ('gone'|'renamed') — репозиторий расширения удалён или
// перемещён на GitHub: обновление/установка невозможны, карточка остаётся
// только у установленных.
const isUpdate = (p) => p.has_update || p.status === 'update'
const isSwitch = (p) => !!p.is_installed && p.status === 'switch'
const isRepoGone = (p) => !!p.is_installed && p.repo_status === 'gone'
const isRepoMoved = (p) => !!p.is_installed && p.repo_status === 'renamed'

export function useProductStatus(productRef) {
  const statusText = computed(() => {
    const p = productRef.value
    if (isRepoGone(p)) return 'Репозиторий недоступен'
    if (isRepoMoved(p)) return 'Репозиторий перемещён'
    if (!p.is_installed) return 'Не установлено'
    if (isUpdate(p)) return 'Обновление'
    if (isSwitch(p)) return 'Смена версии'
    return 'Установлено'
  })

  const statusCls = computed(() => {
    const p = productRef.value
    if (isRepoGone(p) || isRepoMoved(p)) {
      return 'bg-slate-100 dark:bg-slate-800 text-slate-500 dark:text-slate-400 border border-slate-200 dark:border-slate-700'
    }
    if (!p.is_installed) {
      return 'bg-slate-100 dark:bg-slate-800 text-slate-500 dark:text-slate-400 border border-slate-200 dark:border-slate-700'
    }
    if (isUpdate(p)) {
      return 'bg-amber-100 dark:bg-amber-900/60 text-amber-700 dark:text-amber-300 border border-amber-200 dark:border-amber-800 font-semibold'
    }
    if (isSwitch(p)) {
      return 'bg-sky-100 dark:bg-sky-900/60 text-sky-700 dark:text-sky-300 border border-sky-200 dark:border-sky-800 font-semibold'
    }
    return 'bg-emerald-100 dark:bg-emerald-900/60 text-emerald-700 dark:text-emerald-300 border border-emerald-200 dark:border-emerald-800'
  })

  const statusIcon = computed(() => {
    const p = productRef.value
    if (isRepoGone(p) || isRepoMoved(p)) return CircleAlert
    if (!p.is_installed) return Circle
    if (isUpdate(p)) return Zap
    if (isSwitch(p)) return ArrowLeftRight
    return CircleCheck
  })

  const versionText = computed(() => {
    const p = productRef.value
    const inst = p.installed_version
    const latest = p.latest_version
    if ((isRepoGone(p) || isRepoMoved(p)) && inst) return `Версия: v${inst}`
    if ((isUpdate(p) || isSwitch(p)) && inst) return `Версия: v${inst} → v${latest}`
    if (p.is_installed && inst) return `Версия: v${inst}`
    return `Доступно: v${latest || '—'}`
  })

  const versionTitle = computed(() => {
    const p = productRef.value
    const inst = p.installed_version
    return [
      inst ? `установлена: v${inst}` : null,
      p.latest_version ? `доступна: v${p.latest_version}` : null,
      p.published_at ? `релиз: ${p.published_at}` : null,
      isSwitch(p) ? 'релиз новее по дате публикации, но ниже по номеру (смена схемы нумерации)' : null,
      isRepoGone(p) ? 'репозиторий удалён на GitHub — обновление недоступно' : null,
      isRepoMoved(p) ? `репозиторий перемещён${p.repo ? `: ${p.repo}` : ''} — обновление недоступно` : null
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
