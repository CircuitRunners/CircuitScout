import { fileURLToPath, URL } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { VitePWA } from "vite-plugin-pwa";

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      // "prompt": a new version waits until <UpdatePrompt> is told to switch,
      // or until every tab of the app has been closed.
      registerType: "prompt",
      // Registered by useRegisterSW in src/components/update-prompt.tsx.
      injectRegister: false,
      // The workbox glob below already picks the icons up; leaving this on
      // would list them in the precache twice.
      includeManifestIcons: false,
      manifest: {
        name: "CircuitScout",
        short_name: "CircuitScout",
        description: "FRC scouting for pit, match and pick lists.",
        start_url: "/",
        scope: "/",
        display: "standalone",
        orientation: "portrait",
        theme_color: "#0a0a0a",
        background_color: "#0a0a0a",
        icons: [
          { src: "/pwa-192.png", sizes: "192x192", type: "image/png" },
          { src: "/pwa-512.png", sizes: "512x512", type: "image/png" },
          { src: "/pwa-maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
        ],
      },
      workbox: {
        globPatterns: ["**/*.{js,css,html,png,svg,woff2}"],
        // Export needs a connection anyway; the spreadsheet library still
        // loads on demand when online.
        globIgnores: ["**/xlsx-*.js"],
        // Workbox skips anything over 2 MiB with only a build warning, and
        // the app would then fail offline. The main chunk is close to 1 MB.
        maximumFileSizeToCacheInBytes: 4 * 1024 * 1024,
        // Same job as the Vercel rewrite: any path opens the SPA.
        navigateFallback: "/index.html",
        cleanupOutdatedCaches: true,
      },
    }),
  ],
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url)),
    },
  },
  server: { port: 5173 },
});
