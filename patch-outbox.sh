#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-outbox.sh — data transfer plan, patch 7: the outbox
#   1. A report saved with no connection is written to the device (a new
#      "outbox" store in the existing circuitscout-offline database), so it
#      survives closing or reloading the app. Nothing is queued in the
#      Convex client any more.
#   2. When the connection returns and the server has confirmed the same
#      scout, the app asks once which held reports the server already has
#      (transfer.receipts), then sends the rest one at a time, oldest first
#      (transfer.send). The server writes each one once.
#   3. A report the server refuses stays in Waiting to send with the
#      server's reason, and gets Try again beside Dismiss.
#   4. Signing out with reports on the device asks first, with the count:
#      Cancel, or Sign out and discard (decision D-2).
#   5. A scout who signs in on a device holding another scout's unsent
#      reports sees a notice. Those reports are kept, hidden, never sent as
#      anyone else, and sent when their author signs in again (D-7).
#   6. The "closing the app loses them" wording and the browser's leave-page
#      prompt are gone. They return only on a device that will not store the
#      reports (private browsing, storage blocked).
#
# Saves made online are unchanged (D-8).
#
# Requires patch 6 (patch-transfer-server.sh), pushed to Convex first: this
# patch calls transfer.send and transfer.receipts.
# Client only: no Convex change, no new dependency. Safe to re-run.
#
# The device database goes from version 1 to 2. The cached queries are kept.
# A tab still running the previous bundle cannot open version 2: it keeps
# working from memory, as it did before the offline store existed, until the
# update prompt reloads it.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f vite.config.ts && -f convex/auth.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
[[ -f src/lib/offline/held.ts && -f src/components/held.tsx && -f src/lib/offline/use-online-mutation.ts ]] || {
  echo "ERROR: run the offline patches first (through patch-offline-readonly.sh); nothing was changed" >&2; exit 1; }
[[ -f convex/transfer.ts && -f convex/lib/transfer.ts ]] || {
  echo "ERROR: run patch-transfer-server.sh first; nothing was changed" >&2; exit 1; }
