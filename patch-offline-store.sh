#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-offline-store.sh — offline plan, patch 2 of 5: cached reads
#   1. src/lib/offline/store.ts — the last result of each listed query, kept
#      on the device in IndexedDB. Keyed by user, dropped when the active
#      event or the user changes, emptied when CACHE_VERSION changes.
#   2. src/lib/offline/status.ts — useOnline(), the single answer to "is
#      there a connection". Trusts the Convex socket, not navigator.onLine
#      alone, so wifi that is joined but passes no traffic counts as offline
#      (after a 3 second grace).
#   3. src/lib/offline/use-cached-query.ts — drop-in for useQuery. A live
#      result always wins; the cached copy is returned only when offline.
#   4. <OfflineBanner> under the nav: "Offline. Showing data as of ...".
#      <ConnectionIndicator> now reads useOnline().
#   5. The dashboard, the scouting and pit landings, Matches, Teams and the
#      other-season equivalents read their lists through useCachedQuery.
#   6. AGENTS.md: the one named exception to "never copy a query result".
#
# What you can see after this patch: with the app open and signed in, lose
# the connection and move between Dashboard, Match Scouting, Pit Scouting,
# Matches and Teams. They show their last data with the banner. A cold start
# with no connection still stops at the auth spinner; that is patch 3.
#
# No Convex change, no new function calls, no schema change, no new
# dependency. Does not depend on patch-pwa.sh. Safe to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f vite.config.ts && -f convex/auth.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# ---- 1. Check every anchor before writing anything ------------------------
say "Checking anchors"
if grep -q "useOnline" src/components/connection-indicator.tsx; then
  echo "  already patched  src/components/connection-indicator.tsx"
elif grep -q "navigator.onLine" src/components/connection-indicator.tsx; then
  echo "  ok               src/components/connection-indicator.tsx"
else
  echo "ERROR: src/components/connection-indicator.tsx is not the file this patch expects; nothing was changed" >&2
  exit 1
fi
trap 'rm -f .patch-offline-store.mjs' EXIT
cat > .patch-offline-store.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";

const mode = process.argv[2]; // "check" | "write"
const HOOK_IMPORT = 'import { useCachedQuery } from "@/lib/offline/use-cached-query";\n';
const plan = [];

const read = (path) => readFileSync(path, "utf8").replace(/\r\n/g, "\n");

function once(path, source, anchor) {
  const count = source.split(anchor).length - 1;
  if (count !== 1) throw new Error(`${path}: expected anchor once, found ${count}:\n  ${anchor}`);
}

/**
 * Switch the listed `useQuery(api.x.y` calls in one file to useCachedQuery.
 * `calls` maps the exact call text to how many times it must appear.
 */
function switchCalls(path, calls) {
  let source = read(path);
  if (source.includes("useCachedQuery")) return plan.push({ path, skip: true });
  for (const [call, expected] of Object.entries(calls)) {
    const anchor = `useQuery(${call}`;
    const count = source.split(anchor).length - 1;
    if (count !== expected) {
      throw new Error(`${path}: expected ${expected} of "${anchor}", found ${count}`);
    }
    source = source.split(anchor).join(`useCachedQuery(${call}`);
  }
  // Drop useQuery from the convex/react import when nothing uses it any more.
  if (!/\buseQuery\(/.test(source)) {
    const importLine = /^import \{([^}]*)\} from "convex\/react";\n/m;
    const match = source.match(importLine);
    if (!match) throw new Error(`${path}: no convex/react import found`);
    const names = match[1].split(",").map((n) => n.trim()).filter((n) => n && n !== "useQuery");
    source = source.replace(
      importLine,
      names.length ? `import { ${names.join(", ")} } from "convex/react";\n` : "",
    );
  }
  // The hook import goes right after the generated-api import every page has.
  const apiImport = source.match(/^import \{ api \} from "[./]+\/convex\/_generated\/api";\n/m);
  if (!apiImport) throw new Error(`${path}: no convex/_generated/api import found`);
  once(path, source, apiImport[0]);
  source = source.replace(apiImport[0], apiImport[0] + HOOK_IMPORT);
  plan.push({ path, skip: false, next: source });
}

