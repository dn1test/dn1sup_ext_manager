import { ref, onMounted } from 'vue'

const isDark = ref(false)

export function useTheme() {
  function applyTheme(dark) {
    isDark.value = dark
    if (dark) {
      document.documentElement.classList.add('dark')
    } else {
      document.documentElement.classList.remove('dark')
    }
    try {
      localStorage.setItem('dn1sup_theme', dark ? 'dark' : 'light')
    } catch {
      // ignore
    }
  }

  function toggleTheme() {
    applyTheme(!isDark.value)
  }

  onMounted(() => {
    try {
      const saved = localStorage.getItem('dn1sup_theme')
      if (saved) {
        applyTheme(saved === 'dark')
      } else {
        // default to light mode to match SketchUp native UI
        applyTheme(false)
      }
    } catch {
      applyTheme(false)
    }
  })

  return {
    isDark,
    toggleTheme,
    applyTheme
  }
}
