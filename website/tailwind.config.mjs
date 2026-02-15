/** @type {import('tailwindcss').Config} */
export default {
  content: ['./src/**/*.{astro,html,js,jsx,md,mdx,svelte,ts,tsx,vue}'],
  theme: {
    extend: {
      colors: {
        'hb-green': '#4a7c50',
        'hb-green-dark': '#2c5530',
        'hb-green-light': '#6b9e6f',
        'hb-amber': '#d97706',
        'hb-amber-dark': '#b45309',
        'hb-erlang': '#a90533',
        'hb-black': '#1a1f1a',
        'hb-gray': '#e8ede8',
      },
      fontFamily: {
        sans: ['system-ui', '-apple-system', 'sans-serif'],
        mono: ['ui-monospace', 'JetBrains Mono', 'monospace'],
      }
    },
  },
  plugins: [],
}
