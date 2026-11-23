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
/** Whose rows the store holds: the last user the server confirmed on this device. */
export const cachedUserId = (): string | null => userId;

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

// For UI that shows whether data is on the device (the Offline ready line).
// Separate from the epoch on purpose: hooks re-save on an epoch change, so
// bumping the epoch on every save would loop.
let tick = 0;
const savedListeners = new Set<() => void>();
export function subscribeSaved(listener: () => void): () => void {
  savedListeners.add(listener);
  return () => savedListeners.delete(listener);
}
export const savedTick = (): number => tick;

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
  tick += 1;
  for (const listener of savedListeners) listener();
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