function edit(path, marker, pairs) {
  let source = read(path);
  if (source.includes(marker)) return plan.push({ path, skip: true });
  for (const [anchor] of pairs) once(path, source, anchor);
  for (const [anchor, replacement] of pairs) source = source.replace(anchor, replacement);
  plan.push({ path, skip: false, next: source });
}

// ---- Tier 1 call sites (offline plan, section 6.3) --------------------------
switchCalls("src/components/season-provider.tsx", { "api.events.active)": 1 });
switchCalls("src/components/app-nav.tsx", { "api.profiles.me)": 1 });
switchCalls("src/routes/dashboard.tsx", {
  "api.events.active)": 1,
  "api.teams.listWithStatus)": 1,
  "api.matches.listForEvent)": 1,
  "api.assignments.mine)": 1,
  "api.stats.matchCoverage)": 1,
});
switchCalls("src/routes/scout/index.tsx", {
  "api.matches.listForEvent)": 1,
  "api.matchReports.mine)": 1,
  "api.assignments.mine)": 1,
});
switchCalls("src/routes/pit/index.tsx", { "api.teams.listWithStatus)": 1 });
switchCalls("src/routes/matches/index.tsx", { "api.matches.listForEvent)": 1 });
switchCalls("src/routes/teams/index.tsx", { "api.teams.listWithStatus)": 1 });
switchCalls("src/routes/notes/dashboard.tsx", {
  "api.notes.progress)": 1,
  "api.matches.listForEvent)": 1,
  "api.notes.assignments)": 1,
});
switchCalls("src/routes/notes/scout.tsx", {
  "api.matches.listForEvent)": 1,
  "api.notes.mine)": 1,
  "api.notes.assignments)": 1,
});
switchCalls("src/routes/notes/pit.tsx", { "api.notes.teams)": 1 });
switchCalls("src/routes/notes/teams.tsx", { "api.notes.teams)": 1 });

// ---- Wiring -----------------------------------------------------------------
edit("src/providers/app-providers.tsx", "OfflineProvider", [
  [
    'import { ThemeProvider } from "next-themes";\n',
    'import { ThemeProvider } from "next-themes";\n\nimport { OfflineProvider } from "@/lib/offline/offline-provider";\n',
  ],
  [
    "      <ConvexAuthProvider client={convex}>{children}</ConvexAuthProvider>\n",
    "      <ConvexAuthProvider client={convex}>\n        <OfflineProvider>{children}</OfflineProvider>\n      </ConvexAuthProvider>\n",
  ],
]);

edit("src/routes/app-layout.tsx", "OfflineBanner", [
  [
    'import { AppNav } from "@/components/app-nav";\n',
    'import { AppNav } from "@/components/app-nav";\nimport { OfflineBanner } from "@/components/offline-banner";\n',
  ],
  ["        <AppNav />\n", "        <AppNav />\n        <OfflineBanner />\n"],
]);

edit("AGENTS.md", "src/lib/offline/", [
  [
    "- Never copy a Convex query result into Zustand.\n",
    `- Never copy a Convex query result into Zustand.
- One named exception to "never copy a query result": the offline store in
  \`src/lib/offline/\` keeps the latest result of listed queries in IndexedDB
  so pages can show them with no connection. Read through \`useCachedQuery\`,
  which returns the live result whenever there is one. Never read the store
  from a page, never put a cached result in Zustand, and bump
  \`CACHE_VERSION\` in \`store.ts\` when a cached query's return shape changes.
`,
  ],
]);

