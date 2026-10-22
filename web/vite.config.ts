import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The build goes straight into Vapor's Public/ directory, so the web app and the
// API share one origin: no CORS, and the call WebSocket lives on the same host.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: '../Public',
    // Public/ also holds files that are not part of this build; `prebuild`
    // removes the previous index.html and assets/ instead.
    emptyOutDir: false,
  },
  server: {
    // `npm run dev` on :5173 talks to `swift run` on :8080, WebSocket included.
    proxy: {
      '/api': { target: 'http://localhost:8080', ws: true },
    },
  },
})
