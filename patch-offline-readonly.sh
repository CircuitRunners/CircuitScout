#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-offline-readonly.sh — offline plan, patch 5 of 5: view-only pages
#   1. Pick lists, the pick list board, Admin, the merge preview, coverage
#      and the team views (team detail, compare, plot, match preview) keep
#      the last copy this device loaded, and show it offline.
#   2. Nothing on pick lists or Admin can be changed offline (decision O-7):
#        - the board drops to read only: no dragging, no note edits, no
#          picked ticks, and the existing "Read only" badge shows;
#        - every other write on those pages goes through useOnlineMutation /
#          useOnlineAction, which refuse at once offline instead of queueing;
#        - a "View only while offline" line sits under the offline banner.
#      Scouting forms are unaffected: their reports are still held and sent.
#   3. Admin cards (useOnDemand) save each load and show the saved copy
#      offline, with the time it was loaded. They do not reload by themselves
#      when the connection returns: press Refresh.
#   4. A page with no saved copy says "Not saved on this device. Reconnect to
#      load it." instead of "Loading…" forever.
#
# Never saved to the device: scout email addresses (account.myEmail,
# account.scoutEmail), the delete-event preview, the usage card and exports.
#
# Requires patches 2 to 4b (patch-offline-store, -login, -forms, -held).
# No Convex change, no new function calls, no new dependency. Safe to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f vite.config.ts && -f convex/auth.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
[[ -f src/lib/offline/store.ts && -f src/components/needs-connection.tsx && -f src/lib/offline/held.ts ]] || {
  echo "ERROR: run the earlier offline patches first (store, login, forms, held); nothing was changed" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# ---- 1. Check everything before writing anything --------------------------
say "Checking"
trap 'rm -f .patch-offline-readonly.mjs' EXIT
cat > .patch-offline-readonly.mjs <<'MJS'
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const mode = process.argv[2]; // "check" | "write"
const plan = new Map(); // path -> { before, next }
const read = (path) => readFileSync(path, "utf8").replace(/\r\n/g, "\n");
const current = (path) => plan.get(path)?.next ?? read(path);
function stage(path, next) {
  const before = plan.get(path)?.before ?? read(path);
  plan.set(path, { before, next });
}

const IMPORTS = {
  useCachedQuery: 'import { useCachedQuery } from "@/lib/offline/use-cached-query";\n',
  LoadingText: 'import { LoadingText } from "@/components/loading-text";\n',
  useOnline: 'import { useOnline } from "@/lib/offline/status";\n',
};

/**
 * Bring one file to the wanted state. Each step counts what it finds and
 * accepts exactly two answers: the count this patch expects (apply it) or
 * none left (already applied). Anything else stops the patch before any file
 * is written.
 *
 *   cached     how many useQuery(api.x) calls become useCachedQuery
 *   keep       calls that must stay live-only, by reference
 *   mutations  how many useMutation( calls become useOnlineMutation(
 *   actions    how many useAction( calls become useOnlineAction(
 */
function bring(path, { cached = 0, keep = [], mutations = 0, actions = 0 } = {}) {
  let source = current(path);

  let switched = 0;
  source = source.replace(/\buseQuery\((\s*)(api\.[A-Za-z0-9_.]+)/g, (whole, space, ref) => {
    if (keep.includes(ref)) return whole;
    switched += 1;
    return `useCachedQuery(${space}${ref}`;
  });
  if (switched !== cached && switched !== 0) {
    throw new Error(`${path}: expected ${cached} useQuery calls to switch, found ${switched}`);
  }
  for (const ref of keep) {
    if (!source.includes(`useQuery(${ref}`)) throw new Error(`${path}: expected useQuery(${ref} to be present`);
  }

  const swap = (from, to, expected) => {
    const found = source.split(`${from}(`).length - 1;
    if (found !== expected && found !== 0) {
      throw new Error(`${path}: expected ${expected} ${from}( calls, found ${found}`);
    }
    source = source.split(`${from}(`).join(`${to}(`);
  };
  swap("useMutation", "useOnlineMutation", mutations);
  swap("useAction", "useOnlineAction", actions);

  // "Loading…" as the whole text of a paragraph: say so when nothing is coming.
  source = source.split(">Loading…</p>").join("><LoadingText /></p>");

  stage(path, fixImports(path, source));
}

/** Only the "Loading…" paragraphs, for pages this patch does not otherwise touch. */
function loadingText(path) {
  stage(path, fixImports(path, current(path).split(">Loading…</p>").join("><LoadingText /></p>")));
}

/** Imports follow use: add ours where needed, drop convex/react names no longer used. */
function fixImports(path, source) {
  const convexImport = /import \{([^}]*)\} from "convex\/react";\n/;
  const match = source.match(convexImport);
  if (match) {
    const names = match[1].split(",").map((n) => n.trim()).filter(Boolean);
    const body = source.replace(convexImport, "");
    const kept = names.filter((n) => new RegExp(`\\b${n.replace(/^type\s+/, "")}\\b`).test(body));
    if (kept.length !== names.length) {
      source = source.replace(
        convexImport,
        kept.length ? `import { ${kept.join(", ")} } from "convex/react";\n` : "",
      );
    }
  }
  const wanted = [];
  for (const [name, line] of Object.entries(IMPORTS)) {
    if (new RegExp(`\\b${name}\\b`).test(source) && !source.includes(line)) wanted.push(line);
  }
  const guards = ["useOnlineMutation", "useOnlineAction"].filter((n) => new RegExp(`\\b${n}\\(`).test(source));
  if (guards.length && !source.includes("@/lib/offline/use-online-mutation")) {
    wanted.push(`import { ${guards.join(", ")} } from "@/lib/offline/use-online-mutation";\n`);
  }
  if (wanted.length === 0) return source;
  const first = source.search(/^import /m);
  if (first < 0) throw new Error(`${path}: no import to anchor on`);
  return source.slice(0, first) + wanted.join("") + source.slice(first);
}

/** Skip when `marker` is present; otherwise every anchor must appear exactly once. */
function edit(path, marker, pairs) {
  let source = current(path);
  if (source.includes(marker)) return;
  for (const [anchor] of pairs) {
    const count = source.split(anchor).length - 1;
    if (count !== 1) throw new Error(`${path}: expected anchor once, found ${count}:\n  ${anchor}`);
  }
  for (const [anchor, replacement] of pairs) source = source.replace(anchor, replacement);
  stage(path, fixImports(path, source));
}

// ---- Pick lists -------------------------------------------------------------
bring("src/routes/picklists/index.tsx", { cached: 4, mutations: 7 });
bring("src/routes/picklists/board.tsx", { cached: 5, mutations: 3 });
bring("src/routes/notes/board.tsx", { cached: 4, mutations: 3 });
// Offline the board is view only. Every edit path on it (dragging, notes,
// picked ticks, the Read only badge) already keys off list.canEdit.
for (const path of ["src/routes/picklists/board.tsx", "src/routes/notes/board.tsx"]) {
  edit(path, "storedList", [
    [
      '  const list = useCachedQuery(api.pickLists.get, listId ? { listId } : "skip");\n',
      `  const online = useOnline();
  const storedList = useCachedQuery(api.pickLists.get, listId ? { listId } : "skip");
  // Offline the board is view only: every edit path below keys off canEdit.
  const list = useMemo(
    () => (storedList && !online ? { ...storedList, canEdit: false } : storedList),
    [storedList, online],
  );
`,
    ],
  ]);
}

// ---- Admin ------------------------------------------------------------------
bring("src/routes/admin/index.tsx", { cached: 2, keep: ["api.events.purgePreview"], mutations: 4, actions: 1 });
bring("src/routes/admin/data.tsx", { cached: 1 });
bring("src/routes/admin/merge.tsx", { cached: 1, mutations: 1 });
bring("src/routes/admin/reports-admin.tsx", { cached: 2, mutations: 5 });
bring("src/routes/admin/stat-sources-card.tsx", { cached: 3, mutations: 2, actions: 1 });
bring("src/routes/admin/assign-dialog.tsx", { cached: 2, mutations: 3 });
// Scout email addresses are never saved to the device.
bring("src/routes/admin/roles-table.tsx", {
  cached: 3, keep: ["api.account.myEmail", "api.account.scoutEmail"], mutations: 6,
});
bring("src/routes/notes/admin-notes.tsx", { cached: 1, mutations: 2 });
bring("src/components/attention-items.tsx", { cached: 1, mutations: 1 });

// Admin cards load once and on Refresh, never as subscriptions. Each load is
// saved; offline the card shows the saved copy with the time it was loaded.
edit("src/routes/admin/refresh-context.ts", "readCached", [
  [
    'import { toast } from "sonner";\n',
    'import { toast } from "sonner";\n\nimport { useOnline } from "@/lib/offline/status";\nimport { cacheKey, readCached, saveResult } from "@/lib/offline/store";\n',
  ],
  [
    "  const argsKey = JSON.stringify(args);\n",
    `  const argsKey = JSON.stringify(args);
  // Read through a ref, not a dependency: a card must not reload by itself
  // each time venue wifi drops and returns. These queries read every report.
  const online = useOnline();
  const onlineNow = useRef(online);
  useEffect(() => {
    onlineNow.current = online;
  });
`,
  ],
  [
    `  const load = useCallback((isCurrent: () => boolean) =>
    convex.query(
      makeFunctionReference<"query">(name) as Q,
      ...(JSON.parse(argsKey) as OptionalRestArgs<Q>),
    )
      .then((result) => {
        if (!isCurrent()) return;
`,
    `  const load = useCallback((isCurrent: () => boolean) => {
    const saved = cacheKey(name, (JSON.parse(argsKey) as unknown[])[0]);
    if (!onlineNow.current) {
      // Offline: the copy saved the last time this card loaded, if there is one.
      return Promise.resolve().then(() => {
        if (!isCurrent()) return;
        const cached = saved === null ? undefined : readCached(saved);
        if (cached) {
          setData(cached.result as FunctionReturnType<Q>);
          setUpdatedAt(cached.savedAt);
        }
        setLoading(false);
      });
    }
    return convex.query(
      makeFunctionReference<"query">(name) as Q,
      ...(JSON.parse(argsKey) as OptionalRestArgs<Q>),
    )
      .then((result) => {
        if (saved !== null) saveResult(name, saved, result);
        if (!isCurrent()) return;
`,
  ],
  [
    "      .finally(() => {\n        if (isCurrent()) setLoading(false);\n      }), [convex, name, argsKey]);\n",
    "      .finally(() => {\n        if (isCurrent()) setLoading(false);\n      });\n  }, [convex, name, argsKey]);\n",
  ],
]);

// ---- Team views -------------------------------------------------------------
bring("src/routes/teams/index.tsx", { cached: 2 });
bring("src/routes/teams/compare.tsx", { cached: 2 });
bring("src/routes/teams/plot.tsx", { cached: 4 });
bring("src/routes/teams/team-detail.tsx", { cached: 3 });
bring("src/routes/matches/preview.tsx", { cached: 2 });
bring("src/routes/notes/team-detail.tsx", { cached: 1 });
bring("src/routes/notes/match.tsx", { cached: 1 });
bring("src/lib/ranks.ts", { cached: 1 });
bring("src/lib/stat-site.ts", { cached: 3 });

// ---- "Loading…" everywhere else -----------------------------------------------
function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? walk(join(dir, entry.name)) : [join(dir, entry.name).replace(/\\/g, "/")],
  );
}
for (const path of walk("src/routes").filter((p) => p.endsWith(".tsx")).sort()) {
  if (current(path).includes(">Loading…</p>")) loadingText(path);
}

