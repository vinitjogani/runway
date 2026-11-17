import { defineConfig } from 'vite';

// One static page at /, its images in public/. `npm run build` → dist/.
export default defineConfig({
  build: { outDir: 'dist', emptyOutDir: true },
});
