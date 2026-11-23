import { Clock, TriangleAlert, Users } from "lucide-react";
import { useState, useSyncExternalStore } from "react";
import { Link } from "react-router";

import { Button } from "@/components/ui/button";
import {
  Card, CardAction, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { MyQrButton } from "@/components/my-qr";
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
        <CardAction><MyQrButton /></CardAction>
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