// PageShell: the heading version of the same thing.
edit("src/routes/page-shell.tsx", "NOT_SAVED", [
  [
    'import type { ReactNode } from "react";\n',
    'import type { ReactNode } from "react";\n\nimport { NOT_SAVED } from "@/components/loading-text";\nimport { useOnline } from "@/lib/offline/status";\n',
  ],
  [
    '}) {\n  return (\n    <div className="space-y-6">\n',
    `}) {
  // Offline, a page still "Loading…" has nothing on its way: say so.
  const online = useOnline();
  const shownTitle = !online && title === "Loading…" ? "Offline" : title;
  const shownDescription = !online && (description === "Loading…" || title === "Loading…")
    ? NOT_SAVED
    : description;
  return (
    <div className="space-y-6">
`,
  ],
  ["            {title}\n", "            {shownTitle}\n"],
  [
    '          {description ? (\n            <p className="text-muted-foreground mt-1 text-sm">{description}</p>\n',
    '          {shownDescription ? (\n            <p className="text-muted-foreground mt-1 text-sm">{shownDescription}</p>\n',
  ],
]);

// ---- The notice ---------------------------------------------------------------
edit("src/routes/app-layout.tsx", "ViewOnlyNotice", [
  [
    'import { PracticeBanner } from "@/components/practice-banner";\n',
    'import { PracticeBanner } from "@/components/practice-banner";\nimport { ViewOnlyNotice } from "@/components/view-only-notice";\n',
  ],
  ["        <OfflineBanner />\n", "        <OfflineBanner />\n        <ViewOnlyNotice />\n"],
]);

