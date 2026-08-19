import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    // docs/deployments.json и forge-артефакты импортируются из корня репозитория
    fs: { allow: ['..'] },
  },
});
