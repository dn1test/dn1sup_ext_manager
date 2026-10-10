import { Box, FolderPlus, Puzzle, Ruler, Settings, Store, Tag, Timer } from 'lucide-vue-next'

// Индивидуальная иконка расширения в списке каталога. Восстановлено по
// образцу getPluginIcon(id) из интерфейса v0.4.x: значок подбирается по
// подстрокам id, без совпадений — общий пазл (например, для расширений,
// найденных на GitHub вне реестра). Порядок правил не менять: подбор по
// подстрокам должен отрабатывать от частного к общему.
const ICON_RULES = [
  { match: ['create_project'], icon: FolderPlus, cls: 'text-emerald-500 dark:text-emerald-400' },
  { match: ['comp_add_view'], icon: Ruler, cls: 'text-amber-500 dark:text-amber-400' },
  { match: ['save_settings'], icon: Settings, cls: 'text-slate-500 dark:text-slate-400' },
  { match: ['export_3d'], icon: Box, cls: 'text-cyan-500 dark:text-cyan-400' },
  { match: ['tag'], icon: Tag, cls: 'text-violet-500 dark:text-violet-400' },
  { match: ['time', 'clock', 'timer'], icon: Timer, cls: 'text-sky-500 dark:text-sky-400' },
  { match: ['ext_manager', 'store', 'hub'], icon: Store, cls: 'text-brand-500 dark:text-brand-400' },
]

function findRule(id) {
  const s = String(id || '').toLowerCase()
  return ICON_RULES.find((rule) => rule.match.some((m) => s.includes(m)))
}

export function productIcon(id) {
  return (findRule(id) || { icon: Puzzle }).icon
}

export function productIconClass(id) {
  return (findRule(id) || { cls: 'text-slate-400 dark:text-slate-500' }).cls
}