let changed = 0;
for (const [path, { before, next }] of [...plan].sort(([a], [b]) => a.localeCompare(b))) {
  if (before === next) {
    console.log(`  already patched  ${path}`);
    continue;
  }
  changed += 1;
  if (mode === "write") {
    writeFileSync(path, next);
    console.log(`  patched          ${path}`);
  } else console.log(`  ok               ${path}`);
}
if (changed === 0) console.log("  nothing to do");
MJS
bun .patch-offline-readonly.mjs check || { echo "ERROR: nothing was changed" >&2; exit 1; }

# ---- 2. New files ----------------------------------------------------------
say "Write guard, loading text, view-only notice"
cat > src/lib/offline/use-online-mutation.ts <<'EOF_FILE'
import { useAction, useMutation } from "convex/react";
import type { FunctionReference, FunctionReturnType, OptionalRestArgs } from "convex/server";
import { useCallback } from "react";

import { useOnline } from "./status";

export const VIEW_ONLY_MESSAGE = "You are offline. This page is view only until you reconnect.";

/**
 * A rejection the caller may or may not handle. Most callers show the error
 * in a toast; a few fire and forget, and for those this must not surface as
 * an unhandled rejection.
 */
function refuse<T>(): Promise<T> {
  const refused = Promise.reject<T>(new Error(VIEW_ONLY_MESSAGE));
  refused.catch(() => {});
  return refused;
}

