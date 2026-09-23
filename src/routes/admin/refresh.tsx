import { LoaderCircle, RefreshCw } from "lucide-react";
import { useMemo, useRef, useState, type ReactNode } from "react";

import { Button } from "@/components/ui/button";
import {
  RefreshContext, useAdminRefresh, type Refresher, type Registry,
} from "./refresh-context";

/**
 * Every Refresh button on the admin page registers here, which is what lets
 * "Refresh admin page" run them all. Refresh Statbotics/TBA deliberately
 * does not register: it calls external APIs, and pressing the page button
 * to see new reports should not also hit TBA.
 */
export function AdminRefreshProvider({ children }: { children: ReactNode }) {
  const refreshers = useRef(new Map<string, Refresher>());
  const value = useMemo<Registry>(() => ({
    register: (key, fn) => {
      refreshers.current.set(key, fn);
      return () => {
        if (refreshers.current.get(key) === fn) refreshers.current.delete(key);
      };
    },
    refresh: async (keys) => {
      const fns = keys
        ? keys.flatMap((k) => refreshers.current.get(k) ?? [])
        : [...refreshers.current.values()];
      await Promise.all(fns.map((fn) => fn()));
    },
  }), []);
  return <RefreshContext.Provider value={value}>{children}</RefreshContext.Provider>;
}

const time = (at: number) =>
  new Date(at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

/** The per-card button, for a card header's top-right corner. */
export function RefreshButton({
  onRefresh, loading, updatedAt,
}: {
  onRefresh: () => Promise<void>;
  loading: boolean;
  updatedAt: number | null;
}) {
  return (
    <div className="flex flex-col items-end gap-1">
      <Button variant="outline" size="sm" disabled={loading} onClick={() => void onRefresh()}>
        {loading ? (
          <LoaderCircle className="size-3.5 animate-spin" />
        ) : (
          <RefreshCw className="size-3.5" />
        )}
        Refresh
      </Button>
      {updatedAt ? (
        <span className="text-muted-foreground text-xs">Updated {time(updatedAt)}</span>
      ) : null}
    </div>
  );
}

/** Next to the page title: runs every registered Refresh button at once. */
export function RefreshAdminPageButton() {
  const { refresh } = useAdminRefresh();
  const [busy, setBusy] = useState(false);
  return (
    <Button variant="outline" size="sm" disabled={busy}
      onClick={() => {
        setBusy(true);
        void refresh().finally(() => setBusy(false));
      }}>
      {busy ? (
        <LoaderCircle className="size-3.5 animate-spin" />
      ) : (
        <RefreshCw className="size-3.5" />
      )}
      Refresh admin page
    </Button>
  );
}

/** What a card shows before its first load finishes, or if it failed. */
export function NotLoaded({ loading }: { loading: boolean }) {
  return (
    <p className="text-muted-foreground text-sm">
      {loading ? "Loading…" : "Couldn't load. Press Refresh to try again."}
    </p>
  );
}
