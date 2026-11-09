import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({
  base: './',
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: true,
    watch: {
      ignored: ['**/backend-build/**', '**/backend-dist/**', '**/release/**', '**/test-output/**'],
    },
  },
});
