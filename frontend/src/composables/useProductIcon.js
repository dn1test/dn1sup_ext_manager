import { Puzzle } from 'lucide-vue-next'

// Фирменные плитки каталога (генератор: tools/make_icons.rb) — плоские
// белые знаки на цветных скруглённых квадратах. Восстановлено по образцу
// getPluginIcon(id) из интерфейса v0.4.x: значок подбирается по подстрокам
// id, без совпадений — общий пазл (например, для расширений, найденных на
// GitHub вне реестра). Порядок правил не менять: подбор по подстрокам
// должен отрабатывать от частного к общему.
import managerSvg from '../assets/products/dn1sup_extension_store.svg'
import timeSvg from '../assets/products/dn1sup_time_project.svg'
import createSvg from '../assets/products/dn1sup_create_project.svg'
import copiesSvg from '../assets/products/dn1sup_comp_add_view.svg'
import settingsSvg from '../assets/products/dn1sup_save_settings.svg'
import cubeSvg from '../assets/products/dn1sup_export_3d.svg'
import tagSvg from '../assets/products/dn1sup_autoselect_tag.svg'
import pdf2Svg from '../assets/products/dn1sup_export_pdf2.svg'
import profilesSvg from '../assets/products/dn1sup_sketchup_profiles.svg'

const ICON_RULES = [
  { match: ['create_project'], url: createSvg },
  { match: ['comp_add_view'], url: copiesSvg },
  { match: ['save_settings'], url: settingsSvg },
  { match: ['export_3d'], url: cubeSvg },
  { match: ['export_pdf'], url: pdf2Svg },
  { match: ['tag'], url: tagSvg },
  { match: ['profiles'], url: profilesSvg },
  { match: ['time', 'clock', 'timer'], url: timeSvg },
  { match: ['ext_manager', 'store', 'hub'], url: managerSvg },
]

function findRule(id) {
  const s = String(id || '').toLowerCase()
  return ICON_RULES.find((rule) => rule.match.some((m) => s.includes(m)))
}

// Фирменная плитка для расширения из реестра; null — нет совпадения.
export function productIconUrl(id) {
  const rule = findRule(id)
  return rule ? rule.url : null
}

// Фолбэк-компонент (common пазл) для расширений вне реестра; null — есть плитка.
export function productIcon(id) {
  return findRule(id) ? null : Puzzle
}

// Класс цвета только для фолбэка; у плиток цвет уже «вшит» в SVG.
export function productIconClass(id) {
  return findRule(id) ? '' : 'text-slate-400 dark:text-slate-500'
}