for (const e of plan) {
  if (e.skip) console.log(`  already patched  ${e.path}`);
  else if (mode === "write") {
    writeFileSync(e.path, e.next);
    console.log(`  patched          ${e.path}`);
  } else console.log(`  ok               ${e.path}`);
}
MJS
bun .patch-offline-store.mjs check || { echo "ERROR: nothing was changed" >&2; exit 1; }

# ---- 2. New files ----------------------------------------------------------
say "Offline store, status, hook, banner"
mkdir -p src/lib/offline
cat > src/lib/offline/store.ts <<'EOF_FILE'
/**
 * The offline store: the last result of each cached Convex query, kept on the
 * device in IndexedDB so pages can show it with no connection.
 *
 * This is the one named exception to "never copy a Convex query result" in
 * AGENTS.md. Pages never read it directly; they call useCachedQuery, which
 * returns the live result whenever there is one.
 *
 * Rules (offline plan, sections 1 and 6):
 *  - A copy only. Nothing here is ever sent back to Convex.
 *  - One person on one device. Rows are keyed by user and dropped when a
 *    different user is confirmed, or on clearOfflineData().
 *  - Scouting queries take no event argument: the server resolves the
 *    caller's team's active event. Every event-scoped row therefore records
 *    the event it was saved under and is dropped when that event changes.
 *  - Bump CACHE_VERSION in the same patch as any change to the return shape
 *    of a cached query. A mismatch empties the store.
 *
 * If IndexedDB cannot be opened (private browsing, storage blocked) the store
 * still works in memory for the life of the tab and the app behaves as it
 * did before this file existed.
 */

export const CACHE_VERSION = 1;

const DB_NAME = "circuitscout-offline";
const DB_VERSION = 1;
const QUERIES = "queries";
const META = "meta";
const OPEN_TIMEOUT_MS = 1500;
const FLUSH_DELAY_MS = 400;

/** Results that are the same whichever event is active. */
const EVENT_INDEPENDENT = new Set(["profiles:me", "events:active"]);

type Row = {
  /** `${userId}|${fn}|${args}` */
  key: string;
  userId: string;
  fn: string;
  result: unknown;
  savedAt: number;
  /** null for event-independent rows and for "no active event". */
  eventId: string | null;
  eventScoped: boolean;
};

export type CachedResult = { result: unknown; savedAt: number };
type MemoryEntry = CachedResult & { fn: string };
type Session = { userId: string; confirmedAt: number };

let db: IDBDatabase | null = null;
let opening: Promise<void> | null = null;
let ready = false;
let epoch = 0;

/** Whose rows are in memory. Known at startup from the last session. */
let userId: string | null = null;
/** True once the server has confirmed `userId` in this session. */
let userConfirmed = false;
/** The active event as the server last reported it this session. */
let eventId: string | null | undefined;
/** The active event recorded by an earlier session. */
let storedEventId: string | null | undefined;

const memory = new Map<string, MemoryEntry>();
const pending = new Map<string, { fn: string; result: unknown }>();
let flushTimer: ReturnType<typeof setTimeout> | undefined;

const listeners = new Set<() => void>();

function bump() {
  epoch += 1;
  for (const listener of listeners) listener();
}

/** For useSyncExternalStore. The epoch changes whenever cached rows may have. */
export function subscribeStore(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
export const storeEpoch = (): number => epoch;
export const isStoreReady = (): boolean => ready;

// ---- IndexedDB plumbing ----------------------------------------------------

function settled<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("IndexedDB request failed"));
  });
}

function finished(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error ?? new Error("IndexedDB transaction failed"));
    tx.onabort = () => reject(tx.error ?? new Error("IndexedDB transaction aborted"));
  });
}