grep -q 'import type \* as transfer from' convex/_generated/api.d.ts || {
  echo "ERROR: convex/_generated/api.d.ts does not list transfer. Run 'bun run go' once, then this patch; nothing was changed" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# ---- 1. Check everything before writing anything --------------------------
say "Checking"
trap 'rm -f .patch-outbox.mjs .patch-outbox.json' EXIT
cat > .patch-outbox.json <<'EOF_JSON'
{
 "edited": {
  "src/lib/offline/store.ts": {
   "marker": "export async function outboxChange(",
   "edits": [
    {
     "old": " *  - A copy only. Nothing here is ever sent back to Convex.",
     "new": " *  - The cached queries are a copy only, and are never sent back to Convex.\n *  - The same database also holds the outbox: reports saved with no\n *    connection, waiting to be sent (data transfer plan, section 3). This\n *    file only stores those rows; src/lib/offline/held.ts owns what they\n *    mean. Unlike the cached queries, outbox rows are not dropped when a\n *    different user signs in or the cache version changes."
    },
    {
     "old": "const DB_VERSION = 1;",
     "new": "// 2 added the outbox store. Raising this never empties the other stores.\nconst DB_VERSION = 2;"
    },
    {
     "old": "const META = \"meta\";\nconst OPEN_TIMEOUT_MS = 1500;",
     "new": "const META = \"meta\";\nconst OUTBOX = \"outbox\";\nconst OPEN_TIMEOUT_MS = 1500;"
    },
    {
     "old": "      }\n    };",
     "new": "      }\n      if (!database.objectStoreNames.contains(OUTBOX)) {\n        database.createObjectStore(OUTBOX, { keyPath: \"id\" }).createIndex(\"userId\", \"userId\");\n      }\n    };"
    },
    {
     "old": "    }\n    db = database;",
     "new": "    }\n    outboxAtOpen = (await settled(\n      database.transaction(OUTBOX).objectStore(OUTBOX).getAll(),\n    )) as unknown[];\n    db = database;"
    },
    {
     "old": "  writeMeta(\"activeEventId\", id);\n  bump();\n  scheduleFlush();\n}\n\n/** Sign-out: everything about this user leaves the device. */",
     "new": "  writeMeta(\"activeEventId\", id);\n  bump();\n  scheduleFlush();\n}\n\n/**\n * The active event as last reported by the server, in this session or an\n * earlier one. undefined: never reported on this device. null: no event.\n */\nexport const knownEventId = (): string | null | undefined =>\n  eventId !== undefined ? eventId : storedEventId;\n\n// ---- The outbox ------------------------------------------------------------\n\nlet outboxAtOpen: unknown[] = [];\n\n/** Every outbox row that was on the device when the store opened. */\nexport const outboxRowsAtOpen = (): unknown[] => outboxAtOpen;\n\n/** False when IndexedDB could not be opened: rows then live in this tab only. */\nexport const outboxIsDurable = (): boolean => db !== null;\n\n/** Every outbox row on the device now, or null when it cannot be read. */\nexport async function outboxReadAll(): Promise<unknown[] | null> {\n  if (!db) return null;\n  try {\n    return (await settled(db.transaction(OUTBOX).objectStore(OUTBOX).getAll())) as unknown[];\n  } catch {\n    return null;\n  }\n}\n\n/**\n * Writes rows and removes ids in one transaction. Resolves true once they\n * are on the device; false means they are held in this tab's memory only.\n */\nexport async function outboxChange(put: ReadonlyArray<{ id: string }>, remove: ReadonlyArray<string>): Promise<boolean> {\n  if (!db) return false;\n  try {\n    const tx = db.transaction([OUTBOX], \"readwrite\");\n    const store = tx.objectStore(OUTBOX);\n    for (const id of remove) store.delete(id);\n    for (const row of put) store.put(row);\n    await finished(tx);\n    return true;\n  } catch {\n    return false;\n  }\n}\n\n/** Sign-out: everything about this user leaves the device. */"
    }
   ]
  },
  "src/lib/offline/offline-provider.tsx": {
   "marker": "startSending(sender, userId)",
   "edits": [
    {
     "old": "import { useEffect, useState, useSyncExternalStore, type ReactNode } from \"react\";",
     "new": "import { useEffect, useMemo, useState, useSyncExternalStore, type ReactNode } from \"react\";"
    },
    {
     "old": "import { api } from \"../../../convex/_generated/api\";\nimport { OnlineContext, createConnectionMonitor } from \"./status\";",
     "new": "import { api } from \"../../../convex/_generated/api\";\nimport { startSending, stopSending, type Sender } from \"./held\";\nimport { OnlineContext, createConnectionMonitor } from \"./status\";"
    },
    {
     "old": " * Mounted once, inside the Convex provider. Does three things:",
     "new": " * Mounted once, inside the Convex provider. Does four things:"
    },
    {
     "old": " *     identical calls, so this adds no function calls.",
     "new": " *     identical calls, so this adds no function calls;\n *  4. sends the reports held on this device (held.ts) while there is a\n *     connection and the server has confirmed who is signed in."
    },
    {
     "old": "\n  // IndexedDB opens in a few milliseconds, and openStore() gives up after 1.5 s.",
     "new": "\n  const sender = useMemo<Sender>(() => ({\n    receipts: (ids) => convex.query(api.transfer.receipts, { ids }),\n    send: (report) => convex.mutation(api.transfer.send, { report }),\n  }), [convex]);\n  useEffect(() => {\n    // Held reports are sent as their author: only once the server has said\n    // who this is, and only with a connection.\n    if (online && isAuthenticated && userId !== undefined) startSending(sender, userId);\n    else stopSending();\n    return stopSending;\n  }, [online, isAuthenticated, userId, sender]);\n\n  // IndexedDB opens in a few milliseconds, and openStore() gives up after 1.5 s."
    }
   ]
  },
  "src/components/offline-banner.tsx": {
   "marker": "const atRisk = waiting > 0 && !heldIsDurable();",
   "edits": [
    {
     "old": "import { useHeldItems } from \"@/lib/offline/held\";",
     "new": "import { heldIsDurable, useHeldItems } from \"@/lib/offline/held\";"
    },
    {
     "old": " * While any report is waiting, the browser is asked to warn before the tab\n * is closed or reloaded, because that would lose it.",
     "new": " * Waiting reports are kept on the device, so closing the app does not lose\n * them. Only when the device would not store them is the browser asked to\n * warn before the tab is closed or reloaded."
    },
    {
     "old": "\n  useEffect(() => {",
     "new": "\n  const atRisk = waiting > 0 && !heldIsDurable();\n  useEffect(() => {"
    },
    {
     "old": "    if (waiting === 0) return;",
     "new": "    if (!atRisk) return;"
    },
    {
     "old": "  }, [waiting]);",
     "new": "  }, [atRisk]);"
    },
    {
     "old": "        <span>Back online. Sending {reports(waiting)}. Keep CircuitScout open.</span>",
     "new": "        <span>Back online. Sending {reports(waiting)}.{atRisk ? \" Keep CircuitScout open.\" : \"\"}</span>"
    }
   ]
  },
  "src/routes/app-layout.tsx": {
   "marker": "<SignOutDialog />",
   "edits": [
    {
     "old": "import { AppNav } from \"@/components/app-nav\";\nimport { OfflineBanner } from \"@/components/offline-banner\";\nimport { PracticeBanner } from \"@/components/practice-banner\";",
     "new": "import { AppNav } from \"@/components/app-nav\";\nimport { OtherScoutNotice } from \"@/components/held\";\nimport { OfflineBanner } from \"@/components/offline-banner\";\nimport { SignOutDialog } from \"@/components/sign-out-dialog\";\nimport { PracticeBanner } from \"@/components/practice-banner\";"
    },
    {
     "old": "        <OfflineBanner />\n        <ViewOnlyNotice />",
     "new": "        <OfflineBanner />\n        <OtherScoutNotice />\n        <ViewOnlyNotice />"
    },
    {
     "old": "      </footer>\n    </div>",
     "new": "      </footer>\n      <SignOutDialog />\n    </div>"
    }
   ]
  },
  "src/routes/profile.tsx": {
   "marker": "await signOut({ force: true });",
   "edits": [
    {
     "old": "      await signOut();",
     "new": "      // No question about unsent reports: the account is already gone.\n      await signOut({ force: true });"
    }
   ]
  },
  "src/routes/scout/form.tsx": {
   "marker": "report: { kind: \"match\", args },",
   "edits": [
    {
     "old": "          // No connection: hand the report to the held list rather than\n          // waiting here. It sends when the connection returns, while the\n          // app stays open.\n          holdSubmission({",
     "new": "          // No connection: hand the report to the outbox rather than\n          // waiting here. It is kept on this device and sent when the\n          // connection returns.\n          const heldNow = holdSubmission({"
    },
    {
     "old": "            send: () => submit(args),",
     "new": "            report: { kind: \"match\", args },"
    },
    {
     "old": "          void navigate(\"/scout\");",
     "new": "          if (heldNow) void navigate(\"/scout\");"
    }
   ]
  },
  "src/routes/pit/form.tsx": {
   "marker": "report: { kind: \"pit\", args: {",
   "edits": [
    {
     "old": "      // No connection: hand the report to the held list rather than waiting\n      // here. It sends when the connection returns, while the app stays open.",
     "new": "      // No connection: hand the report to the outbox rather than waiting\n      // here. It is kept on this device and sent when the connection returns."
    },
    {
     "old": "      holdSubmission({",
     "new": "      const heldNow = holdSubmission({"
    },
    {
     "old": "        send: () => upsert({ teamId: team._id, ...draft, photoId: null }),",
     "new": "        report: { kind: \"pit\", args: { teamId: team._id, ...draft, photoId: null } },"
    },
    {
     "old": "      });\n      void navigate(\"/pit\");\n      return;",
     "new": "      });\n      if (heldNow) void navigate(\"/pit\");\n      return;"
    }
   ]
  },
  "src/routes/notes/scout-form.tsx": {
   "marker": "kind: \"noteMatch\",",
   "edits": [
    {
     "old": "      // No connection: hand the report to the held list rather than waiting\n      // here. It sends when the connection returns, while the app stays open.",
     "new": "      // No connection: hand the report to the outbox rather than waiting\n      // here. It is kept on this device and sent when the connection returns."
    },
    {
     "old": "      holdSubmission({",
     "new": "      const heldNow = holdSubmission({"
    },
    {
     "old": "        send: () => save({ matchNumber: data.matchNumber, teamNumber: data.teamNumber, ...report }),",
     "new": "        report: {\n          kind: \"noteMatch\",\n          args: { matchNumber: data.matchNumber, teamNumber: data.teamNumber, ...report },\n        },"
    },
    {
     "old": "      });\n      void navigate(\"/scout\");\n      return;",
     "new": "      });\n      if (heldNow) void navigate(\"/scout\");\n      return;"
    }
   ]
  },
  "src/routes/notes/pit-form.tsx": {
   "marker": "report: { kind: \"notePit\", args: {",
   "edits": [
    {
     "old": "      // No connection: hand the report to the held list rather than waiting\n      // here. It sends when the connection returns, while the app stays open.\n      holdSubmission({",
     "new": "      // No connection: hand the report to the outbox rather than waiting\n      // here. It is kept on this device and sent when the connection returns.\n      const heldNow = holdSubmission({"
    },
    {
     "old": "        send: () => save({ teamNumber, ...draft, photoId: null }),",
     "new": "        report: { kind: \"notePit\", args: { teamNumber, ...draft, photoId: null } },"
    },
    {
     "old": "      });\n      void navigate(\"/pit\");\n      return;",
     "new": "      });\n      if (heldNow) void navigate(\"/pit\");\n      return;"
    }
   ]
  },
  "AGENTS.md": {
   "marker": "hands its report to `holdSubmission`",
   "edits": [
    {
     "old": "  `CACHE_VERSION` in `store.ts` when a cached query's return shape changes.\n- Never add API routes, server handlers or a backend layer for data that",
     "new": "  `CACHE_VERSION` in `store.ts` when a cached query's return shape changes.\n- A form saved with no connection hands its report to `holdSubmission` in\n  `src/lib/offline/held.ts`. It is kept in the same IndexedDB database (the\n  outbox) and sent with `transfer.send` once the server has confirmed the\n  scout again. Never queue an offline save in the Convex client, and never\n  send a held report any other way: the server writes each held id once.\n- Never add API routes, server handlers or a backend layer for data that"
    }
   ]
  }
 },
 "replaced": {
  "src/lib/offline/held.ts": {
   "was": "bb34ee3ea62fb9ec7d1b4c1c11fe274d599318c1d86e6276b297a9bf066e9439",
   "now": "de27d3ab92424c069a8cd5251ddc9b46fcad5fc0099ad3727a2ff11d971582d2"
  },
  "src/components/held.tsx": {
   "was": "174e2b8dccf3f75c40980b40075f0cde7517bbc11230562f59e3fb1986f5ee71",
   "now": "b3d607e33365d18a3f289ca067b37cf59e8d306675e37bc6ab56d5de982c062f"
  },
  "src/lib/offline/use-sign-out.ts": {
   "was": "b6fe82b324edcbb5b86963aed3fa15a14c1a6f57006b05d061768b0cddb566f2",
   "now": "3a4c18e553443a7bdf316d29ada0c39c9ec0cb67f941102abf1ddaa1e62af5f8"
  }
 }
}
EOF_JSON
cat > .patch-outbox.mjs <<'MJS'
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const mode = process.argv[2]; // "check" | "write"
const { edited, replaced } = JSON.parse(readFileSync(".patch-outbox.json", "utf8"));
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
  if (hash !== was && hash !== now) {
    throw new Error(`${path} has been changed since the offline patches wrote it. This patch replaces it whole, so it stops here.`);
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
bun .patch-outbox.mjs check || { echo "ERROR: nothing was changed" >&2; exit 1; }

# ---- 2. Files written whole -------------------------------------------------
say "Outbox, sender, sign-out question"
cat > src/lib/offline/held.ts <<'EOF_FILE'
import { ConvexError } from "convex/values";
import type { FunctionArgs, FunctionReturnType } from "convex/server";
import { useSyncExternalStore } from "react";
import { toast } from "sonner";

import type { api } from "../../../convex/_generated/api";
import {
  cachedUserId, knownEventId, outboxChange, outboxIsDurable, outboxReadAll, outboxRowsAtOpen,
  subscribeStore,
} from "./store";

/**
 * The outbox: reports saved with no connection, kept on the device until the
 * server has them (data transfer plan, section 3).
 *
 * A form that is saved offline hands its report to holdSubmission(). The
 * report is written to IndexedDB with an id made here, so it survives closing
 * the app. Nothing is queued in the Convex client. When the server has
 * confirmed the same scout again, the sender (startSending) asks which ids
 * the server already has and sends the rest one at a time through
 * transfer.send. The server writes each id once, so a retry, a second tab or
 * a send cut off halfway cannot duplicate a report.
 *
 * Rows belong to the scout who saved them. Another scout signing in on the
 * same device never sees or sends them; they wait for their author.
 */

type SendArgs = FunctionArgs<typeof api.transfer.send>["report"];
type Body<T> = T extends unknown ? Omit<T, "id" | "eventId"> : never;
/** Which form a report came from, and that form's save arguments. */
export type HeldReport = Body<SendArgs>;

type Row = {
  id: string;
  userId: string;
  /** The active event when the form was saved. The server refuses any other. */
  eventId: string;
  report: HeldReport;
  key: string;
  label: string;
  to: string;
  heldAt: number;
  values: unknown;
  status: "waiting" | "failed";
  error: string | null;
};

export type HeldItem = {
  id: string;
  /** One per form: "pit:1002", "match:12:1002", "note-pit:254", "note-match:3:254". */
  key: string;
  /** What the scout calls it: "Team 1002 pit report". */
  label: string;
  /** The route that shows it. */
  to: string;
  heldAt: number;
  /** What was entered, in whatever shape the form can show again. */
  values: unknown;
  status: "waiting" | "failed";
  /** The server's reason, when status is "failed". */
  error: string | null;
};

// ---- State -----------------------------------------------------------------

let rows: Row[] = [];
let loaded = false;
// New arrays on every change, so they work as useSyncExternalStore snapshots.
let mine: ReadonlyArray<HeldItem> = [];
let othersCount = 0;
const listeners = new Set<() => void>();

function isRow(value: unknown): value is Row {
  if (value === null || typeof value !== "object") return false;
  const row = value as Partial<Row>;
  return typeof row.id === "string" && typeof row.userId === "string"
    && typeof row.eventId === "string" && typeof row.key === "string"
    && typeof row.label === "string" && typeof row.to === "string"
    && typeof row.heldAt === "number" && typeof row.report === "object" && row.report !== null
    && (row.status === "waiting" || row.status === "failed");
}

function load() {
  if (loaded) return;
  loaded = true;
  rows = outboxRowsAtOpen().filter(isRow);
}

function sameItems(a: ReadonlyArray<HeldItem>, b: ReadonlyArray<HeldItem>): boolean {
  return a.length === b.length && a.every((item, i) => {
    const other = b[i];
    return other !== undefined && item.id === other.id && item.status === other.status
      && item.error === other.error;
  });
}

let computed = false;

/** Recomputes what the signed-in scout sees. True when it changed. */
function compute(): boolean {
  computed = true;
  const userId = cachedUserId();
  const next = rows
    .filter((row) => row.userId === userId)
    .sort((a, b) => a.heldAt - b.heldAt)
    .map(({ id, key, label, to, heldAt, values, status, error }): HeldItem => ({
      id, key, label, to, heldAt, values, status, error,
    }));
  const others = userId === null ? 0 : rows.filter((row) => row.userId !== userId).length;
  if (sameItems(next, mine) && others === othersCount) return false;
  mine = next;
  othersCount = others;
  return true;
}

/** Called after every change. */
function publish() {
  if (compute()) for (const listener of listeners) listener();
}

let watchingStore = false;
function subscribe(listener: () => void): () => void {
  load();
  if (!watchingStore) {
    // Who is signed in comes from the store, and can change under us.
    watchingStore = true;
    subscribeStore(publish);
  }
  publish();
  listeners.add(listener);
  return () => listeners.delete(listener);
}
const snapshot = (): ReadonlyArray<HeldItem> => {
  load();
  // Before the first subscription: so the first render already has the list.
  if (!computed) compute();
  return mine;
};

// What the device has not caught up with yet, so a re-read does not undo it.
const writing = new Set<string>();
const removing = new Set<string>();
/** Rows the device would not store. They live in this tab only. */
const memoryOnly = new Set<string>();

/** Applies a change in memory at once, then on the device. */
async function change(put: Row[], remove: string[]): Promise<boolean> {
  load();
  const gone = new Set([...remove, ...put.map((row) => row.id)]);
  rows = [...rows.filter((row) => !gone.has(row.id)), ...put];
  publish();
  for (const row of put) writing.add(row.id);
  for (const id of remove) removing.add(id);
  const onDevice = await outboxChange(put, remove);
  for (const row of put) {
    writing.delete(row.id);
    if (!onDevice) memoryOnly.add(row.id);
  }
  for (const id of remove) {
    removing.delete(id);
    memoryOnly.delete(id);
  }
  return onDevice;
}

function newId(): string {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  // Older browsers and pages not served over https.
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x40;
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80;
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

// ---- Saving ----------------------------------------------------------------

/**
 * Take over a submission made with no connection. Returns false, with a
 * message on screen, when it cannot be held; the form should then stay open.
 *
 * Saving the same form again replaces its entry: the new one gets a new id,
 * and the old one was never sent.
 */
export function holdSubmission(input: {
  key: string;
  label: string;
  to: string;
  values: unknown;
  report: HeldReport;
}): boolean {
  load();
  const userId = cachedUserId();
  const eventId = knownEventId();
  if (userId === null || typeof eventId !== "string") {
    toast.error("Could not hold this report", {
      description: "This device has no saved sign-in or event. Reconnect, then save again.",
    });
    return false;
  }
  const row: Row = {
    id: newId(),
    userId,
    eventId,
    report: input.report,
    key: input.key,
    label: input.label,
    to: input.to,
    // Never equal to an earlier one of ours: the list and the sender go by it.
    heldAt: Math.max(Date.now(), ...rows.filter((r) => r.userId === userId).map((r) => r.heldAt + 1)),
    values: input.values,
    status: "waiting",
    error: null,
  };
  // An entry that is being sent right now is left to finish.
  const replaced = rows
    .filter((r) => r.userId === userId && r.key === input.key && !inFlight.has(r.id))
    .map((r) => r.id);
  void change([row], replaced).then((onDevice) => {
    if (onDevice) return;
    toast.warning("Held in this tab only", {
      description: "This device would not store the report. Keep CircuitScout open until it sends.",
    });
  });
  toast("Held on this device", {
    description: `${input.label} will send when you are back online.`,
  });
  return true;
}

/** Remove a failed entry from the list. A waiting entry cannot be withdrawn. */
export function dismissHeld(id: string) {
  load();
  if (rows.some((row) => row.id === id && row.status === "failed")) void change([], [id]);
}

/** Put a failed entry back in line and try it again. */
export function retryHeld(id: string) {
  load();
  const row = rows.find((r) => r.id === id && r.status === "failed");
  if (!row) return;
  void change([{ ...row, status: "waiting", error: null }], []).then(() => kick());
}

/**
 * The form was saved the ordinary way, with a connection: an entry for it
 * that is not already on its way no longer describes anything.
 */
export function forgetHeld(key: string) {
  load();
  const userId = cachedUserId();
  const stale = rows
    .filter((row) => row.userId === userId && row.key === key && !inFlight.has(row.id))
    .map((row) => row.id);
  if (stale.length > 0) void change([], stale);
}

/**
 * Signing out: the signed-in scout's reports leave the device, sent or not.
 * Another scout's rows are not touched.
 */
export function discardHeld(): Promise<boolean> {
  load();
  const userId = cachedUserId();
  return change([], rows.filter((row) => row.userId === userId).map((row) => row.id));
}

// ---- Reading ---------------------------------------------------------------

/** For reading once, outside render (a form seeding its state). */
export function heldValues<T>(key: string): T | undefined {
  load();
  const userId = cachedUserId();
  return rows.find((row) => row.userId === userId && row.key === key)?.values as T | undefined;
}

/** How many reports the signed-in scout has on this device, waiting or failed. */
export function heldCount(): number {
  load();
  const userId = cachedUserId();
  return rows.filter((row) => row.userId === userId).length;
}

/** Every held report of the signed-in scout, oldest first. */
export function useHeldItems(): ReadonlyArray<HeldItem> {
  return useSyncExternalStore(subscribe, snapshot);
}

/** The held report for one form, if there is one. */
export function useHeld(key: string): HeldItem | undefined {
  return useHeldItems().find((i) => i.key === key);
}

const othersSnapshot = (): number => {
  load();
  return othersCount;
};
/** How many unsent reports on this device belong to a different scout. */
export function useOthersHeldCount(): number {
  return useSyncExternalStore(subscribe, othersSnapshot);
}

/** False when the device would not store reports: they live in this tab only. */
export const heldIsDurable = (): boolean => outboxIsDurable();

// ---- Sending ---------------------------------------------------------------

/** The two server calls the sender makes. */
export type Sender = {
  /** transfer.receipts, once: never a subscription. */
  receipts: (ids: string[]) => Promise<FunctionReturnType<typeof api.transfer.receipts>>;
  /** transfer.send. */
  send: (report: SendArgs) => Promise<FunctionReturnType<typeof api.transfer.send>>;
};

const MAX_IDS = 200;
let link: { client: Sender; userId: string } | null = null;
let running = false;
let again = false;
const inFlight = new Set<string>();

/**
 * The server has confirmed `userId` and there is a connection: send that
 * scout's waiting reports, now and whenever kick() is called.
 */
export function startSending(client: Sender, userId: string) {
  if (link?.client === client && link.userId === userId) return;
  link = { client, userId };
  kick();
}

/** No connection, or nobody confirmed: stop starting new sends. */
export function stopSending() {
  link = null;
}

function kick() {
  if (!link) return;
  if (running) {
    again = true;
    return;
  }
  void run();
}

/** Rows written by another tab since this one last looked. */
async function refresh() {
  const onDevice = await outboxReadAll();
  if (onDevice === null) return;
  const fresh = onDevice.filter(isRow).filter((row) => !removing.has(row.id) && !writing.has(row.id));
  const known = new Set(fresh.map((row) => row.id));
  // Keep what the device has not caught up with, or would not store.
  const local = rows.filter((row) => !known.has(row.id)
    && (writing.has(row.id) || memoryOnly.has(row.id) || inFlight.has(row.id)));
  rows = [...fresh, ...local];
  publish();
}

function reason(error: unknown): string {
  if (error instanceof ConvexError) return typeof error.data === "string" ? error.data : "The server refused this report.";
  return "The server could not save this report. Try again, or tell an admin if it keeps happening.";
}

const reports = (n: number) => `${n} report${n === 1 ? "" : "s"}`;

async function run() {
  running = true;
  let sent = 0;
  let byQr = 0;
  let failed = 0;
  try {
    do {
      again = false;
      const current = link;
      if (!current) break;
      load();
      await refresh();
      const own = () => rows.filter((row) => row.userId === current.userId && !inFlight.has(row.id));
      if (own().length === 0) break;

      // 1. What the server already has, by either route.
      const ids = own().map((row) => row.id);
      for (let at = 0; at < ids.length && link === current; at += MAX_IDS) {
        try {
          const found = await current.client.receipts(ids.slice(at, at + MAX_IDS));
          const arrived = found.filter((f) => rows.some((row) => row.id === f.id));
          byQr += arrived.filter((f) => f.via === "relay").length;
          sent += arrived.filter((f) => f.via !== "relay").length;
          if (arrived.length > 0) await change([], arrived.map((f) => f.id));
        } catch {
          // Not answered. Sending is still safe: the server checks every id.
        }
      }

      // 2. The rest, oldest first, one per call.
      const queue = own().filter((row) => row.status === "waiting").sort((a, b) => a.heldAt - b.heldAt);
      for (const row of queue) {
        if (link !== current) break;
        if (!rows.some((r) => r.id === row.id)) continue;
        inFlight.add(row.id);
        try {
          const report = { id: row.id, eventId: row.eventId, ...row.report } as SendArgs;
          const answer = await current.client.send(report);
          inFlight.delete(row.id);
          await change([], [row.id]);
          if (answer.status === "received" && answer.via === "relay") byQr += 1;
          else sent += 1;
        } catch (error) {
          inFlight.delete(row.id);
          failed += 1;
          await change([{ ...row, status: "failed", error: reason(error) }], []);
        }
      }
    } while (again && link);
  } finally {
    running = false;
  }
  if (sent > 0) toast.success(`Sent ${reports(sent)}`);
  if (byQr > 0) toast.success(`${reports(byQr)} already sent by QR`);
  if (failed > 0) {
    toast.error(`Could not send ${reports(failed)}`, { description: "See Waiting to send on the dashboard." });
  }
}
EOF_FILE
echo "  wrote            src/lib/offline/held.ts"
cat > src/lib/offline/use-sign-out.ts <<'EOF_FILE'
import { useAuthActions } from "@convex-dev/auth/react";
import { useCallback, useSyncExternalStore } from "react";

import { discardHeld, heldCount } from "./held";
import { forgetAuthTokens } from "./session";
import { useOnline } from "./status";
import { clearOfflineData } from "./store";

/**
 * A sign-out that is waiting for an answer: this scout has reports on the
 * device that have not been sent, and signing out discards them.
 */
export type SignOutQuestion = { count: number; proceed: () => void };

let question: SignOutQuestion | null = null;
const listeners = new Set<() => void>();
function ask(next: SignOutQuestion | null) {
  question = next;
  for (const listener of listeners) listener();
}
function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** For SignOutDialog, which is mounted once in the app layout. */
export function useSignOutQuestion(): SignOutQuestion | null {
  return useSyncExternalStore(subscribe, () => question);
}
export function cancelSignOut() {
  ask(null);
}

/**
 * The only way the app signs out. Empties the offline store first, so the
 * next person on a shared tablet never sees the previous scout's data, then
 * signs out.
 *
 * Reports held on the device and not sent yet would be lost, so with any
 * waiting the scout is asked first (SignOutDialog) and nothing happens until
 * they answer. Pass force to skip the question, for an account that has
 * just been deleted.
 *
 * With no connection, Convex Auth's signOut() would wait forever on a server
 * call, so the tokens are removed from the device directly and the page is
 * reloaded onto the sign-in screen.
 */
export function useSignOutAndClear(): (options?: { force?: boolean }) => Promise<void> {
  const { signOut } = useAuthActions();
  const online = useOnline();
  return useCallback(async (options) => {
    const finish = async () => {
      ask(null);
      // First, and awaited: it reads whose reports these are from the store.
      await discardHeld();
      clearOfflineData();
      if (online) {
        await signOut();
        return;
      }
      forgetAuthTokens();
      window.location.assign("/sign-in");
    };
    const count = heldCount();
    if (count === 0 || options?.force) {
      await finish();
      return;
    }
    ask({ count, proceed: () => void finish() });
  }, [online, signOut]);
}
EOF_FILE
echo "  wrote            src/lib/offline/use-sign-out.ts"
cat > src/components/held.tsx <<'EOF_FILE'
import { Clock, TriangleAlert, Users } from "lucide-react";
import { useState, useSyncExternalStore } from "react";
import { Link } from "react-router";

import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import {
  dismissHeld, heldIsDurable, retryHeld, useHeld, useHeldItems, useOthersHeldCount,
  type HeldItem,
} from "@/lib/offline/held";
import { useOnline } from "@/lib/offline/status";
import { cachedUserId, subscribeStore } from "@/lib/offline/store";

const AT = new Intl.DateTimeFormat(undefined, {
  month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
});

function Status({ item }: { item: HeldItem }) {
  if (item.status === "waiting") {
    return (
      <span className="text-muted-foreground flex items-center gap-1.5 text-xs">
        <Clock className="size-3.5 shrink-0" aria-hidden />
        Waiting to send since {AT.format(item.heldAt)}
      </span>
    );
  }
  return (
    <span className="text-destructive flex items-start gap-1.5 text-xs">
      <TriangleAlert className="mt-0.5 size-3.5 shrink-0" aria-hidden />
      <span>Could not send: {item.error}</span>
    </span>
  );
}

/**
 * Dashboard card: every report that was saved with no connection and has not
 * reached the server yet. Renders nothing when there are none.
 */
export function HeldList() {
  const items = useHeldItems();
  const online = useOnline();
  if (items.length === 0) return null;
  return (
    <Card>
      <CardHeader>
        <CardTitle>Waiting to send</CardTitle>
        <CardDescription>
          {heldIsDurable()
            ? "Saved on this device. Each one sends by itself when you are back online, even if you close CircuitScout before then. Signing out discards them."
            : "This device would not store these, so they are held in this tab only. Keep CircuitScout open until this list is empty."}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        {items.map((item) => (
          <div key={item.id} className="flex flex-wrap items-center gap-x-3 gap-y-2 rounded-md border p-3">
            <div className="min-w-0 flex-1 space-y-1">
              <p className="truncate text-sm font-medium">{item.label}</p>
              <Status item={item} />
            </div>
            <Button variant="outline" size="sm" render={<Link to={item.to} />}>View</Button>
            {item.status === "failed" ? (
              <>
                <Button variant="outline" size="sm" disabled={!online} onClick={() => retryHeld(item.id)}>
                  Try again
                </Button>
                <Button variant="ghost" size="sm" onClick={() => dismissHeld(item.id)}>Dismiss</Button>
              </>
            ) : null}
          </div>
        ))}
      </CardContent>
    </Card>
  );
}

/**
 * At the top of a form whose answers are held: says so, so reopening the form
 * and seeing your own entries is not mistaken for the server having them.
 */
export function HeldFormNotice({ heldKey }: { heldKey: string }) {
  const item = useHeld(heldKey);
  if (!item) return null;
  return (
    <div role="status" className="space-y-1 rounded-lg border border-dashed p-3">
      <Status item={item} />
      <p className="text-muted-foreground text-xs">
        {item.status === "waiting"
          ? "These are the answers you saved. You can change them and save again."
          : "These are the answers you saved. Fix what the message says and save again."}
      </p>
    </div>
  );
}

/** A held report shown as read-only rows, for forms that cannot be reopened. */
export function HeldSummary({
  item,
  rows,
}: {
  item: HeldItem;
  rows: ReadonlyArray<readonly [label: string, value: string]>;
}) {
  const online = useOnline();
  return (
    <Card>
      <CardHeader>
        <CardTitle>What you entered</CardTitle>
        <CardDescription><Status item={item} /></CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        <dl className="divide-y text-sm">
          {rows.map(([label, value]) => (
            <div key={label} className="flex gap-3 py-2">
              <dt className="text-muted-foreground w-2/5 shrink-0">{label}</dt>
              <dd className="min-w-0 flex-1 break-words whitespace-pre-wrap">{value}</dd>
            </div>
          ))}
        </dl>
        {item.status === "failed" ? (
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" disabled={!online} onClick={() => retryHeld(item.id)}>
              Try again
            </Button>
            <Button variant="outline" onClick={() => dismissHeld(item.id)}>
              Dismiss and start again
            </Button>
          </div>
        ) : null}
      </CardContent>
    </Card>
  );
}

const SEEN_KEY = "circuitscout.other-scout-notice";

function seenFor(): string | null {
  try {
    return sessionStorage.getItem(SEEN_KEY);
  } catch {
    return null;
  }
}

/**
 * Under the nav, for a scout who signs in on a device that still holds
 * another scout's unsent reports (data transfer plan, D-7). Those reports
 * are kept, hidden, and sent only when their author signs in here again.
 */
export function OtherScoutNotice() {
  const others = useOthersHeldCount();
  const userId = useSyncExternalStore(subscribeStore, cachedUserId);
  const [seen, setSeen] = useState(seenFor);
  if (others === 0 || userId === null || seen === userId) return null;
  return (
    <div
      role="status"
      className="bg-muted flex flex-wrap items-center justify-center gap-x-3 gap-y-1 border-b px-4 py-1.5 text-center text-xs"
    >
      <span className="flex items-center gap-2">
        <Users className="size-3.5 shrink-0" aria-hidden />
        <span>
          This device holds {others} unsent report{others === 1 ? "" : "s"} from another scout.{" "}
          {others === 1 ? "It stays" : "They stay"} here until that scout signs in again.
        </span>
      </span>
      <Button
        variant="outline"
        size="sm"
        className="h-6 px-2 text-xs"
        onClick={() => {
          try {
            sessionStorage.setItem(SEEN_KEY, userId);
          } catch {
            // Storage is unavailable; the notice goes for this page only.
          }
          setSeen(userId);
        }}
      >
        OK
      </Button>
    </div>
  );
}
EOF_FILE
echo "  wrote            src/components/held.tsx"
cat > src/components/sign-out-dialog.tsx <<'EOF_FILE'
import { Button } from "@/components/ui/button";
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { useOnline } from "@/lib/offline/status";
import { cancelSignOut, useSignOutQuestion } from "@/lib/offline/use-sign-out";

/**
 * Asked before signing out with reports still on the device: signing out
 * discards them (data transfer plan, D-2). Mounted once, in the app layout.
 */
export function SignOutDialog() {
  const question = useSignOutQuestion();
  const online = useOnline();
  const count = question?.count ?? 0;
  return (
    <Dialog open={question !== null} onOpenChange={(open) => { if (!open) cancelSignOut(); }}>
      <DialogContent className="max-w-sm">
        <DialogHeader>
          <DialogTitle>Sign out and lose unsent reports?</DialogTitle>
          <DialogDescription>
            {count === 1
              ? "1 report on this device has not been sent."
              : `${count} reports on this device have not been sent.`}{" "}
            Signing out discards {count === 1 ? "it" : "them"}.{" "}
            {online
              ? "You are online: cancel, and wait for Waiting to send on the dashboard to empty."
              : "To keep them, cancel and stay signed in until you are back online."}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" onClick={cancelSignOut}>Cancel</Button>
          <Button variant="destructive" onClick={() => question?.proceed()}>
            Sign out and discard
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
EOF_FILE
echo "  wrote            src/components/sign-out-dialog.tsx"

# ---- 3. Edits --------------------------------------------------------------
say "Store, provider, forms, layout"
bun .patch-outbox.mjs write

say "Done"
cat <<'TXT'
Next:
  1. bun run typecheck && bun run lint && bun run build
  2. Patch 6 must be on the Convex deployment the app talks to before this
     is used: bun run go for development, and your usual deploy for
     production. Deploy Convex before, or together with, the site.
  3. Against a production build (bunx vite preview, or a Vercel preview),
     signed in, on an event with a schedule:
     a. Open the dashboard and Pit Scouting online, so the lists are saved.
     b. DevTools > Network > Offline. Save a pit report and a match report.
        Both appear under Waiting to send.
     c. Close the tab. Open the app again, still offline: both are still
        listed, and the pit form reopens with your answers.
     d. Press Sign out: the question names the count. Cancel.
     e. Go back online. The banner says "Sending 2 reports", then a toast
        says "Sent 2 reports" and the list empties. Check the two reports
        are on the server once each.
     f. Offline again, save a second match report on the robot you just
        reported. Online: it stays in the list with "You have already
        reported that robot in this match." Dismiss it.
     g. Offline, save a report, then sign out and choose Sign out and
        discard: after signing in again the list is empty.
  4. Shared device: scout A saves a report offline and the session ends
     without a sign-out (or A is signed out on the server). Scout B signs
     in: B sees the notice and not A's report. A signs in again: A's report
     is listed and sends.
TXT
