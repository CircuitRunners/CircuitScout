#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-pwa.sh — offline plan, patch 1 of 5: the PWA shell
#   1. vite-plugin-pwa 2.0.0 (pinned): a generated service worker precaches
#      the built app, so its files load with no connection after one visit
#   2. Web app manifest + icons, so the app installs to a home screen
#   3. <UpdatePrompt>: a new version prompts with a Reload button while the
#      app is running, never inside a scouting form, and never reloads on its
#      own. A fully closed app picks the new version up on its next launch.
#   4. public/loading-wheel.png shrunk from 878 px / 1.57 MB to 192 px / 70 KB.
#      It is shown at 48 px at most, and at full size it was over half of
#      what every device downloads for offline use. The original stays in
#      git history.
#
# What this patch does NOT do: sign-in and data still need a connection.
# Offline, the app files load and the auth spinner shows. That is expected
# until patches 2 and 3 (cached reads, cached login).
#
# The service worker is OFF under `bun run go`. To test it:
#   bun run build && bunx vite preview      (or a Vercel preview URL)
#
# Escape hatch if a bad service worker ever ships: add `selfDestroying: true`
# to the VitePWA({...}) options in vite.config.ts and deploy. Do not just
# remove the plugin; a removed worker stays on devices that already have it.
#
# No Convex change. No schema change. Safe to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f vite.config.ts && -f convex/auth.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# ---- 1. Check every anchor before writing anything ------------------------
say "Checking anchors"
cat > .patch-pwa.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";

const mode = process.argv[2]; // "check" | "write"
const edits = [];

/** One edit: skip when `marker` is already present, else require `anchor` exactly once. */
function edit(path, marker, anchor, replacement) {
  const source = readFileSync(path, "utf8").replace(/\r\n/g, "\n");
  if (source.includes(marker)) {
    edits.push({ path, skip: true });
    return;
  }
  const count = source.split(anchor).length - 1;
  if (count !== 1) {
    throw new Error(`${path}: expected anchor once, found ${count}:\n  ${anchor}`);
  }
  edits.push({ path, skip: false, next: source.replace(anchor, replacement) });
}

// vite.config.ts — two anchors, applied as one edit.
{
  const path = "vite.config.ts";
  const source = readFileSync(path, "utf8").replace(/\r\n/g, "\n");
  if (source.includes("vite-plugin-pwa")) {
    edits.push({ path, skip: true });
  } else {
    const importAnchor = 'import tailwindcss from "@tailwindcss/vite";\n';
    const pluginAnchor = "  plugins: [react(), tailwindcss()],\n";
    for (const anchor of [importAnchor, pluginAnchor]) {
      const count = source.split(anchor).length - 1;
      if (count !== 1) throw new Error(`${path}: expected anchor once, found ${count}:\n  ${anchor}`);
    }
    const plugins = `  plugins: [
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
`;
    edits.push({
      path,
      skip: false,
      next: source
        .replace(importAnchor, importAnchor + 'import { VitePWA } from "vite-plugin-pwa";\n')
        .replace(pluginAnchor, plugins),
    });
  }
}

edit(
  "index.html",
  "apple-touch-icon",
  '    <link rel="icon" type="image/png" href="/logo.png" />\n',
  `    <link rel="icon" type="image/png" href="/logo.png" />
    <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
    <meta name="theme-color" media="(prefers-color-scheme: light)" content="#ffffff" />
    <meta name="theme-color" media="(prefers-color-scheme: dark)" content="#0a0a0a" />
`,
);

edit(
  "src/vite-env.d.ts",
  "vite-plugin-pwa/react",
  '/// <reference types="vite/client" />\n',
  '/// <reference types="vite/client" />\n/// <reference types="vite-plugin-pwa/react" />\n',
);

// root-layout.tsx — import and mount, applied as one edit.
{
  const path = "src/routes/root-layout.tsx";
  const source = readFileSync(path, "utf8").replace(/\r\n/g, "\n");
  if (source.includes("UpdatePrompt")) {
    edits.push({ path, skip: true });
  } else {
    const importAnchor = 'import { Toaster } from "@/components/ui/sonner";\n';
    const mountAnchor = "      <Toaster richColors closeButton />\n";
    for (const anchor of [importAnchor, mountAnchor]) {
      const count = source.split(anchor).length - 1;
      if (count !== 1) throw new Error(`${path}: expected anchor once, found ${count}:\n  ${anchor}`);
    }
    edits.push({
      path,
      skip: false,
      next: source
        .replace(importAnchor, 'import { UpdatePrompt } from "@/components/update-prompt";\n' + importAnchor)
        .replace(mountAnchor, mountAnchor + "      <UpdatePrompt />\n"),
    });
  }
}

for (const e of edits) {
  if (e.skip) console.log(`  already patched  ${e.path}`);
  else if (mode === "write") {
    writeFileSync(e.path, e.next);
    console.log(`  patched          ${e.path}`);
  } else console.log(`  ok               ${e.path}`);
}
MJS
trap 'rm -f .patch-pwa.mjs' EXIT
bun .patch-pwa.mjs check || { echo "ERROR: nothing was changed" >&2; exit 1; }

