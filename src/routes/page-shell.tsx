import type { ReactNode } from "react";

import { NOT_SAVED } from "@/components/loading-text";
import { useOnline } from "@/lib/offline/status";

/** Consistent heading block for every landing area. */
export function PageShell({
  title,
  description,
  actions,
  children,
}: {
  title: ReactNode;
  description?: string;
  actions?: ReactNode;
  children?: ReactNode;
}) {
  // Offline, a page still "Loading…" has nothing on its way: say so.
  const online = useOnline();
  const shownTitle = !online && title === "Loading…" ? "Offline" : title;
  const shownDescription = !online && (description === "Loading…" || title === "Loading…")
    ? NOT_SAVED
    : description;
  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="flex flex-wrap items-baseline gap-x-3 gap-y-1 text-2xl font-semibold tracking-tight">
            {shownTitle}
          </h1>
          {shownDescription ? (
            <p className="text-muted-foreground mt-1 text-sm">{shownDescription}</p>
          ) : null}
        </div>
        {actions}
      </div>
      {children}
    </div>
  );
}

export function TrackStub({ track, scope }: { track: string; scope: string }) {
  return (
    <div className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
      <p className="font-medium">Track {track}</p>
      <p className="mt-1">{scope}</p>
    </div>
  );
}