function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    if (typeof indexedDB === "undefined") {
      reject(new Error("IndexedDB is not available"));
      return;
    }
    const timer = setTimeout(() => reject(new Error("IndexedDB open timed out")), OPEN_TIMEOUT_MS);
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(QUERIES)) {
        database.createObjectStore(QUERIES, { keyPath: "key" }).createIndex("userId", "userId");
      }
      if (!database.objectStoreNames.contains(META)) {
        database.createObjectStore(META, { keyPath: "name" });
      }
    };
    request.onsuccess = () => {
      clearTimeout(timer);
      resolve(request.result);
    };
    request.onerror = () => {
      clearTimeout(timer);
      reject(request.error ?? new Error("IndexedDB open failed"));
    };
    request.onblocked = () => {
      clearTimeout(timer);
      reject(new Error("IndexedDB open blocked"));
    };
  });
}

async function readMeta<T>(database: IDBDatabase, name: string): Promise<T | undefined> {
  const row = (await settled(database.transaction(META).objectStore(META).get(name))) as
    | { name: string; value: T }
    | undefined;
  return row?.value;
}

/** Best effort: a failed write costs a cached copy, never the app. */
function write(stores: string[], work: (tx: IDBTransaction) => void) {
  if (!db) return;
  try {
    const tx = db.transaction(stores, "readwrite");
    work(tx);
    finished(tx).catch(() => {});
  } catch {
    // The connection was closed or the quota is gone. Memory still serves this tab.
  }
}

function writeMeta(name: string, value: unknown) {
  write([META], (tx) => tx.objectStore(META).put({ name, value }));
}

// ---- Opening ---------------------------------------------------------------

/**
 * Opens the store and loads the last signed-in user's rows into memory, so
 * that reads during render are synchronous. Never rejects. Safe to call more
 * than once.
 */
export function openStore(): Promise<void> {
  opening ??= open();
  return opening;
}

async function open(): Promise<void> {
  try {
    const database = await openDatabase();
    const version = await readMeta<number>(database, "cacheVersion");
    if (version !== CACHE_VERSION) {
      // The shape of a cached result may have changed. Start empty.
      const tx = database.transaction([QUERIES, META], "readwrite");
      tx.objectStore(QUERIES).clear();
      tx.objectStore(META).put({ name: "cacheVersion", value: CACHE_VERSION });
      await finished(tx);
    }
    const session = await readMeta<Session>(database, "session");
    storedEventId = await readMeta<string | null>(database, "activeEventId");
    if (session) {
      const rows = (await settled(
        database.transaction(QUERIES).objectStore(QUERIES).index("userId").getAll(session.userId),
      )) as Row[];
      userId = session.userId;
      const prefix = `${session.userId}|`;
      for (const row of rows) {
        memory.set(row.key.slice(prefix.length), {
          fn: row.fn, result: row.result, savedAt: row.savedAt,
        });
      }
    }
    db = database;
    database.onversionchange = () => {
      database.close();
      db = null;
    };
  } catch {
    db = null;
  }
  if (typeof document !== "undefined") {
    // A phone going into a pocket: write what is waiting before the tab is frozen.
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "hidden") flush();
    });
  }
  ready = true;
  bump();
  scheduleFlush();
}

// ---- Identity and event ----------------------------------------------------

/**
 * The server has confirmed who is signed in. Nothing is written to the device
 * before this has been called in the current session.
 */
export function confirmUser(id: string) {
  if (!ready) {
    void openStore().then(() => confirmUser(id));
    return;
  }
  if (id === userId && userConfirmed) return;
  // Results queued before the first confirmation belong to this user: they
  // arrived in this session. Only a previous, different user is wiped.
  const switched = userId !== null && id !== userId;
  userId = id;
  userConfirmed = true;
  if (switched) {
    // A different person on this device: the previous user's copy goes.
    memory.clear();
    pending.clear();
    eventId = undefined;
    storedEventId = undefined;
    write([QUERIES, META], (tx) => {
      tx.objectStore(QUERIES).clear();
      tx.objectStore(META).delete("activeEventId");
    });
  }
  writeMeta("session", { userId: id, confirmedAt: Date.now() } satisfies Session);
  // Mounted hooks save their current live results again under this user.
  bump();
  scheduleFlush();
}

