#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# track-e.sh — Track E: team list, team detail modal, dashboard.
# Run ONCE from the REPO ROOT. Owns convex/teams.ts, src/routes/teams/*,
# src/routes/dashboard.tsx. No schema change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f package.json ]] || { echo "ERROR: run from the folder with package.json" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
mkdir -p convex src/routes/teams

say "shadcn dialog"
bunx shadcn@latest add -y dialog

say "Convex: teams"
cat > convex/teams.ts <<'EOF'
import { v } from "convex/values";
import { query } from "./_generated/server";
import type { QueryCtx } from "./_generated/server";
import { activeEvent } from "./lib/guards";
import {
  climbPoints, countedTeleopFuel, uncountedTeleopFuel,
} from "./lib/scoring";
import type { Id } from "./_generated/dataModel";

type Tier = "t1" | "t2" | "t3" | "dnp" | "uncategorized";

/**
 * Tier comes from the team primary list. Personal lists are the scout's own
 * working notes; the primary list is the one the team acts on, so that is what
 * belongs next to a team everywhere else in the app.
 */
async function primaryTiers(
  ctx: QueryCtx,
  eventId: Id<"events">,
): Promise<Map<string, Tier>> {
  const primary = await ctx.db
    .query("pickLists")
    .withIndex("by_event_owner", (q) =>
      q.eq("eventId", eventId).eq("ownerId", null))
    .first();
  if (!primary) return new Map();

  const entries = await ctx.db
    .query("pickListEntries")
    .withIndex("by_list", (q) => q.eq("pickListId", primary._id))
    .collect();

  return new Map(entries.map((e) => [e.teamId, e.tier]));
}

export const listWithStatus = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return [];

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();

    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const scouted = new Set(pit.map((p) => p.teamId));

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const counts = new Map<string, number>();
    for (const r of reports) {
      counts.set(r.teamId, (counts.get(r.teamId) ?? 0) + 1);
    }

    const tiers = await primaryTiers(ctx, event._id);

    return teams
      .sort((a, b) => a.number - b.number)
      .map((t) => ({
        ...t,
        pitScouted: scouted.has(t._id),
        reportCount: counts.get(t._id) ?? 0,
        tier: tiers.get(t._id) ?? ("uncategorized" as Tier),
      }));
  },
});

const mean = (xs: number[]) =>
  xs.length === 0 ? 0 : xs.reduce((a, b) => a + b, 0) / xs.length;

