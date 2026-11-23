import { useSyncExternalStore } from "react";
import { toast } from "sonner";

/**
 * Reports submitted with no connection, and what happened to them.
 *
 * A form that is saved offline hands its report to holdSubmission() instead
 * of waiting on it. The Convex client keeps the mutation queued and sends it
 * when the connection returns; this module keeps the part a scout needs to
 * see in the meantime: what is waiting, since when, and what was entered.
 *
 * Everything here lives in this tab's memory. Closing or reloading the app
 * loses both the queued mutation and this list. Making held reports survive
 * that is the data transfer plan; when it is built, this is the module whose
 * storage changes, and the forms and the list keep calling the same functions.
 */
export type HeldItem = {
  id: number;
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

let sequence = 0;
// A new array on every change, so it works as a useSyncExternalStore snapshot.
let items: ReadonlyArray<HeldItem> = [];
const listeners = new Set<() => void>();

function publish(next: ReadonlyArray<HeldItem>) {
  items = next;
  for (const listener of listeners) listener();
}

/**
 * Take over a submission made with no connection. `send` must start the
 * Convex mutation and return its promise; it is called once, now, so the
 * mutation joins the client's queue in the order the scout pressed save.
 *
 * Saving the same form again replaces its entry here. Both mutations stay
 * queued and are sent in order, so for forms whose save replaces the earlier
 * one (pit reports, other-season reports) the latest answers win.
 */
export function holdSubmission(input: {
  key: string;
  label: string;
  to: string;
  values: unknown;
  send: () => Promise<unknown>;
}) {
  const id = (sequence += 1);
  const item: HeldItem = {
    id,
    key: input.key,
    label: input.label,
    to: input.to,
    heldAt: Date.now(),
    values: input.values,
    status: "waiting",
    error: null,
  };
  publish([...items.filter((i) => i.key !== input.key), item]);
  toast("Held on this device", {
    description: `${input.label} will send when you are back online. Keep CircuitScout open until then.`,
  });

  const settle = (error: unknown) => {
    // An entry replaced by a later save of the same form is no longer listed.
    if (!items.some((i) => i.id === id)) return;
    if (error === null) {
      publish(items.filter((i) => i.id !== id));
      toast.success(`Sent: ${input.label}`);
      return;
    }
    const message = error instanceof Error ? error.message : String(error);
    publish(items.map((i) => (i.id === id ? { ...i, status: "failed" as const, error: message } : i)));
    toast.error(`Could not send: ${input.label}`, { description: message });
  };

  let sending: Promise<unknown>;
  try {
    sending = input.send();
  } catch (error) {
    settle(error);
    return;
  }
  sending.then(
    () => settle(null),
    (error: unknown) => settle(error),
  );
}

/** Remove a failed entry from the list. A waiting entry cannot be withdrawn. */
export function dismissHeld(id: number) {
  publish(items.filter((i) => i.id !== id || i.status === "waiting"));
}

/**
 * The form was saved the ordinary way, with a connection: an entry left over
 * from an earlier failed attempt no longer describes anything.
 */
export function forgetHeld(key: string) {
  if (items.some((i) => i.key === key && i.status === "failed")) {
    publish(items.filter((i) => i.key !== key || i.status !== "failed"));
  }
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
const snapshot = (): ReadonlyArray<HeldItem> => items;

/** For reading once, outside render (a form seeding its state). */
export function heldValues<T>(key: string): T | undefined {
  return items.find((i) => i.key === key)?.values as T | undefined;
}

/** Every held report, oldest first. */
export function useHeldItems(): ReadonlyArray<HeldItem> {
  return useSyncExternalStore(subscribe, snapshot);
}

/** The held report for one form, if there is one. */
export function useHeld(key: string): HeldItem | undefined {
  return useHeldItems().find((i) => i.key === key);
}
