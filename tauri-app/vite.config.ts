import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig(({ command }) => ({
  base: "./",
  plugins: [
    react(),
    ...(command === "build"
      ? [
          {
            name: "codex-token-bar-tauri-html",
            transformIndexHtml(html: string) {
              return html
                .replaceAll(" crossorigin", "")
                .replaceAll('type="module"', "defer");
            },
          },
        ]
      : []),
  ],
  clearScreen: false,
  server: {
    strictPort: true,
    host: "127.0.0.1",
    port: 1420,
  },
  envPrefix: ["VITE_", "TAURI_"],
  build: {
    rollupOptions: {
      output: {
        format: "iife",
      },
    },
  },
}));
