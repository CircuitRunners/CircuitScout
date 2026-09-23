import { useConvex } from "convex/react";
import { ChevronDown, LoaderCircle, RefreshCw } from "lucide-react";
import { useCallback, useEffect, useState } from "react";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import type { UsageRow } from "../../../convex/admin";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardAction, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { cn } from "@/lib/utils";
import { useRegisterRefresh } from "./refresh-context";

type EventUsage = {
  eventId: Id<"events">;
  name: string;
  tbaEventKey: string;
  rows: UsageRow[];
};

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;

/**
 * Scouting activity per team at each event. Loaded on demand rather than
 * subscribed: the queries behind it read every report at every event, which
 * is fine once when someone looks and expensive if it re-ran on each
 * submission.
 */
export function UsageByTeamCard({ myTeamNumber }: { myTeamNumber: number | undefined }) {
  const convex = useConvex();
  const [events, setEvents] = useState<EventUsage[] | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [updatedAt, setUpdatedAt] = useState<number | null>(null);
  // Open/closed per event, kept across refreshes. Absent means "default",
  // which is open for the newest event and closed for the rest.
  const [open, setOpen] = useState<Record<string, boolean>>({});

  const fetchUsage = useCallback(async (): Promise<EventUsage[]> => {
    const list = await convex.query(api.admin.usageEvents, {});
    const loaded = await Promise.all(
      list.map(async (e) => ({
        ...e,
        rows: await convex.query(api.admin.usageForEvent, { eventId: e.eventId }),
      })),
    );
    return loaded.filter((e) => e.rows.length > 0);
  }, [convex]);

  // State is only set once the queries settle, never synchronously here.
  const run = useCallback((isCurrent: () => boolean) =>
    fetchUsage()
      .then((loaded) => {
        if (!isCurrent()) return;
        setEvents(loaded);
        setError(null);
        setUpdatedAt(Date.now());
      })
      .catch((err: unknown) => {
        if (isCurrent()) setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => {
        if (isCurrent()) setLoading(false);
      }), [fetchUsage]);

  useEffect(() => {
    let current = true;
    void run(() => current);
    return () => { current = false; };
  }, [run]);

  const refresh = useCallback(() => {
    setLoading(true);
    return run(() => true);
  }, [run]);
  useRegisterRefresh("usage", refresh);

  const isOpen = (eventId: string, index: number) => open[eventId] ?? index === 0;

  return (
    <Card>
      <CardHeader>
        <CardTitle>Usage by team</CardTitle>
        <CardDescription>
          Scouting activity by team at each event. Loads when you open this
          page, not live.
        </CardDescription>
        <CardAction className="flex flex-col items-end gap-1">
          <Button variant="outline" size="sm" disabled={loading} onClick={() => void refresh()}>
            {loading ? (
              <LoaderCircle className="size-3.5 animate-spin" />
            ) : (
              <RefreshCw className="size-3.5" />
            )}
            Refresh
          </Button>
          {updatedAt ? (
            <span className="text-muted-foreground text-xs">
              Updated {new Date(updatedAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}
            </span>
          ) : null}
        </CardAction>
      </CardHeader>
      <CardContent className="space-y-3">
        {error ? (
          <p className="text-destructive text-sm">Couldn't load usage. {error}</p>
        ) : events === null ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) : events.length === 0 ? (
          <p className="text-muted-foreground text-sm">
            No scouting yet. Numbers appear once reports come in.
          </p>
        ) : (
          events.map((event, index) => {
            const expanded = isOpen(event.eventId, index);
            const totals = event.rows.reduce(
              (t, r) => ({
                scouts: t.scouts + r.scouts,
                match: t.match + r.matchReports,
                pit: t.pit + r.pitReports,
              }),
              { scouts: 0, match: 0, pit: 0 },
            );
            const teamCount = event.rows.filter((r) => r.teamNumber !== null).length;
            return (
              <div key={event.eventId} className="overflow-hidden rounded-lg border">
                <button
                  type="button"
                  aria-expanded={expanded}
                  onClick={() => setOpen((o) => ({ ...o, [event.eventId]: !expanded }))}
                  className={cn(
                    "bg-muted/50 hover:bg-muted flex w-full items-center gap-2.5 px-3 py-2.5 text-left",
                    expanded && "border-b",
                  )}
                >
                  <ChevronDown
                    className={cn(
                      "text-muted-foreground size-4 shrink-0 transition-transform",
                      !expanded && "-rotate-90",
                    )}
                  />
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-baseline gap-2">
                      <span className="truncate text-sm font-medium">{event.name}</span>
                      <span className="text-muted-foreground font-mono text-xs">{event.tbaEventKey}</span>
                    </div>
                    <div className="text-muted-foreground mt-0.5 text-xs">
                      {plural(teamCount, "team")} · {plural(totals.scouts, "scout")} ·{" "}
                      {totals.match} match · {totals.pit} pit
                    </div>
                  </div>
                </button>
                {expanded ? (
                  <div className="overflow-x-auto">
                    <table className="w-full text-sm">
                      <thead className="text-muted-foreground">
                        <tr>
                          <th className="px-3 py-2 text-left font-normal">Team</th>
                          <th className="px-3 py-2 text-right font-normal">Scouts</th>
                          <th className="px-3 py-2 text-right font-normal">Match reports</th>
                          <th className="px-3 py-2 text-right font-normal">Pit reports</th>
                        </tr>
                      </thead>
                      <tbody>
                        {[...event.rows]
                          // Your own team first, then busiest first.
                          .sort((a, b) =>
                            Number(b.teamNumber === myTeamNumber) - Number(a.teamNumber === myTeamNumber))
                          .map((row) => (
                            <tr key={row.teamNumber ?? "none"} className="border-t">
                              <td className="px-3 py-2">
                                {row.teamNumber ?? (
                                  <span className="text-muted-foreground">No team</span>
                                )}
                                {row.teamNumber !== null && row.teamNumber === myTeamNumber ? (
                                  <Badge variant="secondary" className="ml-2">yours</Badge>
                                ) : null}
                              </td>
                              <td className="px-3 py-2 text-right tabular-nums">{row.scouts}</td>
                              <td className="px-3 py-2 text-right tabular-nums">{row.matchReports}</td>
                              <td className="px-3 py-2 text-right tabular-nums">{row.pitReports}</td>
                            </tr>
                          ))}
                      </tbody>
                    </table>
                  </div>
                ) : null}
              </div>
            );
          })
        )}
        <p className="text-muted-foreground text-xs">
          Reports are a rough guide. Most database use comes from phones
          viewing pages, which isn't counted here.
        </p>
      </CardContent>
    </Card>
  );
}