/**
 * The server has reported the caller's team's active event (null: none).
 * Rows saved under any other event are dropped.
 */
export function setActiveEvent(id: string | null) {
  if (!ready) {
    void openStore().then(() => setActiveEvent(id));
    return;
  }
  const previous = eventId !== undefined ? eventId : storedEventId;
  if (eventId === id) return;
  eventId = id;
  storedEventId = id;
  if (previous !== undefined && previous !== id) {
    for (const [key, entry] of memory) {
      if (!EVENT_INDEPENDENT.has(entry.fn)) memory.delete(key);
    }
    for (const [key, entry] of pending) {
      if (!EVENT_INDEPENDENT.has(entry.fn)) pending.delete(key);
    }
    write([QUERIES], (tx) => {
      const store = tx.objectStore(QUERIES);
      const cursor = store.openCursor();
      cursor.onsuccess = () => {
        const at = cursor.result;
        if (!at) return;
        const row = at.value as Row;
        if (row.eventScoped && row.eventId !== id) at.delete();
        at.continue();
      };
    });
  }
  writeMeta("activeEventId", id);
  bump();
  scheduleFlush();
}

/** Sign-out: everything about this user leaves the device. */
export function clearOfflineData() {
  if (!ready) {
    void openStore().then(() => clearOfflineData());
    return;
  }
  memory.clear();
  pending.clear();
  userId = null;
  userConfirmed = false;
  eventId = undefined;
  storedEventId = undefined;
  write([QUERIES, META], (tx) => {
    tx.objectStore(QUERIES).clear();
    tx.objectStore(META).delete("session");
    tx.objectStore(META).delete("activeEventId");
  });
  bump();
}

// ---- Reading and saving ----------------------------------------------------

/**
 * Stable key for one query call, or null when the arguments cannot be turned
 * into one (the call is then simply not cached).
 */
export function cacheKey(fn: string, args: unknown): string | null {
  try {
    return `${fn}|${stableJson(args ?? {})}`;
  } catch {
    return null;
  }
}

function stableJson(value: unknown): string {
  if (value === null || typeof value !== "object") {
    if (typeof value === "bigint") throw new Error("bigint argument");
    return JSON.stringify(value) ?? "null";
  }
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (Object.getPrototypeOf(value) !== Object.prototype) throw new Error("non-plain argument");
  const record = value as Record<string, unknown>;
  const parts = Object.keys(record)
    .filter((k) => record[k] !== undefined)
    .sort()
    .map((k) => `${JSON.stringify(k)}:${stableJson(record[k])}`);
  return `{${parts.join(",")}}`;
}

/** Synchronous, for use during render. */
export function readCached(key: string): CachedResult | undefined {
  return memory.get(key);
}

/** Queue a live result to be saved. Cheap; call it on every change. */
export function saveResult(fn: string, key: string, result: unknown) {
  pending.set(key, { fn, result });
  scheduleFlush();
}

function scheduleFlush() {
  if (flushTimer !== undefined || pending.size === 0) return;
  flushTimer = setTimeout(flush, FLUSH_DELAY_MS);
}

function flush() {
  if (flushTimer !== undefined) clearTimeout(flushTimer);
  flushTimer = undefined;
  // Wait for the server to say who this is. confirmUser() schedules again.
  if (!ready || !userConfirmed || userId === null) return;

  const rows: Row[] = [];
  const savedAt = Date.now();
  for (const [key, entry] of pending) {
    const eventScoped = !EVENT_INDEPENDENT.has(entry.fn);
    // Wait for the server to say which event this is. setActiveEvent() schedules again.
    if (eventScoped && eventId === undefined) continue;
    pending.delete(key);
    memory.set(key, { fn: entry.fn, result: entry.result, savedAt });
    rows.push({
      key: `${userId}|${key}`,
      userId,
      fn: entry.fn,
      result: entry.result,
      savedAt,
      eventId: eventScoped ? (eventId ?? null) : null,
      eventScoped,
    });
  }
  if (rows.length === 0) return;
  write([QUERIES], (tx) => {
    const store = tx.objectStore(QUERIES);
    for (const row of rows) {
      try {
        store.put(row);
      } catch {
        // A result that cannot be cloned is skipped; memory still has it.
      }
    }
  });
}

