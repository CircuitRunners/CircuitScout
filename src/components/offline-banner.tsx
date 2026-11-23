import { useEffect, useSyncExternalStore } from "react";
import { CloudOff, CloudUpload } from "lucide-react";

import { heldIsDurable, useHeldItems } from "@/lib/offline/held";
import { useOnline } from "@/lib/offline/status";
import { oldestServed, subscribeServed } from "@/lib/offline/store";

const AS_OF = new Intl.DateTimeFormat(undefined, {
  month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
});

const reports = (n: number) => `${n} report${n === 1 ? "" : "s"}`;

/**
 * Under the nav.
 *
 * Offline: says how old the data on screen is (the oldest cached result any
 * query on the page is showing; a clock time rather than "5 minutes ago", so
 * it stays right without ticking) and how many reports are waiting to send.
 *
 * Back online with reports still waiting: says they are being sent.
 *
 * Waiting reports are kept on the device, so closing the app does not lose
 * them. Only when the device would not store them is the browser asked to
 * warn before the tab is closed or reloaded.
 */
export function OfflineBanner() {
  const online = useOnline();
  const oldest = useSyncExternalStore(subscribeServed, oldestServed);
  const waiting = useHeldItems().filter((i) => i.status === "waiting").length;

  const atRisk = waiting > 0 && !heldIsDurable();
  useEffect(() => {
    if (!atRisk) return;
    const warn = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      // Older browsers need a return value to show the prompt.
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [atRisk]);

  if (online && waiting === 0) return null;
  if (online) {
    return (
      <div
        role="status"
        className="bg-primary text-primary-foreground flex items-center justify-center gap-2 px-4 py-1.5 text-center text-xs font-medium"
      >
        <CloudUpload className="size-3.5 shrink-0" />
        <span>Back online. Sending {reports(waiting)}.{atRisk ? " Keep CircuitScout open." : ""}</span>
      </div>
    );
  }
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
        {waiting > 0 ? ` ${reports(waiting)} waiting to send.` : ""}
      </span>
    </div>
  );
}