/**
 * useMutation for pages that are view only offline (offline plan, O-7): pick
 * lists, Admin, attention items. With a connection it is useMutation. Without
 * one the call is refused at once instead of being queued, so nothing on
 * these pages can change while the scout cannot see the result.
 *
 * Scouting forms do NOT use this. Their reports are meant to be held and sent
 * later (src/lib/offline/held.ts).
 */
export function useOnlineMutation<Mutation extends FunctionReference<"mutation">>(
  mutation: Mutation,
): (...args: OptionalRestArgs<Mutation>) => Promise<FunctionReturnType<Mutation>> {
  const run = useMutation(mutation);
  const online = useOnline();
  return useCallback(
    (...args: OptionalRestArgs<Mutation>) => (online ? run(...args) : refuse()),
    [online, run],
  );
}

/** useAction, refused offline in the same way. */
export function useOnlineAction<Action extends FunctionReference<"action">>(
  action: Action,
): (...args: OptionalRestArgs<Action>) => Promise<FunctionReturnType<Action>> {
  const run = useAction(action);
  const online = useOnline();
  return useCallback(
    (...args: OptionalRestArgs<Action>) => (online ? run(...args) : refuse()),
    [online, run],
  );
}
EOF_FILE
echo "  wrote            src/lib/offline/use-online-mutation.ts"
cat > src/components/loading-text.tsx <<'EOF_FILE'
import { useOnline } from "@/lib/offline/status";

export const NOT_SAVED = "Not saved on this device. Reconnect to load it.";

/**
 * "Loading…" while there is a connection. Without one, nothing is on its way:
 * a page that reaches this has no saved copy to show, and says so instead of
 * looking like it is still trying.
 */
export function LoadingText() {
  const online = useOnline();
  return <>{online ? "Loading…" : NOT_SAVED}</>;
}
EOF_FILE
echo "  wrote            src/components/loading-text.tsx"
cat > src/components/view-only-notice.tsx <<'EOF_FILE'
import { Eye } from "lucide-react";
import { useLocation } from "react-router";

import { useOnline } from "@/lib/offline/status";

/** Pages that can be read offline but not changed (offline plan, O-7). */
const VIEW_ONLY = /^\/(picklists|admin)(\/|$)/;

/**
 * Under the offline banner on pick lists and Admin: what is on screen is the
 * last copy this device loaded, and every control that would change it is
 * turned off until the connection returns.
 */
export function ViewOnlyNotice() {
  const online = useOnline();
  const { pathname } = useLocation();
  if (online || !VIEW_ONLY.test(pathname)) return null;
  return (
    <div
      role="status"
      className="bg-muted text-muted-foreground flex items-center justify-center gap-2 border-b px-4 py-1.5 text-center text-xs"
    >
      <Eye className="size-3.5 shrink-0" aria-hidden />
      <span>View only while offline. Changes are turned off until you reconnect.</span>
    </div>
  );
}
EOF_FILE
echo "  wrote            src/components/view-only-notice.tsx"

# ---- 3. Edits --------------------------------------------------------------
say "Pick lists, Admin, team views"
bun .patch-offline-readonly.mjs write

say "Done"
cat <<'TXT'
Next:
  1. bun run typecheck && bun run lint && bun run build
  2. Against a production build (bunx vite preview, or a Vercel preview),
     signed in as an admin:
     a. Online, open: Pick Lists, one pick list board, Admin (let the cards
        load), Admin > Merge, a team's detail, Compare and the Data plot.
     b. DevTools > Network > Offline, reload.
     c. Each page from (a) shows what it showed, with "View only while
        offline" on Pick Lists and Admin.
     d. On the board: cards do not drag and the "Read only" badge shows.
     e. On Admin: press something that writes (a role, Import, Delete).
        It reports "You are offline. This page is view only until you
        reconnect." and nothing is queued.
     f. Open a team or a board you did NOT open in (a): it says "Not saved
        on this device".
     g. Back online: everything is live and editable again. Admin cards
        show their saved copy until you press Refresh.
TXT