// ---- What the page is currently showing from the cache ---------------------

const served = new Map<symbol, number>();
const servedListeners = new Set<() => void>();
let oldest: number | null = null;

function recomputeOldest() {
  let next: number | null = null;
  for (const at of served.values()) if (next === null || at < next) next = at;
  if (next === oldest) return;
  oldest = next;
  for (const listener of servedListeners) listener();
}

/** A hook is showing a cached result saved at `savedAt`. Returns the undo. */
export function markServed(savedAt: number): () => void {
  const id = Symbol("served");
  served.set(id, savedAt);
  recomputeOldest();
  return () => {
    served.delete(id);
    recomputeOldest();
  };
}

export function subscribeServed(listener: () => void): () => void {
  servedListeners.add(listener);
  return () => servedListeners.delete(listener);
}

/** The age of the oldest cached result on screen, or null when none is. */
export const oldestServed = (): number | null => oldest;
EOF_FILE
echo "  wrote            src/lib/offline/store.ts"
cat > src/lib/offline/status.ts <<'EOF_FILE'
import { createContext, useContext } from "react";

/**
 * The single answer to "is there a connection". Every offline decision in the
 * app reads this, so the badge, the banner and the cache can never disagree.
 */
export const OnlineContext = createContext(true);

/** True while Convex is reachable. Provided by <OfflineProvider>. */
export const useOnline = (): boolean => useContext(OnlineContext);

type ConnectionSource = {
  connectionState(): { isWebSocketConnected: boolean };
  subscribeToConnectionState(cb: (state: { isWebSocketConnected: boolean }) => void): () => void;
};

/** How long a dropped socket is given to come back before the app says Offline. */
export const SOCKET_GRACE_MS = 3000;

/**
 * Watches the browser's online flag and the Convex websocket.
 *
 * `navigator.onLine` only says a network is joined, not that it passes
 * traffic, and venue wifi is often the first without the second. So:
 *  - browser says offline            -> offline, at once
 *  - socket connected                -> online
 *  - browser says online, socket down -> online for a short grace, then offline
 * The grace also covers the first moments after launch, before the socket has
 * had a chance to connect.
 */
export function createConnectionMonitor(source: ConnectionSource, graceMs = SOCKET_GRACE_MS) {
  let browserOnline = typeof navigator === "undefined" ? true : navigator.onLine;
  let socketUp = false;
  let online = browserOnline;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const listeners = new Set<() => void>();

  const set = (next: boolean) => {
    if (next === online) return;
    online = next;
    for (const listener of listeners) listener();
  };

  const settle = () => {
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
    if (!browserOnline) return set(false);
    if (socketUp) return set(true);
    if (!online) return;
    timer = setTimeout(() => {
      timer = undefined;
      set(false);
    }, graceMs);
  };

  return {
    isOnline: () => online,
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    /** Starts watching. Returns the stop function. */
    start() {
      const onBrowser = () => {
        browserOnline = navigator.onLine;
        settle();
      };
      window.addEventListener("online", onBrowser);
      window.addEventListener("offline", onBrowser);
      socketUp = source.connectionState().isWebSocketConnected;
      const unsubscribe = source.subscribeToConnectionState((state) => {
        socketUp = state.isWebSocketConnected;
        settle();
      });
      onBrowser();
      return () => {
        window.removeEventListener("online", onBrowser);
        window.removeEventListener("offline", onBrowser);
        unsubscribe();
        if (timer !== undefined) clearTimeout(timer);
        timer = undefined;
      };
    },
  };
}
EOF_FILE
echo "  wrote            src/lib/offline/status.ts"
cat > src/lib/offline/offline-provider.tsx <<'EOF_FILE'
import { useConvex, useConvexAuth, useQuery } from "convex/react";
import { useEffect, useState, useSyncExternalStore, type ReactNode } from "react";

