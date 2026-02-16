/** @type {import('tailwindcss').Config} */
export default {
  content: ['./src/**/*.{astro,html,js,jsx,md,mdx,svelte,ts,tsx,vue}'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        'hb-green': '#4a7c50',
        'hb-green-dark': '#2c5530',
        'hb-green-light': '#6b9e6f',
        'hb-amber': '#d97706',
        'hb-amber-dark': '#b45309',
        'hb-erlang': '#a90533',
        // Theme-aware colors via CSS variables
        'hb-bg': 'var(--hb-bg)',
        'hb-bg-secondary': 'var(--hb-bg-secondary)',
        'hb-text': 'var(--hb-text)',
        'hb-muted': 'var(--hb-muted)',
        'hb-border': 'var(--hb-border)',
        'hb-code-bg': 'var(--hb-code-bg)',
      },
      fontFamily: {
        sans: ['system-ui', '-apple-system', 'sans-serif'],
        mono: ['ui-monospace', 'JetBrains Mono', 'monospace'],
      }
    },
  },
  plugins: [],
}
