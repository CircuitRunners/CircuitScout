#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-admin-refresh.sh — admin cards load on demand, with Refresh buttons.
#
# The admin page's report cards were live subscriptions to queries that read
# every report at the event, so an admin who left the page open re-read them
# all on every submission. That was the largest remaining I/O cost. These
# cards now load once when the page opens and again when refreshed:
#
#   Teams needing attention   attention.forEvent (admin page only; the teams
#                             tab keeps its live copy)
#   Flagged                   admin.reports { onlyFlagged: true }
#   Manage reports            admin.reports { onlyFlagged: false }
#   Pit reports               admin.pitReports
#   Events                    events.list — reads every imported event, and
#                             grew with each event any team imported
#
# Each gets a Refresh button in its top-right corner, with the time it last
# loaded. A "Refresh admin page" button next to the page title runs every
# refresh button on the page — these five and Usage by team — but NOT
# "Refresh Statbotics/TBA", which calls external APIs and stays separate.
#
# Acting on a row refreshes what it affects: dismissing, restoring, changing
# the auto winner or deleting a report refreshes Flagged, Manage reports and
# Teams needing attention; settling an attention item refreshes that card;
# deleting a pit report refreshes Pit reports; importing, activating,
# standing down, deleting, removing or recovering an event refreshes Events.
#
#   src/routes/admin/refresh-context.ts  the registry and useOnDemand
#   src/routes/admin/refresh.tsx         the provider and the buttons
#
# Frontend only. No schema change, nothing to run on prod.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/admin/usage-card.tsx ]] \
  || { echo "ERROR: run patch-multi-team.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# Relative import: Git Bash translates /tmp in arguments, not in import strings.
cat > /tmp/ar-lib.mjs <<'MJS'
export function swap(s, from, to, label) {
  const i = s.indexOf(from);
  if (i < 0 || s.indexOf(from, i + 1) >= 0) {
    console.error(`ERROR: anchor ${i < 0 ? "missing" : "not unique"}: ${label}`);
    process.exit(1);
  }
  return s.slice(0, i) + to + s.slice(i + from.length);
}
/** swap, but only inside one exported component: from its declaration to the next. */
export function swapIn(s, component, from, to, label) {
  const start = s.indexOf(`export function ${component}(`);
  if (start < 0) { console.error(`ERROR: component missing: ${component}`); process.exit(1); }
  const next = s.indexOf("\nexport function ", start + 1);
  const end = next < 0 ? s.length : next;
  return s.slice(0, start) + swap(s.slice(start, end), from, to, `${component}: ${label}`) + s.slice(end);
}
MJS

say "Helpers: src/routes/admin/refresh-context.ts and refresh.tsx"
# Hooks and context in a .ts file, components in the .tsx: Vite's fast
# refresh only works when a component file exports nothing else.
#
# The first version of refresh-context.ts put the `api.x.y` reference in a
# hook dependency list. Those references are rebuilt on every access, so the
# effect re-ran after every render and the cards reloaded in a loop — which
# froze the page. Any copy without the fix is replaced.
if grep -q "getFunctionName" src/routes/admin/refresh-context.ts 2>/dev/null; then
  echo "src/routes/admin/refresh-context.ts already up to date"
else
cat > src/routes/admin/refresh-context.ts <<'EOF'
import { useConvex } from "convex/react";
import {
  getFunctionName, makeFunctionReference,
  type FunctionReference, type FunctionReturnType, type OptionalRestArgs,
} from "convex/server";
import { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import { toast } from "sonner";

export type Refresher = () => Promise<void>;
export type Registry = {
  register: (key: string, fn: Refresher) => () => void;
  /** Run the named refreshers, or every registered one when no keys are given. */
  refresh: (keys?: string[]) => Promise<void>;
};

// Outside the admin page there is no registry, and refreshing is a no-op.
export const RefreshContext = createContext<Registry>({
  register: () => () => {},
  refresh: async () => {},
});

export const useAdminRefresh = () => useContext(RefreshContext);

/** Put a card's refresh in the page registry under `key`. */
export function useRegisterRefresh(key: string, fn: Refresher) {
  const { register } = useAdminRefresh();
  const latest = useRef(fn);
  useEffect(() => {
    latest.current = fn;
  });
  useEffect(() => register(key, () => latest.current()), [register, key]);
}

/**
 * A query run once on mount and again on refresh — never a live
 * subscription. For admin cards whose queries read every report at the
 * event: subscribed, they re-ran on every submission for as long as the
 * page stayed open.
 */
export function useOnDemand<Q extends FunctionReference<"query">>(
  key: string,
  query: Q,
  ...args: OptionalRestArgs<Q>
) {
  const convex = useConvex();
  const [data, setData] = useState<FunctionReturnType<Q> | undefined>(undefined);
  const [loading, setLoading] = useState(true);
  const [updatedAt, setUpdatedAt] = useState<number | null>(null);

  // Both compared by VALUE. `api.x.y` builds a new object on every access,
  // so depending on the reference itself re-ran this hook's effect after
  // every render: load, set state, render, load again — a loop that froze
  // the page when results came back from the client's cache.
  const name = getFunctionName(query);
  const argsKey = JSON.stringify(args);
  // State is only set once the query settles, never synchronously.
  const load = useCallback((isCurrent: () => boolean) =>
    convex.query(
      makeFunctionReference<"query">(name) as Q,
      ...(JSON.parse(argsKey) as OptionalRestArgs<Q>),
    )
      .then((result) => {
        if (!isCurrent()) return;
        setData(result);
        setUpdatedAt(Date.now());
      })
      .catch((error: unknown) => {
        if (isCurrent()) {
          toast.error("Couldn't refresh", {
            description: error instanceof Error ? error.message : String(error),
          });
        }
      })
      .finally(() => {
        if (isCurrent()) setLoading(false);
      }), [convex, name, argsKey]);

  useEffect(() => {
    let current = true;
    void load(() => current);
    return () => {
      current = false;
    };
  }, [load]);

  const refresh = useCallback(() => {
    setLoading(true);
    return load(() => true);
  }, [load]);

  useRegisterRefresh(key, refresh);
  return { data, loading, updatedAt, refresh };
}
EOF
echo "src/routes/admin/refresh-context.ts written"
fi
if [[ -f src/routes/admin/refresh.tsx ]]; then
  echo "src/routes/admin/refresh.tsx already exists"
else
cat > src/routes/admin/refresh.tsx <<'EOF'
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
EOF
echo "src/routes/admin/refresh.tsx written"
fi

say "Attention card: optional callback after settling"
cat > /tmp/ar1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./ar-lib.mjs";
const p = "src/components/attention-items.tsx";
let s = readFileSync(p, "utf8");
if (s.includes("onSettled")) { console.log("attention-items already patched"); process.exit(0); }

s = swap(s,
`export function AttentionCard({
  row,
  showTeam = false,
}: {
  row: AttentionRow;
  showTeam?: boolean;
}) {`,
`export function AttentionCard({
  row,
  showTeam = false,
  onSettled,
}: {
  row: AttentionRow;
  showTeam?: boolean;
  /** For lists that are not live subscriptions, to reload after a change. */
  onSettled?: () => void;
}) {`,
"AttentionCard: props");

s = swap(s,
`      .then(() => toast.success(mode === "resolved" ? "Marked resolved" : "Dismissed"))`,
`      .then(() => {
        toast.success(mode === "resolved" ? "Marked resolved" : "Dismissed");
        onSettled?.();
      })`,
"AttentionCard: settle");

writeFileSync(p, s);
console.log("src/components/attention-items.tsx patched");
MJS
bun /tmp/ar1.mjs

say "Report cards: load on demand, Refresh in the corner"
cat > /tmp/ar2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap, swapIn } from "./ar-lib.mjs";
const p = "src/routes/admin/reports-admin.tsx";
let s = readFileSync(p, "utf8");
if (s.includes("useOnDemand")) { console.log("reports-admin already patched"); process.exit(0); }

s = swap(s,
`import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";`,
`import {
  Card, CardAction, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { NotLoaded, RefreshButton } from "./refresh";
import { useAdminRefresh, useOnDemand } from "./refresh-context";`,
"imports");

// Acting on a report changes what Flagged, Manage reports and the attention
// list show, so all three reload after a successful action.
s = swap(s,
`  const flip = row.autoWinner === "red" ? "blue" : "red";
  const id = row.reportId as Id<"matchReports">;`,
`  const flip = row.autoWinner === "red" ? "blue" : "red";
  const id = row.reportId as Id<"matchReports">;
  const { refresh } = useAdminRefresh();
  const reloadReports = () => void refresh(["flagged", "manage", "attention"]);`,
"ReportRow: refresh hook");
s = swap(s,
`      toast.success("Flag dismissed");`,
`      toast.success("Flag dismissed");
      reloadReports();`,
"ReportRow: dismiss");
s = swap(s,
`      toast.success("Flag restored");`,
`      toast.success("Flag restored");
      reloadReports();`,
"ReportRow: restore");
s = swap(s,
`      setAction("none");
      setReason("");
      setConfirmText("");
    } catch (error) {`,
`      setAction("none");
      setReason("");
      setConfirmText("");
      reloadReports();
    } catch (error) {`,
"ReportRow: winner/delete");

// Flagged
s = swapIn(s, "FlaggedReports",
`  const rows = useQuery(api.admin.reports, { onlyFlagged: true });`,
`  const { data: rows, loading, updatedAt, refresh } =
    useOnDemand("flagged", api.admin.reports, { onlyFlagged: true });`,
"query");
s = swapIn(s, "FlaggedReports",
`          the report is edited afterwards.
        </CardDescription>
      </CardHeader>`,
`          the report is edited afterwards.
        </CardDescription>
        <CardAction>
          <RefreshButton onRefresh={refresh} loading={loading} updatedAt={updatedAt} />
        </CardAction>
      </CardHeader>`,
"header");
s = swapIn(s, "FlaggedReports",
`        {rows === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) :`,
`        {rows === undefined ? (
          <NotLoaded loading={loading} />
        ) :`,
"loading");

// Manage reports
s = swapIn(s, "ManageReports",
`  const rows = useQuery(api.admin.reports, { onlyFlagged: false });`,
`  const { data: rows, loading, updatedAt, refresh } =
    useOnDemand("manage", api.admin.reports, { onlyFlagged: false });`,
"query");
s = swapIn(s, "ManageReports",
`          scout actually observed.
        </CardDescription>
      </CardHeader>`,
`          scout actually observed.
        </CardDescription>
        <CardAction>
          <RefreshButton onRefresh={refresh} loading={loading} updatedAt={updatedAt} />
        </CardAction>
      </CardHeader>`,
"header");
s = swapIn(s, "ManageReports",
`        {rows === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) :`,
`        {rows === undefined ? (
          <NotLoaded loading={loading} />
        ) :`,
"loading");

// Pit reports
s = swapIn(s, "PitReportsAdmin",
`  const rows = useQuery(api.admin.pitReports, {});`,
`  const { data: rows, loading, updatedAt, refresh } =
    useOnDemand("pit", api.admin.pitReports, {});`,
"query");
s = swapIn(s, "PitReportsAdmin",
`      toast.success(\`Pit report for \${teamNumber} deleted\`);`,
`      toast.success(\`Pit report for \${teamNumber} deleted\`);
      void refresh();`,
"delete");
s = swapIn(s, "PitReportsAdmin",
`          so an edit updates it in place rather than adding a second.
        </CardDescription>
      </CardHeader>`,
`          so an edit updates it in place rather than adding a second.
        </CardDescription>
        <CardAction>
          <RefreshButton onRefresh={refresh} loading={loading} updatedAt={updatedAt} />
        </CardAction>
      </CardHeader>`,
"header");
s = swapIn(s, "PitReportsAdmin",
`        {rows === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) :`,
`        {rows === undefined ? (
          <NotLoaded loading={loading} />
        ) :`,
"loading");

// Teams needing attention
s = swapIn(s, "TeamsNeedingAttention",
`  const rows = useQuery(api.attention.forEvent);`,
`  const { data: rows, loading, updatedAt, refresh } =
    useOnDemand("attention", api.attention.forEvent, {});`,
"query");
s = swapIn(s, "TeamsNeedingAttention",
`          pick nobody warned you about.
        </CardDescription>
      </CardHeader>`,
`          pick nobody warned you about.
        </CardDescription>
        <CardAction>
          <RefreshButton onRefresh={refresh} loading={loading} updatedAt={updatedAt} />
        </CardAction>
      </CardHeader>`,
"header");
s = swapIn(s, "TeamsNeedingAttention",
`        {rows === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) :`,
`        {rows === undefined ? (
          <NotLoaded loading={loading} />
        ) :`,
"loading");
s = swapIn(s, "TeamsNeedingAttention",
`              row={row as AttentionRow} showTeam />`,
`              row={row as AttentionRow} showTeam onSettled={() => void refresh()} />`,
"settle");

writeFileSync(p, s);
console.log("src/routes/admin/reports-admin.tsx patched");
MJS
bun /tmp/ar2.mjs

say "Usage by team: join the page refresh"
cat > /tmp/ar3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./ar-lib.mjs";
const p = "src/routes/admin/usage-card.tsx";
let s = readFileSync(p, "utf8");
if (s.includes("useRegisterRefresh")) { console.log("usage card already patched"); process.exit(0); }

s = swap(s,
`import { cn } from "@/lib/utils";`,
`import { cn } from "@/lib/utils";
import { useRegisterRefresh } from "./refresh-context";`,
"imports");

// run returns its promise, so "Refresh admin page" can wait for it.
s = swap(s,
`  const run = useCallback((isCurrent: () => boolean) => {
    fetchUsage()`,
`  const run = useCallback((isCurrent: () => boolean) =>
    fetchUsage()`,
"run returns");
s = swap(s,
`      .finally(() => {
        if (isCurrent()) setLoading(false);
      });
  }, [fetchUsage]);`,
`      .finally(() => {
        if (isCurrent()) setLoading(false);
      }), [fetchUsage]);`,
"run close");
s = swap(s,
`    run(() => current);`,
`    void run(() => current);`,
"effect");
s = swap(s,
`  const refresh = () => {
    setLoading(true);
    run(() => true);
  };
`,
`  const refresh = useCallback(() => {
    setLoading(true);
    return run(() => true);
  }, [run]);
  useRegisterRefresh("usage", refresh);
`,
"refresh");
s = swap(s,
`onClick={refresh}>`,
`onClick={() => void refresh()}>`,
"button");

writeFileSync(p, s);
console.log("src/routes/admin/usage-card.tsx patched");
MJS
bun /tmp/ar3.mjs

say "Admin page: registry, Events on demand, Refresh admin page next to the title"
cat > /tmp/ar4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./ar-lib.mjs";
const p = "src/routes/admin/index.tsx";
let s = readFileSync(p, "utf8");
if (s.includes("AdminPageBody")) { console.log("admin page already patched"); process.exit(0); }

// An earlier version of this patch wrapped the page without the Events card.
// Undo that wrapping first, then apply this version as if fresh.
if (s.includes("AdminRefreshProvider")) {
  s = swap(s,
`import { AdminRefreshProvider, RefreshAdminPageButton } from "./refresh";
`, ``, "earlier version: import");
  s = swap(s,
`    <AdminRefreshProvider>
    <PageShell
      title={<>Admin <RefreshAdminPageButton /></>}`,
`    <PageShell
      title="Admin"`, "earlier version: open");
  s = swap(s,
`    </PageShell>
    </AdminRefreshProvider>
  );
}`,
`    </PageShell>
  );
}`, "earlier version: close");
  console.log("upgrading from the earlier version of this patch");
}

s = swap(s,
`import { UsageByTeamCard } from "./usage-card";`,
`import { UsageByTeamCard } from "./usage-card";
import {
  AdminRefreshProvider, NotLoaded, RefreshAdminPageButton, RefreshButton,
} from "./refresh";
import { useOnDemand } from "./refresh-context";`,
"imports");

s = swap(s,
`import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";`,
`import {
  Card, CardAction, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";`,
"card imports");

// The registry has to sit ABOVE the page's own hooks for the Events card to
// register, so the page splits into a provider shell and its body.
s = swap(s,
`export default function AdminPage() {
  const events = useQuery(api.events.list);`,
`export default function AdminPage() {
  return (
    <AdminRefreshProvider>
      <AdminPageBody />
    </AdminRefreshProvider>
  );
}

function AdminPageBody() {
  // Loaded on demand: events.list reads every imported event's teams,
  // matches and pit reports, and as a subscription it re-ran on every
  // submission at any of them.
  const {
    data: events, loading: eventsLoading, updatedAt: eventsUpdatedAt,
    refresh: refreshEvents,
  } = useOnDemand("events", api.events.list, {});`,
"page split");

s = swap(s,
`    <PageShell
      title="Admin"`,
`    <PageShell
      title={<>Admin <RefreshAdminPageButton /></>}`,
"title");

// Events card: Refresh in the corner, and a failed first load says so.
s = swap(s,
`            down changes nothing about its data.
          </CardDescription>
        </CardHeader>`,
`            down changes nothing about its data.
          </CardDescription>
          <CardAction>
            <RefreshButton onRefresh={refreshEvents} loading={eventsLoading}
              updatedAt={eventsUpdatedAt} />
          </CardAction>
        </CardHeader>`,
"events header");
s = swap(s,
`          {events === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) :`,
`          {events === undefined ? (
            <NotLoaded loading={eventsLoading} />
          ) :`,
"events loading");

// Everything that changes the list reloads it once it succeeds.
s = swap(s,
`      setEventKey("");`,
`      setEventKey("");
      void refreshEvents();`,
"after import");
s = swap(s,
`                    onClick={() => void setActiveForTeam({
                      eventId: null, teamNumber: targetTeam,
                    })}>`,
`                    onClick={() => void setActiveForTeam({
                      eventId: null, teamNumber: targetTeam,
                    }).then(() => refreshEvents())}>`,
"after stand down");
s = swap(s,
`                    onClick={() => void setActiveForTeam({
                      eventId: event._id, teamNumber: targetTeam,
                    })}>`,
`                    onClick={() => void setActiveForTeam({
                      eventId: event._id, teamNumber: targetTeam,
                    }).then(() => refreshEvents())}>`,
"after activate");
s = swap(s,
`                        setPurgeTarget(null);
                        setPurgeKey("");
                      })`,
`                        setPurgeTarget(null);
                        setPurgeKey("");
                        void refreshEvents();
                      })`,
"after delete");
s = swap(s,
`                          setRemoving(null);
                          setConfirmKey("");`,
`                          setRemoving(null);
                          setConfirmKey("");
                          void refreshEvents();`,
"after remove");
s = swap(s,
`                              .then((r) => toast.success(\`\${r.name} recovered\`))`,
`                              .then((r) => {
                                toast.success(\`\${r.name} recovered\`);
                                void refreshEvents();
                              })`,
"after recover");

writeFileSync(p, s);
console.log("src/routes/admin/index.tsx patched");
MJS
bun /tmp/ar4.mjs
rm -f /tmp/ar-lib.mjs /tmp/ar1.mjs /tmp/ar2.mjs /tmp/ar3.mjs /tmp/ar4.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
