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

/**
 * What "my QR" carries: the signed-in scout's waiting reports, oldest first,
 * each exactly as transfer.send would be given it. Failed reports are left
 * out: the server has already refused them.
 */
export function heldTransfer(): { author: string; reports: SendArgs[] } | null {
  load();
  const userId = cachedUserId();
  if (userId === null) return null;
  const reports = rows
    .filter((row) => row.userId === userId && row.status === "waiting")
    .sort((a, b) => a.heldAt - b.heldAt)
    .map((row) => ({ id: row.id, eventId: row.eventId, ...row.report }) as SendArgs);
  return { author: userId, reports };
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