/** Everything the detail modal needs, in one subscription. */
export const detail = query({
  args: { teamNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;

    const team = await ctx.db
      .query("teams")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("number", args.teamNumber))
      .unique();
    if (!team) return null;

    const pitReport = await ctx.db
      .query("pitReports")
      .withIndex("by_event_team", (q) =>
        q.eq("eventId", event._id).eq("teamId", team._id))
      .unique();
    const photoUrl = pitReport?.photoId
      ? await ctx.storage.getUrl(pitReport.photoId)
      : null;

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event_team", (q) =>
        q.eq("eventId", event._id).eq("teamId", team._id))
      .collect();

    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const matchById = new Map(matches.map((m) => [m._id, m]));

    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    const rows = [];
    const autoF: number[] = [];
    const teleF: number[] = [];
    const deadF: number[] = [];
    const endF: number[] = [];
    const totals: number[] = [];
    const climbs: number[] = [];
    const drivers: number[] = [];
    const defenses: number[] = [];
    const accuracies: number[] = [];

    for (const report of reports) {
      const match = matchById.get(report.matchId);
      const onRed = match?.redTeamNumbers.includes(team.number) ?? false;
      const alliance: "red" | "blue" = onRed ? "red" : "blue";
      const isWinner =
        report.autoWinner === null ? null : report.autoWinner === alliance;

      const counted =
        isWinner === null
          ? Object.values(report.teleop.byShift).reduce((a, b) => a + b, 0)
          : countedTeleopFuel(report.teleop.byShift, isWinner);
      const dead =
        isWinner === null ? 0 : uncountedTeleopFuel(report.teleop.byShift, isWinner);
      const total = report.auto.fuel + counted + report.endgame.fuel;
      const climb = climbPoints(report.auto.climbL1, report.endgame.climb);

      autoF.push(report.auto.fuel);
      teleF.push(counted);
      deadF.push(dead);
      endF.push(report.endgame.fuel);
      totals.push(total);
      climbs.push(climb);
      drivers.push(report.ratings.driver);
      defenses.push(report.ratings.defense);
      accuracies.push(report.ratings.accuracy);

      const edits = await ctx.db
        .query("reportEdits")
        .withIndex("by_report", (q) => q.eq("reportId", report._id))
        .collect();

      rows.push({
        reportId: report._id,
        matchNumber: match?.matchNumber ?? 0,
        alliance,
        scoutName: nameByUser.get(report.scoutId) ?? "Unknown scout",
        autoFuel: report.auto.fuel,
        teleopFuel: counted,
        deadFuel: dead,
        endgameFuel: report.endgame.fuel,
        totalFuel: total,
        climb: report.endgame.climb,
        climbPoints: climb,
        autoClimb: report.auto.climbL1,
        driver: report.ratings.driver,
        defense: report.ratings.defense,
        accuracy: report.ratings.accuracy,
        broke: report.ratings.broke,
        brokeNotes: report.ratings.brokeNotes,
        inconsistent: report.ratings.inconsistent,
        inconsistentNotes: report.ratings.inconsistentNotes,
        shootsOnMove: report.ratings.shootsOnMove,
        finalNotes: report.finalNotes ?? "",
        hubStateSource: report.hubStateSource,
        editCount: edits.length,
        submittedAt: report.submittedAt,
      });
    }

    rows.sort((a, b) => a.matchNumber - b.matchNumber);

    const tiers = await primaryTiers(ctx, event._id);

    return {
      team,
      pitReport,
      photoUrl,
      pitScoutName: pitReport
        ? (nameByUser.get(pitReport.scoutId) ?? "Unknown scout")
        : null,
      tier: tiers.get(team._id) ?? ("uncategorized" as Tier),
      reports: rows,
      stats: {
        reportCount: reports.length,
        avgAutoFuel: mean(autoF),
        avgTeleopFuel: mean(teleF),
        avgUncountedFuel: mean(deadF),
        avgEndgameFuel: mean(endF),
        avgTotalFuel: mean(totals),
        avgClimbPoints: mean(climbs),
        avgDriver: mean(drivers),
        avgDefense: mean(defenses),
        avgAccuracy: mean(accuracies),
        minTotalFuel: totals.length ? Math.min(...totals) : 0,
        maxTotalFuel: totals.length ? Math.max(...totals) : 0,
      },
    };
  },
});
EOF

say "Client: team detail modal"
cat > src/routes/teams/team-detail.tsx <<'EOF'
import { useQuery } from "convex/react";
import { AlertTriangle, Pencil, Wrench } from "lucide-react";