import { api } from "../../../convex/_generated/api";
import { OnlineContext, createConnectionMonitor } from "./status";
import {
  confirmUser, isStoreReady, openStore, setActiveEvent, subscribeStore,
} from "./store";

/**
 * Mounted once, inside the Convex provider. Does three things:
 *  1. answers "is there a connection" for the whole app (useOnline);
 *  2. opens the offline store and holds the first render until the cached
 *     rows are in memory, so no page flashes a spinner before its cached copy;
 *  3. tells the store who is signed in and which event is active, as the
 *     server reports them. Both queries are already subscribed elsewhere
 *     (AppNav, SeasonProvider), and Convex shares one subscription between
 *     identical calls, so this adds no function calls.
 */
export function OfflineProvider({ children }: { children: ReactNode }) {
  const convex = useConvex();
  const [monitor] = useState(() => createConnectionMonitor(convex));
  useEffect(() => monitor.start(), [monitor]);
  const online = useSyncExternalStore(monitor.subscribe, monitor.isOnline);

  useEffect(() => {
    void openStore();
  }, []);
  const ready = useSyncExternalStore(subscribeStore, isStoreReady);

  const { isAuthenticated } = useConvexAuth();
  const profile = useQuery(api.profiles.me, isAuthenticated ? {} : "skip");
  const event = useQuery(api.events.active, isAuthenticated ? {} : "skip");
  const userId = profile?.userId;
  const eventId = event === undefined ? undefined : (event?._id ?? null);

  useEffect(() => {
    if (userId !== undefined) confirmUser(userId);
  }, [userId]);
  useEffect(() => {
    if (userId !== undefined && eventId !== undefined) setActiveEvent(eventId);
  }, [userId, eventId]);

  // IndexedDB opens in a few milliseconds, and openStore() gives up after 1.5 s.
  if (!ready) return null;
  return <OnlineContext.Provider value={online}>{children}</OnlineContext.Provider>;
}
EOF_FILE
echo "  wrote            src/lib/offline/offline-provider.tsx"
cat > src/lib/offline/use-cached-query.ts <<'EOF_FILE'
import { useQuery, type OptionalRestArgsOrSkip } from "convex/react";
import {
  getFunctionName, type FunctionReference, type FunctionReturnType,
} from "convex/server";
import { useEffect, useSyncExternalStore } from "react";

import { useOnline } from "./status";
import {
  cacheKey, markServed, readCached, saveResult, storeEpoch, subscribeStore,
} from "./store";

/**
 * Drop-in for useQuery that also keeps the latest result on the device.
 *
 *   online, result arrived   the live result (and it is saved)
 *   online, still loading    undefined, exactly as useQuery
 *   offline, copy on device  the copy; its age shows in <OfflineBanner>
 *   offline, no copy         undefined
 *
 * A live result always wins, so nothing changes while there is a connection.
 * Use it only for queries on the offline plan's list (section 6.3), and bump
 * CACHE_VERSION in store.ts when one of them changes its return shape.
 */
