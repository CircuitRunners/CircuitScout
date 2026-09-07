#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# track-i.sh — Track I: browse inactive events.
#
# DEPARTS FROM PLAN §11.2. The plan proposed a global viewing mode that
# retargeted the whole app. That needs an optional eventKey threaded through
# every read query in five files owned by three tracks, and a missed mutation
# would write scouting data into an archive.
#
# This is the isolated version: its own read-only queries, its own screens,
# nothing existing touched. Less UI reuse, no way to corrupt live data.
#
# No schema change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/lib/summarise.ts ]] || { echo "ERROR: run track-h.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
mkdir -p convex src/routes/archive

say "Convex: archive reads"
cat > convex/archive.ts <<'EOF'
import { v } from "convex/values";
import { query } from "./_generated/server";
import { currentTeamNumber, requireUser } from "./lib/guards";
import { summarise, type Summary } from "./lib/summarise";
import type { Doc, Id } from "./_generated/dataModel";

/**
 * Read-only by construction. Every function here takes an explicit event key
 * and none of them can write, so nothing in this file can put scouting data
 * into the wrong competition.
 */

export const events = query({
  args: {},
  handler: async (ctx) => {
    await requireUser(ctx);
    const myTeam = await currentTeamNumber(ctx);

    const all = await ctx.db.query("events").collect();
    const settings = await ctx.db.query("teamSettings").collect();

    const rows = [];
    for (const event of all) {
      const teams = await ctx.db
        .query("teams")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const matches = await ctx.db
        .query("matches")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const reports = await ctx.db
        .query("matchReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();

      const activeForTeams = settings
        .filter((t) => t.activeEventId === event._id)
        .map((t) => t.teamNumber);

      rows.push({
        eventKey: event.tbaEventKey,
        name: event.name,
        season: Number.parseInt(event.tbaEventKey.slice(0, 4), 10),
        teamCount: teams.length,
        matchCount: matches.length,
        reportCount: reports.length,
        activeForTeams,
        isMine: myTeam !== undefined && activeForTeams.includes(myTeam),
      });
    }

    return rows.sort((a, b) =>
      b.season - a.season || a.name.localeCompare(b.name));
  },
});

export const teamTable = query({
  args: { eventKey: v.string() },
  handler: async (ctx, args) => {
    await requireUser(ctx);

    const event = await ctx.db
      .query("events")
      .withIndex("by_key", (q) => q.eq("tbaEventKey", args.eventKey))
      .unique();
    if (!event) return null;

    const [teams, matches, reports] = await Promise.all([
      ctx.db.query("teams").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ctx.db.query("matches").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ctx.db.query("matchReports").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
    ]);

    const matchById = new Map(matches.map((m) => [m._id, m]));
    const teamById = new Map(teams.map((t) => [t._id, t]));

    const byTeam = new Map<
      Id<"teams">,
      { report: Doc<"matchReports">; isAutoWinner: boolean | null }[]
    >();
    for (const report of reports) {
      const match = matchById.get(report.matchId);
      const team = teamById.get(report.teamId);
      let isAutoWinner: boolean | null = null;
      if (report.autoWinner !== null && match && team) {
        const onRed = match.redTeamNumbers.includes(team.number);
        isAutoWinner = report.autoWinner === (onRed ? "red" : "blue");
      }
      const list = byTeam.get(report.teamId) ?? [];
      list.push({ report, isAutoWinner });
      byTeam.set(report.teamId, list);
    }

    const rows: {
      teamNumber: number;
      nickname: string;
      stats: Summary;
    }[] = teams.map((team) => ({
      teamNumber: team.number,
      nickname: team.nickname,
      stats: summarise(byTeam.get(team._id) ?? []),
    }));

    return {
      eventKey: event.tbaEventKey,
      name: event.name,
      matchCount: matches.length,
      rows: rows.sort((a, b) => a.teamNumber - b.teamNumber),
    };
  },
});
EOF

say "Client: archive screens"
cat > src/routes/archive/index.tsx <<'EOF'
import { useQuery } from "convex/react";
import { Archive, ChevronRight } from "lucide-react";
import { useState } from "react";
import { Link, useNavigate } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import {
  Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";

export default function ArchivePage() {
  const events = useQuery(api.archive.events);
  const navigate = useNavigate();
  // Ephemeral by design: a refresh shows the gate again, so a tab left open
  // overnight cannot come back still pointed at an old competition.
  const [entered, setEntered] = useState(false);

  return (
    <PageShell
      title="Past events"
      description="Read-only. Nothing here can be scouted, ranked or edited."
    >
      <Dialog open={!entered} onOpenChange={(next) => { if (!next) void navigate(-1); }}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>You are about to read old data</DialogTitle>
            <DialogDescription>
              These numbers are from competitions that are over.
            </DialogDescription>
          </DialogHeader>
          <p className="text-muted-foreground text-sm">
            Nothing on these pages affects your current event. Quoting a figure
            from here in an alliance meeting is the mistake this dialog exists
            to prevent.
          </p>
          <div className="flex gap-2">
            <Button onClick={() => setEntered(true)}>
              <Archive className="size-4" /> Show me
            </Button>
            <Button variant="outline" onClick={() => void navigate(-1)}>
              Take me back
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      {entered ? (
        <Card>
          <CardHeader>
            <CardTitle>Events</CardTitle>
            <CardDescription>
              Every event imported into this deployment, newest season first.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-1">
            {events === undefined ? (
              <p className="text-muted-foreground text-sm">Loading…</p>
            ) : events.length === 0 ? (
              <p className="text-muted-foreground text-sm">Nothing imported yet.</p>
            ) : (
              events.map((event) => (
                <Button key={event.eventKey} variant="outline"
                  className="h-auto w-full justify-start py-3"
                  render={<Link to={`/archive/${event.eventKey}`} />}>
                  <span className="min-w-0 flex-1 text-left">
                    <span className="font-medium">{event.name}</span>
                    <span className="text-muted-foreground ml-2 text-xs">
                      {event.eventKey} · {event.teamCount} teams ·{" "}
                      {event.reportCount} reports
                    </span>
                  </span>
                  {event.isMine ? (
                    <Badge variant="destructive" className="shrink-0">
                      Your live event
                    </Badge>
                  ) : event.activeForTeams.length > 0 ? (
                    <Badge variant="outline" className="shrink-0">
                      Live for {event.activeForTeams.join(", ")}
                    </Badge>
                  ) : null}
                  <ChevronRight className="size-4 shrink-0" />
                </Button>
              ))
            )}
          </CardContent>
        </Card>
      ) : null}
    </PageShell>
  );
}
EOF

cat > src/routes/archive/event.tsx <<'EOF'
import { useQuery } from "convex/react";
import { ArrowLeft, TriangleAlert } from "lucide-react";
import { useMemo, useState } from "react";
import { Link, useParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

type SortKey = "number" | "totalFuel" | "climbPoints" | "driver" | "defense";

const COLUMNS: ReadonlyArray<{ key: SortKey; label: string }> = [
  { key: "number", label: "Team" },
  { key: "totalFuel", label: "Fuel" },
  { key: "climbPoints", label: "Climb" },
  { key: "driver", label: "Driver" },
  { key: "defense", label: "Defense" },
];

export default function ArchiveEventPage() {
  const params = useParams();
  const eventKey = params.eventKey ?? "";
  const data = useQuery(api.archive.teamTable, eventKey ? { eventKey } : "skip");

  const [search, setSearch] = useState("");
  const [sort, setSort] = useState<SortKey>("number");

  const rows = useMemo(() => {
    const all = data?.rows ?? [];
    const needle = search.trim().toLowerCase();
    const filtered = needle === ""
      ? all
      : all.filter((r) =>
          String(r.teamNumber).includes(needle) ||
          r.nickname.toLowerCase().includes(needle));

    return [...filtered].sort((a, b) => {
      switch (sort) {
        case "number": return a.teamNumber - b.teamNumber;
        case "totalFuel": return b.stats.avgTotalFuel - a.stats.avgTotalFuel;
        case "climbPoints": return b.stats.avgClimbPoints - a.stats.avgClimbPoints;
        case "driver": return b.stats.avgDriver - a.stats.avgDriver;
        case "defense": return b.stats.avgDefense - a.stats.avgDefense;
      }
    });
  }, [data, search, sort]);

  if (data === undefined) {
    return <PageShell title="Past event" description="Loading…" />;
  }
  if (data === null) {
    return (
      <PageShell title="Past event" description="No event with that key.">
        <Button variant="outline" render={<Link to="/archive" />}>
          <ArrowLeft className="size-4" /> All events
        </Button>
      </PageShell>
    );
  }

  return (
    <PageShell
      title={data.name}
      description={`${data.eventKey} · ${data.matchCount} qualification matches`}
      actions={
        <Button variant="outline" render={<Link to="/archive" />}>
          <ArrowLeft className="size-4" /> All events
        </Button>
      }
    >
      <div className="border-destructive text-destructive flex items-center gap-2 rounded-lg border p-3 text-sm">
        <TriangleAlert className="size-4 shrink-0" />
        Archived data. These numbers are not from your current competition.
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <Input className="max-w-56" placeholder="Team number or name"
          value={search} onChange={(e) => setSearch(e.target.value)} />
        {COLUMNS.map((c) => (
          <Button key={c.key} size="sm"
            variant={sort === c.key ? "default" : "outline"}
            onClick={() => setSort(c.key)}>
            {c.label}
          </Button>
        ))}
      </div>

      <div className="overflow-x-auto rounded-lg border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b">
              <th className="p-3 text-left font-medium">Team</th>
              <th className="p-3 text-right font-medium">Reports</th>
              <th className="p-3 text-right font-medium">Fuel</th>
              <th className="p-3 text-right font-medium">Climb</th>
              <th className="p-3 text-right font-medium">Driver</th>
              <th className="p-3 text-right font-medium">Defense</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.teamNumber} className="border-b last:border-0">
                <td className="p-3">
                  <span className="font-semibold tabular-nums">{row.teamNumber}</span>
                  <span className="text-muted-foreground ml-2 text-xs">
                    {row.nickname}
                  </span>
                </td>
                <td className="text-muted-foreground p-3 text-right text-xs tabular-nums">
                  {row.stats.reportCount}
                </td>
                <td className="p-3 text-right tabular-nums">
                  {row.stats.reportCount === 0 ? "—" : row.stats.avgTotalFuel.toFixed(1)}
                </td>
                <td className="p-3 text-right tabular-nums">
                  {row.stats.reportCount === 0 ? "—" : row.stats.avgClimbPoints.toFixed(1)}
                </td>
                <td className="p-3 text-right tabular-nums">
                  {row.stats.reportCount === 0 ? "—" : row.stats.avgDriver.toFixed(1)}
                </td>
                <td className="p-3 text-right tabular-nums">
                  {row.stats.reportCount === 0 ? "—" : row.stats.avgDefense.toFixed(1)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </PageShell>
  );
}
EOF

say "Routes and nav"
cat > /tmp/i1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

let r = readFileSync("src/routes/router.tsx", "utf8");
if (!r.includes("ArchivePage")) {
  r = r.replace('import DashboardPage from "./dashboard";',
    'import DashboardPage from "./dashboard";\nimport ArchivePage from "./archive/index";\nimport ArchiveEventPage from "./archive/event";');
  const anchor = '              { path: "matches", element: <MatchesPage /> },';
  if (!r.includes(anchor)) fail("could not find the matches route");
  r = r.replace(anchor, `${anchor}
              { path: "archive", element: <ArchivePage /> },
              { path: "archive/:eventKey", element: <ArchiveEventPage /> },`);
  writeFileSync("src/routes/router.tsx", r);
  console.log("src/routes/router.tsx patched");
}

let n = readFileSync("src/components/app-nav.tsx", "utf8");
if (!n.includes('to: "/archive"')) {
  const anchor = '  { to: "/picklists", label: "Pick Lists" },';
  if (!n.includes(anchor)) fail("could not find the nav list");
  n = n.replace(anchor, `${anchor}\n  { to: "/archive", label: "Past Events" },`);
  writeFileSync("src/components/app-nav.tsx", n);
  console.log("src/components/app-nav.tsx patched");
}
MJS
bun /tmp/i1.mjs
rm -f /tmp/i1.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