import { api } from "../../../convex/_generated/api";
import { Badge } from "@/components/ui/badge";
import {
  Dialog, DialogContent, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { TIER_LABELS, type Tier } from "@/lib/types";

function Stat({
  label, value, suffix = "",
}: { label: string; value: number; suffix?: string }) {
  return (
    <div className="rounded-lg border p-3">
      <p className="text-muted-foreground text-xs">{label}</p>
      <p className="text-xl font-semibold tabular-nums">
        {value.toFixed(1)}{suffix}
      </p>
    </div>
  );
}

const CLIMB_LABEL: Record<string, string> = {
  none: "—", low: "L1", mid: "L2", high: "L3",
};

export function TeamDetail({
  teamNumber,
  onClose,
}: {
  teamNumber: number | null;
  onClose: () => void;
}) {
  const data = useQuery(
    api.teams.detail,
    teamNumber === null ? "skip" : { teamNumber },
  );

  return (
    <Dialog open={teamNumber !== null} onOpenChange={(open) => { if (!open) onClose(); }}>
      <DialogContent className="max-h-[85vh] max-w-3xl overflow-y-auto">
        {data === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) : data === null ? (
          <p className="text-muted-foreground text-sm">Team not found.</p>
        ) : (
          <>
            <DialogHeader>
              <DialogTitle className="flex flex-wrap items-center gap-2">
                <span className="tabular-nums">{data.team.number}</span>
                <span>{data.team.nickname}</span>
                {data.tier !== "uncategorized" ? (
                  <Badge>{TIER_LABELS[data.tier as Tier]}</Badge>
                ) : null}
              </DialogTitle>
            </DialogHeader>

            <p className="text-muted-foreground text-sm">
              {[data.team.city, data.team.stateProv, data.team.country]
                .filter(Boolean)
                .join(", ")}
            </p>

            {/* Report count sits next to the averages deliberately: an average
                over two matches and one over eleven are not comparable, and a
                bare number invites treating them as if they were. */}
            <div className="flex items-baseline gap-2">
              <h3 className="font-medium">Averages</h3>
              <span className="text-muted-foreground text-xs">
                from {data.stats.reportCount} report
                {data.stats.reportCount === 1 ? "" : "s"}
              </span>
            </div>

            {data.stats.reportCount === 0 ? (
              <p className="text-muted-foreground rounded-lg border border-dashed p-6 text-center text-sm">
                No match reports yet.
              </p>
            ) : (
              <>
                <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
                  <Stat label="Auto fuel" value={data.stats.avgAutoFuel} />
                  <Stat label="Teleop fuel" value={data.stats.avgTeleopFuel} />
                  <Stat label="Endgame fuel" value={data.stats.avgEndgameFuel} />
                  <Stat label="Total fuel" value={data.stats.avgTotalFuel} />
                  <Stat label="Climb points" value={data.stats.avgClimbPoints} />
                  <Stat label="Driver" value={data.stats.avgDriver} />
                  <Stat label="Defense" value={data.stats.avgDefense} />
                  <Stat label="Accuracy" value={data.stats.avgAccuracy} suffix="%" />
                  <Stat label="Dead-hub fuel" value={data.stats.avgUncountedFuel} />
                </div>

                {/* A mean of 30 could be 30/30/30 or 5/85/0, and consistency
                    is often what decides a second-round pick. */}
                <p className="text-muted-foreground text-xs">
                  Total fuel ranged {data.stats.minTotalFuel}–
                  {data.stats.maxTotalFuel} across those matches. Total fuel
                  counts only fuel scored into a live hub.
                </p>
              </>
            )}

            <h3 className="font-medium">Pit report</h3>
            {data.pitReport === null ? (
              <p className="text-muted-foreground rounded-lg border border-dashed p-6 text-center text-sm">
                Not pit scouted.
              </p>
            ) : (
              <div className="space-y-3 rounded-lg border p-3">
                {data.photoUrl ? (
                  <img src={data.photoUrl} alt={`Team ${data.team.number} robot`}
                    className="max-h-56 w-full rounded-md object-contain" />
                ) : null}
                <div className="flex flex-wrap gap-1">
                  {data.pitReport.scoring.turret ? <Badge variant="secondary">Turret</Badge> : null}
                  {data.pitReport.scoring.drumFullWidth ? <Badge variant="secondary">Full-width drum</Badge> : null}
                  {data.pitReport.scoring.drumNonFullWidth ? <Badge variant="secondary">Drum</Badge> : null}
                  {data.pitReport.scoring.fixed ? <Badge variant="secondary">Fixed shooter</Badge> : null}
                  {data.pitReport.scoring.kitbot ? <Badge variant="secondary">Kitbot</Badge> : null}
                  {data.pitReport.scoring.other ? (
                    <Badge variant="secondary">{data.pitReport.scoring.otherText || "Other"}</Badge>
                  ) : null}
                </div>
                <div className="flex flex-wrap gap-1">
                  {data.pitReport.climb.low ? <Badge variant="outline">L1</Badge> : null}
                  {data.pitReport.climb.mid ? <Badge variant="outline">L2</Badge> : null}
                  {data.pitReport.climb.high ? <Badge variant="outline">L3</Badge> : null}
                  {data.pitReport.climb.duringAuto ? <Badge variant="outline">Auto climb</Badge> : null}
                  {data.pitReport.underTrench ? <Badge variant="outline">Under trench</Badge> : null}
                  {data.pitReport.overBump ? <Badge variant="outline">Over bump</Badge> : null}
                </div>
                <p className="text-sm">
                  <Wrench className="mr-1 inline size-3" />
                  {data.pitReport.drivetrain || "Drivetrain not recorded"}
                </p>
                {data.pitReport.robotNotes ? (
                  <p className="text-sm">{data.pitReport.robotNotes}</p>
                ) : null}
                {data.pitReport.otherNotes ? (
                  <p className="text-muted-foreground text-sm">{data.pitReport.otherNotes}</p>
                ) : null}
                <p className="text-muted-foreground text-xs">
                  Scouted by {data.pitScoutName}
                </p>
              </div>
            )}

            <h3 className="font-medium">Match reports</h3>
            {data.reports.length === 0 ? (
              <p className="text-muted-foreground rounded-lg border border-dashed p-6 text-center text-sm">
                Nothing yet.
              </p>
            ) : (
              <div className="space-y-2">
                {data.reports.map((r) => (
                  <div key={r.reportId} className="space-y-1 rounded-lg border p-3 text-sm">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="font-medium">Qual {r.matchNumber}</span>
                      <Badge variant="outline" className="text-xs">{r.alliance}</Badge>
                      <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                        {r.scoutName}
                      </span>
                      {r.editCount > 0 ? (
                        <Badge variant="secondary" className="text-xs">
                          <Pencil className="size-3" />
                          edited
                        </Badge>
                      ) : null}
                      {r.hubStateSource === "none" ? (
                        <Badge variant="outline" className="text-xs">no shift split</Badge>
                      ) : null}
                    </div>
                    <div className="text-muted-foreground flex flex-wrap gap-3 text-xs tabular-nums">
                      <span>auto {r.autoFuel}</span>
                      <span>teleop {r.teleopFuel}</span>
                      <span>endgame {r.endgameFuel}</span>
                      <span className="font-medium">total {r.totalFuel}</span>
                      {r.deadFuel > 0 ? <span>dead {r.deadFuel}</span> : null}
                      <span>climb {CLIMB_LABEL[r.climb] ?? "—"}{r.autoClimb ? " +auto" : ""}</span>
                      <span>drv {r.driver}</span>
                      <span>def {r.defense}</span>
                      <span>acc {r.accuracy}%</span>
                    </div>
                    {r.broke || r.inconsistent ? (
                      <p className="text-destructive flex items-start gap-1 text-xs">
                        <AlertTriangle className="mt-0.5 size-3 shrink-0" />
                        {[r.broke ? `Broke: ${r.brokeNotes || "no detail"}` : null,
                          r.inconsistent ? `Inconsistent: ${r.inconsistentNotes || "no detail"}` : null]
                          .filter(Boolean).join(" · ")}
                      </p>
                    ) : null}
                    {r.finalNotes ? <p className="text-xs">{r.finalNotes}</p> : null}
                  </div>
                ))}
              </div>
            )}
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}
EOF

say "Client: team list"
cat > src/routes/teams/index.tsx <<'EOF'
import { useQuery } from "convex/react";
import { useMemo, useState } from "react";
import { useSearchParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { TeamDetail } from "./team-detail";
import { TeamCard } from "@/components/scouting/team-card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import type { Tier } from "@/lib/types";

type Filter = "all" | "no-pit" | "no-matches";

const FILTERS: ReadonlyArray<{ value: Filter; label: string }> = [
  { value: "all", label: "All" },
  { value: "no-pit", label: "Missing pit" },
  { value: "no-matches", label: "No match data" },
];

export default function TeamsPage() {
  const teams = useQuery(api.teams.listWithStatus);
  // The open team lives in the URL, not in a store: it makes a team shareable
  // and the back button correct.
  const [searchParams, setSearchParams] = useSearchParams();
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<Filter>("all");

  const openParam = searchParams.get("team");
  const openTeam = openParam === null ? null : Number.parseInt(openParam, 10);

  const shown = useMemo(() => {
    if (!teams) return [];
    const needle = search.trim().toLowerCase();
    return teams.filter((team) => {
      if (filter === "no-pit" && team.pitScouted) return false;
      if (filter === "no-matches" && team.reportCount > 0) return false;
      if (needle === "") return true;
      return (
        String(team.number).includes(needle) ||
        team.nickname.toLowerCase().includes(needle)
      );
    });
  }, [teams, search, filter]);

  const open = (teamNumber: number) => {
    const next = new URLSearchParams(searchParams);
    next.set("team", String(teamNumber));
    setSearchParams(next);
  };

  const close = () => {
    const next = new URLSearchParams(searchParams);
    next.delete("team");
    setSearchParams(next, { replace: true });
  };

  return (
    <PageShell
      title="Teams"
      description={
        teams === undefined
          ? "Loading…"
          : `${teams.length} teams at this event. Tap one for its full record.`
      }
    >
      <div className="flex flex-wrap items-center gap-2">
        {FILTERS.map((f) => (
          <Button
            key={f.value}
            size="sm"
            variant={filter === f.value ? "default" : "outline"}
            onClick={() => setFilter(f.value)}
          >
            {f.label}
          </Button>
        ))}
        <Input
          className="ml-auto max-w-56"
          placeholder="Team number or name"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
      </div>

      {teams === undefined ? (
        <p className="text-muted-foreground text-sm">Loading…</p>
      ) : shown.length === 0 ? (
        <p className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
          {teams.length === 0
            ? "No teams yet. An admin needs to import an event."
            : "Nothing matches."}
        </p>
      ) : (
        <div className="space-y-2">
          {shown.map((team) => (
            <TeamCard
              key={team._id}
              number={team.number}
              nickname={team.nickname}
              pitScouted={team.pitScouted}
              reportCount={team.reportCount}
              tier={team.tier as Tier}
              onClick={() => open(team.number)}
            />
          ))}
        </div>
      )}

      <TeamDetail
        teamNumber={openTeam !== null && !Number.isNaN(openTeam) ? openTeam : null}
        onClose={close}
      />
    </PageShell>
  );
}
EOF

say "Client: dashboard"
cat > src/routes/dashboard.tsx <<'EOF'
import { useQuery } from "convex/react";
import { Link } from "react-router";

import { api } from "../../convex/_generated/api";
import { PageShell } from "./page-shell";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

function Metric({
  label, value, hint,
}: { label: string; value: string; hint?: string }) {
  return (
    <Card>
      <CardHeader>
        <CardDescription>{label}</CardDescription>
        <CardTitle className="text-3xl tabular-nums">{value}</CardTitle>
      </CardHeader>
      {hint ? (
        <CardContent className="text-muted-foreground -mt-4 text-xs">{hint}</CardContent>
      ) : null}
    </Card>
  );
}

export default function DashboardPage() {
  const event = useQuery(api.events.active);
  const teams = useQuery(api.teams.listWithStatus);
  const matches = useQuery(api.matches.listForEvent);

  const total = teams?.length ?? 0;
  const pitDone = teams?.filter((t) => t.pitScouted).length ?? 0;
  const reports = teams?.reduce((sum, t) => sum + t.reportCount, 0) ?? 0;
  const noData = teams?.filter((t) => t.reportCount === 0).length ?? 0;

  // Six robots per match is full coverage. Anything less is a gap you want to
  // see now rather than during alliance selection.
  const expected = (matches?.length ?? 0) * 6;
  const coverage = expected === 0 ? 0 : Math.round((reports / expected) * 100);

  return (
    <PageShell
      title={event ? event.name : "No active event"}
      description={
        event
          ? `${event.tbaEventKey} · ${total} teams · ${matches?.length ?? 0} qualification matches`
          : "An admin needs to set up an event before scouting can begin."
      }
      actions={
        <div className="flex gap-2">
          <Button variant="outline" render={<Link to="/pit" />}>Pit</Button>
          <Button render={<Link to="/scout" />}>Scout a match</Button>
        </div>
      }
    >
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Metric label="Pit scouted" value={`${pitDone}/${total}`}
          hint={total - pitDone > 0 ? `${total - pitDone} still to do` : "Complete"} />
        <Metric label="Match reports" value={String(reports)} />
        <Metric label="Coverage" value={`${coverage}%`}
          hint={`of ${expected} possible robot-matches`} />
        <Metric label="Teams with no data" value={String(noData)}
          hint={noData > 0 ? "Unrankable until scouted" : "Every team has data"} />
      </div>

      {noData > 0 && teams ? (
        <Card>
          <CardHeader>
            <CardTitle>Teams with no match data</CardTitle>
            <CardDescription>
              These cannot be ranked on anything yet. Worth targeting before
              alliance selection.
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap gap-2">
            {teams
              .filter((t) => t.reportCount === 0)
              .map((t) => (
                <Button key={t._id} size="sm" variant="outline"
                  render={<Link to={`/teams?team=${t.number}`} />}>
                  {t.number}
                </Button>
              ))}
          </CardContent>
        </Card>
      ) : null}
    </PageShell>
  );
}
EOF

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Track E written. Open /teams and tap a team.

DONE
