import { Clock, TriangleAlert } from "lucide-react";
import { Link } from "react-router";

import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { dismissHeld, useHeld, useHeldItems, type HeldItem } from "@/lib/offline/held";

const AT = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

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
  if (items.length === 0) return null;
  return (
    <Card>
      <CardHeader>
        <CardTitle>Waiting to send</CardTitle>
        <CardDescription>
          Saved on this device only. Each one sends by itself when you are back
          online. Keep CircuitScout open until this list is empty: closing or
          reloading the app loses them.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        {items.map((item) => (
          <div key={item.id} className="flex items-center gap-3 rounded-md border p-3">
            <div className="min-w-0 flex-1 space-y-1">
              <p className="truncate text-sm font-medium">{item.label}</p>
              <Status item={item} />
            </div>
            <Button variant="outline" size="sm" render={<Link to={item.to} />}>View</Button>
            {item.status === "failed" ? (
              <Button variant="ghost" size="sm" onClick={() => dismissHeld(item.id)}>Dismiss</Button>
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
          <Button variant="outline" onClick={() => dismissHeld(item.id)}>
            Dismiss and start again
          </Button>
        ) : null}
      </CardContent>
    </Card>
  );
}
