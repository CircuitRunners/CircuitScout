#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-docs.sh — README, AGENTS.md and CLAUDE.md after the offline and data
# transfer patches
#   1. README.md: the Vite starter text is replaced with a short description
#      of CircuitScout: what it does, the stack, the commands, the
#      environment variables the Convex functions read, how changes ship
#      (patch scripts, and the Vercel build command), and offline in short.
#   2. AGENTS.md:
#      - Commands: bunx tsc -p convex, because bun run typecheck does not
#        cover the Convex functions.
#      - Reads and writes: useCachedQuery for queries shown offline,
#        useOnlineMutation for writes that must not queue offline.
#      - Held reports: transfer.relay is the second valid route.
#      - The four holdable saves run through shared write functions; change
#        what a save writes there.
#   3. CLAUDE.md: one line at the top pointing to AGENTS.md, above the block
#      Convex manages.
#
# Documentation only: no source file, dependency or Convex change.
# Requires the patches through patch-qr-scan.sh, because it describes them.
# Safe to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f vite.config.ts && -f convex/auth.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
[[ -f src/routes/scan.tsx ]] && grep -q 'export const relay = mutation(' convex/transfer.ts 2>/dev/null || {
  echo "ERROR: run the patches through patch-qr-scan.sh first; nothing was changed" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Checking"
trap 'rm -f .patch-docs.mjs .patch-docs.json' EXIT
cat > .patch-docs.json <<'EOF_JSON'
{
 "edited": {
  "AGENTS.md": {
   "marker": "bunx tsc -p convex",
   "edits": [
    {
     "old": "    bun run typecheck",
     "new": "    bun run typecheck   # the app only\n    bunx tsc -p convex  # the Convex functions; typecheck does not cover them"
    },
    {
     "old": "  mutations. Read with `useQuery`, write with `useMutation`.\n- **Zustand** (`src/stores/ui-store.ts`) owns only ephemeral client UI state:",
     "new": "  mutations. Read with `useQuery`, write with `useMutation`.\n  A query that pages show offline is read with `useCachedQuery` instead, and\n  a write that must not wait in a queue offline (pick lists, Admin) uses\n  `useOnlineMutation`. Both are in `src/lib/offline/`.\n- **Zustand** (`src/stores/ui-store.ts`) owns only ephemeral client UI state:"
    },
    {
     "old": "  scout again. Never queue an offline save in the Convex client, and never\n  send a held report any other way: the server writes each held id once.",
     "new": "  scout again, or uploaded by a teammate who scans its QR (`transfer.relay`).\n  Never queue an offline save in the Convex client, and never send a held\n  report by any other route: those two write each held id once.\n- The four saves a form can hold offline (`matchReports.submit`,\n  `pit.upsert`, `notes.saveMatchReport`, `notes.savePitReport`) are thin\n  wrappers around `writeMatchReport`, `writePitReport`, `writeGenericMatch`\n  and `writeGenericPit`. Change what a save writes in the write function,\n  so a save made online, a held report and a relayed one cannot differ. A\n  new form that can be saved offline also needs a kind in `heldReport`\n  (`convex/lib/transfer.ts`)."
    }
   ]
  },
  "CLAUDE.md": {
   "marker": "@AGENTS.md",
   "edits": [
    {
     "old": "<!-- convex-ai-start -->",
     "new": "This project's stack rules are in AGENTS.md. Read them before changing anything: @AGENTS.md\n\n<!-- convex-ai-start -->"
    }
   ]
  }
 },
 "replaced": {
  "README.md": {
   "was": [
    "4e3e3954304089029e89b232c93c0269e5d564191b9bd60d872b1233f99d8304",
    "12caecccd6829262770aab9dc4cccd75b518f8027c2756201ce9e996c0119792"
   ],
   "now": "061f54f0f5a09f12ec134e55e91ac40f90d95e41a3cf5397461dc7c951a23977"
  }
 }
}
EOF_JSON
cat > .patch-docs.mjs <<'MJS'
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const mode = process.argv[2]; // "check" | "write"
const { edited, replaced } = JSON.parse(readFileSync(".patch-docs.json", "utf8"));
const read = (path) => {
  try {
    return readFileSync(path, "utf8").replace(/\r\n/g, "\n");
  } catch {
    throw new Error(`${path} is missing`);
  }
};

// Files this patch rewrites whole. Each must be exactly what the earlier
// offline patches wrote, or what this patch writes.
for (const [path, { was, now }] of Object.entries(replaced)) {
  const hash = createHash("sha256").update(read(path)).digest("hex");
  if (![was].flat().includes(hash) && hash !== now) {
    throw new Error(`${path} is not the Vite starter text any more. This patch replaces it whole, so it stops here: move your version aside and run again, or keep yours.`);
  }
  if (mode === "check") console.log(`  ${hash === now ? "already applied " : "ok              "} ${path}`);
}

const staged = [];
for (const [path, { marker, edits }] of Object.entries(edited)) {
  let source = read(path);
  if (source.includes(marker)) {
    console.log(`  already applied  ${path}`);
    continue;
  }
  for (const { old, new: next } of edits) {
    const found = source.split(old).length - 1;
    if (found !== 1) {
      throw new Error(
        `${path} is not the version this patch expects (${found === 0 ? "not found" : "found more than once"}):\n` +
        old.split("\n").slice(0, 4).join("\n"),
      );
    }
    source = source.replace(old, () => next);
  }
  if (!source.includes(marker)) throw new Error(`${path}: the edit did not take`);
  staged.push([path, source]);
}

for (const [path, source] of staged) {
  if (mode === "write") {
    writeFileSync(path, source);
    console.log(`  patched          ${path}`);
  } else console.log(`  ok               ${path}`);
}
MJS
bun .patch-docs.mjs check || { echo "ERROR: nothing was changed" >&2; exit 1; }

say "README.md"
cat > README.md <<'EOF_FILE'
# CircuitScout

A mobile-first scouting app for FIRST Robotics Competition teams, built by
CircuitRunners (FRC 1002). Scouts record pit and match reports on their
phones; the team reviews robots, compares them and builds pick lists.

Created by Tarun A, FRC 1002.

## What it does

- **Pit and match scouting** for the active event, with match assignments.
- **Teams, matches and pick lists**: stored averages, compare, data plot,
  match previews and shared pick list boards.
- **Admin**: events imported from The Blue Alliance, accounts, exports,
  past events.
- **Works offline**: after one online visit the app opens with no
  connection, shows the last data it saw, and lets scouts fill in forms.
- **Reports saved offline are kept on the device** and send by themselves
  on reconnect. A teammate who is online can also upload them by scanning
  the scout's QR code.

## Stack

Bun · Vite · React 19 · TypeScript (strict) · React Router 7 ·
Tailwind CSS v4 · shadcn/ui on Base UI · Convex (data and auth) ·
installable as a PWA.

The rules for working in this codebase are in [AGENTS.md](AGENTS.md).

## Running it

Always use `bun`.

    bun install
    bun run go            # Convex and Vite together
    bun run typecheck     # the app
    bunx tsc -p convex    # the Convex functions
    bun run lint
    bun run build

`bun run go` needs a Convex deployment. The app reads its address from
`VITE_CONVEX_URL`.

The Convex deployment needs these environment variables:

| Variable | Used for |
| --- | --- |
| `TBA_API_KEY` | Importing events, teams and schedules from The Blue Alliance |
| `MATCH13_API_KEY` | match13 ratings |
| `GMAIL_USER`, `GMAIL_APP_PASSWORD` | Password reset emails |
| `SITE_URL` | The site's address; reset links are built from it |
| `JWT_PRIVATE_KEY`, `JWKS` | Convex Auth; both from one run of the key generator |

## How changes ship

Each change is one `patch-*.sh` script at the repo root. A script checks
every file it will touch before writing anything, and is safe to run twice.

    bash patch-name.sh

Production is built on Vercel with one command, which deploys the Convex
functions and builds the site in the same step, so the two go out together:

    bunx convex deploy --cmd 'bun run build'

## Offline, in short

- The built app is stored on the device by a service worker. A new release
  shows an "Update available" prompt, never in the middle of a form.
- Pick lists and Admin are view only without a connection.
- Photos need a connection.
- Signing out discards reports that have not been sent. The app asks first.
EOF_FILE
echo "  wrote            README.md"

say "AGENTS.md and CLAUDE.md"
bun .patch-docs.mjs write

say "Done"
cat <<'TXT'
Nothing to build or deploy. Read the three files over before committing:
README.md is new text, and the AGENTS.md changes are rules future work
will be held to.
TXT