export function useCachedQuery<Query extends FunctionReference<"query">>(
  query: Query,
  ...args: OptionalRestArgsOrSkip<Query>
): FunctionReturnType<Query> | undefined {
  const live = useQuery(query, ...args);
  const online = useOnline();
  // Re-run the save below when the store has dropped rows (new user, new event).
  const epoch = useSyncExternalStore(subscribeStore, storeEpoch);

  // `api.x.y` is a new object on every access; the name is the stable part.
  const name = getFunctionName(query);
  const first: unknown = args[0];
  const key = first === "skip" ? null : cacheKey(name, first);

  useEffect(() => {
    if (key !== null && live !== undefined) saveResult(name, key, live);
  }, [name, key, live, epoch]);

  const cached = key !== null && live === undefined && !online ? readCached(key) : undefined;
  const servedAt = cached?.savedAt;
  useEffect(() => {
    if (servedAt === undefined) return;
    return markServed(servedAt);
  }, [servedAt]);

  if (live !== undefined || cached === undefined) return live;
  return cached.result as FunctionReturnType<Query>;
}
EOF_FILE
echo "  wrote            src/lib/offline/use-cached-query.ts"
cat > src/components/offline-banner.tsx <<'EOF_FILE'
import { useSyncExternalStore } from "react";
import { CloudOff } from "lucide-react";

import { useOnline } from "@/lib/offline/status";
import { oldestServed, subscribeServed } from "@/lib/offline/store";

const AS_OF = new Intl.DateTimeFormat(undefined, {
  month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
});

/**
 * Under the nav while there is no connection. Says how old the data on
 * screen is: the oldest cached result any query on the page is showing. A
 * clock time rather than "5 minutes ago", so it stays right without ticking.
 */
export function OfflineBanner() {
  const online = useOnline();
  const oldest = useSyncExternalStore(subscribeServed, oldestServed);
  if (online) return null;
  return (
    <div
      role="status"
      className="bg-destructive flex items-center justify-center gap-2 px-4 py-1.5 text-center text-xs font-medium text-white"
    >
      <CloudOff className="size-3.5 shrink-0" />
      <span>
        Offline.{" "}
        {oldest === null
          ? "New data will load when you reconnect."
          : `Showing data as of ${AS_OF.format(oldest)}.`}
      </span>
    </div>
  );
}
EOF_FILE
echo "  wrote            src/components/offline-banner.tsx"
cat > src/components/connection-indicator.tsx <<'EOF_FILE'
import { CloudOff, Cloud } from "lucide-react";

import { useOnline } from "@/lib/offline/status";

/**
 * Venue wifi is unreliable and Convex is websocket-backed. A scout must be
 * able to see they are offline BEFORE keying in six minutes of match data.
 *
 * Reads useOnline(), which trusts the Convex socket rather than
 * navigator.onLine alone: wifi that is joined but passes no traffic shows
 * Offline here, where it used to show Live.
 */
export function ConnectionIndicator() {
  const online = useOnline();

  if (online) {
    return (
      <span className="text-muted-foreground flex items-center gap-1.5 text-xs">
        <Cloud className="size-3.5" />
        <span className="hidden sm:inline">Live</span>
      </span>
    );
  }

  return (
    <span className="flex items-center gap-1.5 rounded-md bg-destructive px-2 py-1 text-xs font-medium text-white">
      <CloudOff className="size-3.5" />
      Offline
    </span>
  );
}
EOF_FILE
echo "  wrote            src/components/connection-indicator.tsx"

# ---- 3. Anchored edits -----------------------------------------------------
say "Wiring and call sites"
bun .patch-offline-store.mjs write

say "Done"
cat <<'TXT'
Next:
  1. bun run typecheck && bun run lint && bun run build
  2. bun run go, sign in, open the Dashboard. In DevTools > Application >
     IndexedDB > circuitscout-offline > queries there should be rows for
     profiles:me, events:active, matches:listForEvent, teams:listWithStatus
     and the others, all under your user id. Reload: they are still there.
  3. DevTools > Network > Offline. Within about 3 seconds the badge turns
     to Offline and the red banner appears. Move between Dashboard, Match
     Scouting, Pit Scouting, Matches and Teams: each shows its last data and
     the banner reads "Showing data as of <time>".
     Opening a match or pit form you have not opened before still shows
     Loading. That is patch 4.
  4. Back online: the banner goes, and everything is live again.
TXT