# ---- 2. Dependency ---------------------------------------------------------
say "Dependency: vite-plugin-pwa 2.0.0 (pinned)"
if grep -q '"vite-plugin-pwa"' package.json; then
  echo "  already in package.json"
else
  bun add -d --exact vite-plugin-pwa@2.0.0
fi

# ---- 3. Icons ----------------------------------------------------------------
# Generated from public/logo.png on a #0a0a0a background (the logo's white
# circuit traces vanish on white). The maskable icon keeps the logo inside
# the 80% safe zone so Android can crop it to any shape.
say "Icons"
icon() {
  if [[ -f "public/$1" ]]; then echo "  already there    public/$1"; return; fi
  base64 -d > "public/$1"
  echo "  wrote            public/$1"
}
icon pwa-192.png <<'B64'
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
ywAAAABJRU5ErkJggg==
B64
icon pwa-512.png <<'B64'
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
RK5CYII=
B64
icon pwa-maskable-512.png <<'B64'
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
GhyKAAAAAElFTkSuQmCC
B64
icon apple-touch-icon.png <<'B64'
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
B64

# ---- 3b. Loading wheel -----------------------------------------------------
# Only replaced while it is still the large original, so a wheel you have
# changed yourself is left alone and a re-run does nothing.
say "Loading wheel"
if [[ -f public/loading-wheel.png ]] && (( $(wc -c < public/loading-wheel.png) > 200000 )); then
  base64 -d > public/loading-wheel.png <<'B64'
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
rkJggg==
B64
  echo "  shrunk           public/loading-wheel.png"
else
  echo "  left alone       public/loading-wheel.png"
fi

# ---- 4. Update prompt ------------------------------------------------------
say "UI: update prompt"
cat > src/components/update-prompt.tsx <<'TSX'
import { useEffect } from "react";
import { useLocation } from "react-router";
import { toast } from "sonner";
import { useRegisterSW } from "virtual:pwa-register/react";

const TOAST_ID = "app-update";
const CHECK_EVERY_MS = 60 * 60 * 1000;

/**
 * Scouting forms, for every season (the routes are season-switched, so the
 * 2026 forms and the generic ones share these paths). A scout mid-match must
 * never be offered a reload: it would throw the form away.
 */
const FORM_ROUTES = [/^\/scout\/[^/]+\/[^/]+\/?$/, /^\/pit\/[^/]+\/?$/];

/**
 * The update rule (offline plan, O-6):
 *  - a new version downloads quietly in the background;
 *  - while the app is running it is offered with a Reload button, on every
 *    page except a scouting form;
 *  - nothing ever reloads on its own;
 *  - an app that was fully closed starts on the new version by itself.
 * Renders nothing. Mounted once, in RootLayout.
 */
export function UpdatePrompt() {
  const { pathname } = useLocation();
  const {
    needRefresh: [needRefresh],
    updateServiceWorker,
  } = useRegisterSW({
    onRegisteredSW(_url, registration) {
      if (!registration) return;
      const check = () => {
        if (navigator.onLine) void registration.update().catch(() => {});
      };
      // Browsers only look for a new worker on navigation, and a single-page
      // app that stays open all day never navigates.
      window.setInterval(check, CHECK_EVERY_MS);
      // A phone that was in a pocket for three matches: look when it wakes.
      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "visible") check();
      });
    },
  });

  const onForm = FORM_ROUTES.some((route) => route.test(pathname));

  useEffect(() => {
    if (!needRefresh || onForm) {
      toast.dismiss(TOAST_ID);
      return;
    }
    toast("Update available", {
      id: TOAST_ID,
      description: "Reload to get the latest version of CircuitScout.",
      duration: Infinity,
      action: { label: "Reload", onClick: () => void updateServiceWorker(true) },
    });
  }, [needRefresh, onForm, updateServiceWorker]);

  return null;
}
TSX

# ---- 5. Anchored edits -----------------------------------------------------
say "Wiring: vite.config.ts, index.html, vite-env.d.ts, root-layout.tsx"
bun .patch-pwa.mjs write
rm -f .patch-pwa.mjs

say "Done"
cat <<'TXT'
Next:
  1. bun run typecheck && bun run lint && bun run build
     The build should end with a "PWA v2.0.0" block listing the precache.
     Read it: a file Workbox skipped for size would be named there.
  2. bunx vite preview, open it, then DevTools > Application:
       - Service workers: sw.js is activated
       - Manifest: CircuitScout, three icons, no warnings
     Tick Offline in the Network tab and reload: the app files load and the
     auth spinner shows. That spinner is expected until patches 2 and 3.
  3. After the first Vercel deploy, check the response headers for /sw.js:
     cache-control must revalidate (max-age=0), or devices will not notice
     new versions.
  4. On a phone: Android offers Install; on iPhone use Share > Add to Home
     Screen. The iPhone home screen app needs its own sign-in once.
TXT
