import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The admin panel is served by the Go backend at /admin/. In dev, Vite proxies
// API + WebSocket calls to the backend so the panel works against a live server.
export default defineConfig({
  plugins: [react()],
  base: '/admin/',
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: 'http://localhost:8080',
        changeOrigin: true,
      },
      '/auth': {
        target: 'http://localhost:8080',
        changeOrigin: true,
      },
      '/config': {
        target: 'http://localhost:8080',
        changeOrigin: true,
      },
      '/me': {
        target: 'http://localhost:8080',
        changeOrigin: true,
      },
      '/family': {
        target: 'http://localhost:8080',
        changeOrigin: true,
      },
      '/families': {
        target: 'http://localhost:8080',
        changeOrigin: true,
      },
      '/ws': {
        target: 'ws://localhost:8080',
        ws: true,
      },
    },
  },
  build: {
    // The Go server embeds this directory directly. Building here keeps the
    // browser bundle that ships in Docker/the standalone binary in sync with
    // the source bundle developers preview locally.
    outDir: '../backend/web/dist',
    emptyOutDir: true,
    sourcemap: false,
  },
})
