import { defineConfig } from 'astro/config';
import tailwind from '@astrojs/tailwind';
import mdx from '@astrojs/mdx';

export default defineConfig({
  site: 'https://hornbeam.dev',
  integrations: [
    tailwind(),
    mdx()
  ],
  markdown: {
    shikiConfig: {
      themes: {
        light: 'github-light',
        dark: 'github-dark'
      },
      wrap: true,
      defaultColor: false
    }
  }
});
