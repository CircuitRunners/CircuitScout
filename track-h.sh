#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# track-h.sh — Track H: compare views, match preview, coverage/QA, CSV export.
# Run ONCE from the REPO ROOT. Owns convex/stats.ts, convex/exports.ts,
# src/routes/matches/*, src/routes/teams/compare.tsx, src/routes/admin/data.tsx,
# src/components/compare-table.tsx. No schema change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f package.json ]] || { echo "ERROR: run from the folder with package.json" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
mkdir -p convex/lib src/components src/routes/matches src/routes/teams src/routes/admin

say "Convex: shared report maths"
cat > convex/lib/summarise.ts <<'EOF'
import { climbPoints, countedTeleopFuel, uncountedTeleopFuel } from "./scoring";
import type { Doc } from "../_generated/dataModel";

export type Summary = {
  reportCount: number;
  avgAutoFuel: number;
  avgTeleopFuel: number;
  avgUncountedFuel: number;
  avgEndgameFuel: number;
  avgTotalFuel: number;
  avgClimbPoints: number;
  avgDriver: number;
  avgDefense: number;
  avgAccuracy: number;
  avgBps: number;
  bpsReportCount: number;
  minTotalFuel: number;
  maxTotalFuel: number;
  brokeCount: number;
  inconsistentCount: number;
};

export const EMPTY_SUMMARY: Summary = {
  reportCount: 0, avgAutoFuel: 0, avgTeleopFuel: 0, avgUncountedFuel: 0,
  avgEndgameFuel: 0, avgTotalFuel: 0, avgClimbPoints: 0, avgDriver: 0,
  avgDefense: 0, avgAccuracy: 0, avgBps: 0, bpsReportCount: 0,
  minTotalFuel: 0, maxTotalFuel: 0, brokeCount: 0, inconsistentCount: 0,
};

const mean = (xs: number[]) =>
  xs.length === 0 ? 0 : xs.reduce((a, b) => a + b, 0) / xs.length;

/** One report's derived numbers, given whether its alliance won auto. */
export function derive(report: Doc<"matchReports">, isAutoWinner: boolean | null) {
  const counted =
    isAutoWinner === null
      ? Object.values(report.teleop.byShift).reduce((a, b) => a + b, 0)
      : countedTeleopFuel(report.teleop.byShift, isAutoWinner);
  const dead =
    isAutoWinner === null ? 0 : uncountedTeleopFuel(report.teleop.byShift, isAutoWinner);

  return {
    counted,
    dead,
    total: report.auto.fuel + counted + report.endgame.fuel,
    climb: climbPoints(report.auto.climbL1, report.endgame.climb),
  };
}

export function summarise(
  entries: { report: Doc<"matchReports">; isAutoWinner: boolean | null }[],
): Summary {
  if (entries.length === 0) return { ...EMPTY_SUMMARY };

  const auto: number[] = [], tele: number[] = [], dead: number[] = [];
  const end: number[] = [], totals: number[] = [], climbs: number[] = [];
  const drv: number[] = [], def: number[] = [], acc: number[] = [], bps: number[] = [];
  let broke = 0, inconsistent = 0;

  for (const { report, isAutoWinner } of entries) {
    const d = derive(report, isAutoWinner);
    auto.push(report.auto.fuel);
    tele.push(d.counted);
    dead.push(d.dead);
    end.push(report.endgame.fuel);
    totals.push(d.total);
    climbs.push(d.climb);
    drv.push(report.ratings.driver);
    def.push(report.ratings.defense);
    acc.push(report.ratings.accuracy);
    // Reports written before avgBps existed must not average in as zero.
    if (report.avgBps !== undefined) bps.push(report.avgBps);
    if (report.ratings.broke) broke += 1;
    if (report.ratings.inconsistent) inconsistent += 1;
  }

  return {
    reportCount: entries.length,
    avgAutoFuel: mean(auto),
    avgTeleopFuel: mean(tele),
    avgUncountedFuel: mean(dead),
    avgEndgameFuel: mean(end),
    avgTotalFuel: mean(totals),
    avgClimbPoints: mean(climbs),
    avgDriver: mean(drv),
    avgDefense: mean(def),
    avgAccuracy: mean(acc),
    avgBps: mean(bps),
    bpsReportCount: bps.length,
    minTotalFuel: Math.min(...totals),
    maxTotalFuel: Math.max(...totals),
    brokeCount: broke,
    inconsistentCount: inconsistent,
  };
}
EOF

say "Convex: stats"
cat > convex/stats.ts <<'EOF'
import { v } from "convex/values";
import { query } from "./_generated/server";
import type { QueryCtx } from "./_generated/server";
import { activeEvent } from "./lib/guards";
import { submittedBeforeMatchEnd } from "./lib/scoring";
import { EMPTY_SUMMARY, derive, summarise, type Summary } from "./lib/summarise";
import type { Doc, Id } from "./_generated/dataModel";

/** Whether each report's team was on the alliance that won auto. */
function winnerFlags(
  reports: Doc<"matchReports">[],
  matchById: Map<Id<"matches">, Doc<"matches">>,
  teamById: Map<Id<"teams">, Doc<"teams">>,
): Map<Id<"matchReports">, boolean | null> {
  const flags = new Map<Id<"matchReports">, boolean | null>();
  for (const r of reports) {
    const match = matchById.get(r.matchId);
    const team = teamById.get(r.teamId);
    if (r.autoWinner === null || !match || !team) {
      flags.set(r._id, null);
      continue;
    }
    const onRed = match.redTeamNumbers.includes(team.number);
    flags.set(r._id, r.autoWinner === (onRed ? "red" : "blue"));
  }
  return flags;
}

async function loadEvent(ctx: QueryCtx) {
  const event = await activeEvent(ctx);
  if (!event) return null;

  const [reports, matches, teams] = await Promise.all([
    ctx.db.query("matchReports").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
    ctx.db.query("matches").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
    ctx.db.query("teams").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
  ]);

  const matchById = new Map(matches.map((m) => [m._id, m]));
  const teamById = new Map(teams.map((t) => [t._id, t]));
  const teamByNumber = new Map(teams.map((t) => [t.number, t]));

  return {
    event, reports, matches, teams,
    matchById, teamById, teamByNumber,
    flags: winnerFlags(reports, matchById, teamById),
  };
}

export const forEvent = query({
  args: {},
  handler: async (ctx): Promise<Record<string, Summary>> => {
    const loaded = await loadEvent(ctx);
    if (!loaded) return {};

    const byTeam = new Map<Id<"teams">, { report: Doc<"matchReports">; isAutoWinner: boolean | null }[]>();
    for (const report of loaded.reports) {
      const list = byTeam.get(report.teamId) ?? [];
      list.push({ report, isAutoWinner: loaded.flags.get(report._id) ?? null });
      byTeam.set(report.teamId, list);
    }

    const out: Record<string, Summary> = {};
    for (const team of loaded.teams) {
      out[team._id] = summarise(byTeam.get(team._id) ?? []);
    }
    return out;
  },
});

export type CompareRow = {
  teamNumber: number;
  nickname: string;
  pitScouted: boolean;
  stats: Summary;
};

/** Aligned season averages for the teams asked for, in the order asked for. */
export const compare = query({
  args: { teamNumbers: v.array(v.number()) },
  handler: async (ctx, args): Promise<CompareRow[]> => {
    const loaded = await loadEvent(ctx);
    if (!loaded) return [];

    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", loaded.event._id))
      .collect();
    const scouted = new Set(pit.map((p) => p.teamId));

    return args.teamNumbers.flatMap((number) => {
      const team = loaded.teamByNumber.get(number);
      if (!team) return [];
      const entries = loaded.reports
        .filter((r) => r.teamId === team._id)
        .map((report) => ({ report, isAutoWinner: loaded.flags.get(report._id) ?? null }));
      return [{
        teamNumber: team.number,
        nickname: team.nickname,
        pitScouted: scouted.has(team._id),
        stats: entries.length ? summarise(entries) : { ...EMPTY_SUMMARY },
      }];
    });
  },
});

/**
 * A match, with each robot's season averages AND what it actually did in this
 * match if anyone scouted it. The two together answer different questions:
 * averages say what to expect, the actuals say what happened.
 */
export const forMatch = query({
  args: { matchNumber: v.number() },
  handler: async (ctx, args) => {
    const loaded = await loadEvent(ctx);
    if (!loaded) return null;

    const match = loaded.matches.find((m) => m.matchNumber === args.matchNumber);
    if (!match) return null;

    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    const side = (numbers: number[]) =>
      numbers.flatMap((number) => {
        const team = loaded.teamByNumber.get(number);
        if (!team) {
          return [{
            teamNumber: number, nickname: "Not at this event",
            stats: { ...EMPTY_SUMMARY }, thisMatch: [],
          }];
        }

        const season = loaded.reports
          .filter((r) => r.teamId === team._id)
          .map((report) => ({ report, isAutoWinner: loaded.flags.get(report._id) ?? null }));

        const thisMatch = loaded.reports
          .filter((r) => r.teamId === team._id && r.matchId === match._id)
          .map((report) => {
            const d = derive(report, loaded.flags.get(report._id) ?? null);
            return {
              scoutName: nameByUser.get(report.scoutId) ?? "Unknown scout",
              autoFuel: report.auto.fuel,
              teleopFuel: d.counted,
              deadFuel: d.dead,
              endgameFuel: report.endgame.fuel,
              totalFuel: d.total,
              climbPoints: d.climb,
              driver: report.ratings.driver,
              defense: report.ratings.defense,
              accuracy: report.ratings.accuracy,
              broke: report.ratings.broke,
              inconsistent: report.ratings.inconsistent,
              finalNotes: report.finalNotes ?? "",
            };
          });

        return [{
          teamNumber: team.number,
          nickname: team.nickname,
          stats: season.length ? summarise(season) : { ...EMPTY_SUMMARY },
          thisMatch,
        }];
      });

    return {
      matchNumber: match.matchNumber,
      scheduledTime: match.scheduledTime,
      red: side(match.redTeamNumbers),
      blue: side(match.blueTeamNumbers),
    };
  },
});

/** Is the data trustworthy? The view that decides whether anything else is. */
export const coverage = query({
  args: {},
  handler: async (ctx) => {
    const loaded = await loadEvent(ctx);
    if (!loaded) {
      return { matches: [], teamsNoPit: [], teamsNoMatch: [], byScout: [], totals: null };
    }

    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", loaded.event._id))
      .collect();
    const pitScouted = new Set(pit.map((p) => p.teamId));

    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    const reportsByMatch = new Map<Id<"matches">, Doc<"matchReports">[]>();
    for (const r of loaded.reports) {
      const list = reportsByMatch.get(r.matchId) ?? [];
      list.push(r);
      reportsByMatch.set(r.matchId, list);
    }

    const matches = loaded.matches
      .map((match) => {
        const rows = reportsByMatch.get(match._id) ?? [];
        const covered = new Set(
          rows.flatMap((r) => {
            const team = loaded.teamById.get(r.teamId);
            return team ? [team.number] : [];
          }),
        );
        const expected = [...match.redTeamNumbers, ...match.blueTeamNumbers];
        return {
          matchNumber: match.matchNumber,
          reportCount: rows.length,
          missing: expected.filter((n) => !covered.has(n)),
        };
      })
      .filter((m) => m.missing.length > 0)
      .sort((a, b) => a.matchNumber - b.matchNumber);

    const reportCountByTeam = new Map<Id<"teams">, number>();
    for (const r of loaded.reports) {
      reportCountByTeam.set(r.teamId, (reportCountByTeam.get(r.teamId) ?? 0) + 1);
    }

    const byScoutMap = new Map<string, { name: string; count: number; noSplit: number; early: number }>();
    for (const r of loaded.reports) {
      const key = r.scoutId;
      const row = byScoutMap.get(key) ?? {
        name: nameByUser.get(r.scoutId) ?? "Unknown scout",
        count: 0, noSplit: 0, early: 0,
      };
      row.count += 1;
      if (r.hubStateSource === "none") row.noSplit += 1;
      if (submittedBeforeMatchEnd(r.matchStartedAt, r.submittedAt)) row.early += 1;
      byScoutMap.set(key, row);
    }

    return {
      matches,
      teamsNoPit: loaded.teams
        .filter((t) => !pitScouted.has(t._id))
        .map((t) => t.number)
        .sort((a, b) => a - b),
      teamsNoMatch: loaded.teams
        .filter((t) => (reportCountByTeam.get(t._id) ?? 0) === 0)
        .map((t) => t.number)
        .sort((a, b) => a - b),
      byScout: [...byScoutMap.values()].sort((a, b) => b.count - a.count),
      totals: {
        teams: loaded.teams.length,
        matches: loaded.matches.length,
        reports: loaded.reports.length,
        possible: loaded.matches.length * 6,
      },
    };
  },
});
EOF

say "Convex: CSV export"
cat > convex/exports.ts <<'EOF'
import { v } from "convex/values";
import { query } from "./_generated/server";
import { activeEvent, requireUser } from "./lib/guards";
import { derive } from "./lib/summarise";

/** RFC 4180 quoting: wrap in quotes and double any quote inside. */
function cell(value: string | number | boolean | null | undefined): string {
  const text = value === null || value === undefined ? "" : String(value);
  return `"${text.replace(/"/g, '""')}"`;
}

const toCsv = (header: string[], rows: (string | number | boolean | null)[][]) =>
  [header.map(cell).join(","), ...rows.map((r) => r.map(cell).join(","))].join("\n");

/**
 * The escape hatch. Strategy leads want the data in a spreadsheet, and an
 * export is what you fall back on when the app is unreachable — which is
 * exactly when venue wifi fails.
 */
export const csv = query({
  args: {
    kind: v.union(
      v.literal("teams"),
      v.literal("matchReports"),
      v.literal("pitReports"),
    ),
  },
  handler: async (ctx, args): Promise<string> => {
    await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) return "";

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const teamById = new Map(teams.map((t) => [t._id, t]));

    if (args.kind === "teams") {
      return toCsv(
        ["number", "nickname", "city", "stateProv", "country", "tbaTeamKey"],
        teams
          .sort((a, b) => a.number - b.number)
          .map((t) => [t.number, t.nickname, t.city, t.stateProv, t.country, t.tbaTeamKey]),
      );
    }

    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    if (args.kind === "pitReports") {
      const pit = await ctx.db
        .query("pitReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      return toCsv(
        ["team", "nickname", "scout", "drivetrain", "turret", "drumFullWidth",
         "drumNarrow", "fixedShooter", "kitbot", "otherScoring", "climbLow",
         "climbMid", "climbHigh", "climbAuto", "underTrench", "overBump",
         "robotNotes", "otherNotes"],
        pit.flatMap((p) => {
          const team = teamById.get(p.teamId);
          if (!team) return [];
          return [[
            team.number, team.nickname, nameByUser.get(p.scoutId) ?? "",
            p.drivetrain, p.scoring.turret, p.scoring.drumFullWidth,
            p.scoring.drumNonFullWidth, p.scoring.fixed, p.scoring.kitbot,
            p.scoring.other ? p.scoring.otherText : "",
            p.climb.low, p.climb.mid, p.climb.high, p.climb.duringAuto,
            p.underTrench, p.overBump, p.robotNotes, p.otherNotes,
          ]];
        }),
      );
    }

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const matchById = new Map(matches.map((m) => [m._id, m]));

    return toCsv(
      ["match", "team", "nickname", "alliance", "scout", "autoFuel",
       "autoClimbL1", "autoFouls", "teleopCounted", "teleopDead",
       "transition", "s1", "s2", "s3", "s4", "endgameFuel", "endgameClimb",
       "totalFuel", "climbPoints", "driver", "defense", "accuracy", "avgBps",
       "shootsOnMove", "broke", "inconsistent", "autoWinner",
       "hubStateSource", "finalNotes"],
      reports.flatMap((r) => {
        const team = teamById.get(r.teamId);
        const match = matchById.get(r.matchId);
        if (!team) return [];
        const onRed = match?.redTeamNumbers.includes(team.number) ?? false;
        const alliance = onRed ? "red" : "blue";
        const isWinner = r.autoWinner === null ? null : r.autoWinner === alliance;
        const d = derive(r, isWinner);
        return [[
          match?.matchNumber ?? "", team.number, team.nickname, alliance,
          nameByUser.get(r.scoutId) ?? "",
          r.auto.fuel, r.auto.climbL1, r.auto.fouls,
          d.counted, d.dead,
          r.teleop.byShift.transition, r.teleop.byShift.s1, r.teleop.byShift.s2,
          r.teleop.byShift.s3, r.teleop.byShift.s4,
          r.endgame.fuel, r.endgame.climb,
          d.total, d.climb,
          r.ratings.driver, r.ratings.defense, r.ratings.accuracy,
          r.avgBps ?? "",
          r.ratings.shootsOnMove, r.ratings.broke, r.ratings.inconsistent,
          r.autoWinner ?? "", r.hubStateSource, r.finalNotes ?? "",
        ]];
      }),
    );
  },
});
EOF

say "Client: shared compare table"
cat > src/components/compare-table.tsx <<'EOF'
type Summary = {
  reportCount: number;
  avgAutoFuel: number;
  avgTeleopFuel: number;
  avgUncountedFuel: number;
  avgEndgameFuel: number;
  avgTotalFuel: number;
  avgClimbPoints: number;
  avgDriver: number;
  avgDefense: number;
  avgAccuracy: number;
  avgBps: number;
  bpsReportCount: number;
  minTotalFuel: number;
  maxTotalFuel: number;
  brokeCount: number;
  inconsistentCount: number;
};

export type CompareColumn = {
  teamNumber: number;
  nickname: string;
  stats: Summary;
};

type Metric = {
  label: string;
  get: (s: Summary) => number;
  higherIsBetter: boolean;
  decimals?: number;
  suffix?: string;
};

const METRICS: ReadonlyArray<Metric> = [
  { label: "Reports", get: (s) => s.reportCount, higherIsBetter: true, decimals: 0 },
  { label: "Total fuel", get: (s) => s.avgTotalFuel, higherIsBetter: true },
  { label: "Auto fuel", get: (s) => s.avgAutoFuel, higherIsBetter: true },
  { label: "Teleop fuel", get: (s) => s.avgTeleopFuel, higherIsBetter: true },
  { label: "Endgame fuel", get: (s) => s.avgEndgameFuel, higherIsBetter: true },
  { label: "Dead-hub fuel", get: (s) => s.avgUncountedFuel, higherIsBetter: false },
  { label: "Climb points", get: (s) => s.avgClimbPoints, higherIsBetter: true },
  { label: "Driver", get: (s) => s.avgDriver, higherIsBetter: true },
  { label: "Defense", get: (s) => s.avgDefense, higherIsBetter: true },
  { label: "Accuracy", get: (s) => s.avgAccuracy, higherIsBetter: true, suffix: "%" },
  { label: "BPS", get: (s) => s.avgBps, higherIsBetter: true },
  { label: "Broke", get: (s) => s.brokeCount, higherIsBetter: false, decimals: 0 },
  { label: "Inconsistent", get: (s) => s.inconsistentCount, higherIsBetter: false, decimals: 0 },
];

export function CompareTable({ columns }: { columns: CompareColumn[] }) {
  if (columns.length === 0) return null;

  return (
    <div className="overflow-x-auto rounded-lg border">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b">
            <th className="p-3 text-left font-medium">Metric</th>
            {columns.map((c) => (
              <th key={c.teamNumber} className="p-3 text-right font-medium">
                <div className="tabular-nums">{c.teamNumber}</div>
                <div className="text-muted-foreground max-w-32 truncate text-xs font-normal">
                  {c.nickname}
                </div>
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {METRICS.map((metric) => {
            const values = columns.map((c) => metric.get(c.stats));
            // Only mark a winner when the column actually differ; highlighting
            // a tie implies a distinction that is not there.
            const best = metric.higherIsBetter
              ? Math.max(...values)
              : Math.min(...values);
            const allSame = values.every((v) => v === values[0]);

            return (
              <tr key={metric.label} className="border-b last:border-0">
                <td className="text-muted-foreground p-3">{metric.label}</td>
                {columns.map((c, i) => {
                  const value = values[i] ?? 0;
                  const isBest = !allSame && value === best;
                  return (
                    <td
                      key={c.teamNumber}
                      className={[
                        "p-3 text-right tabular-nums",
                        isBest ? "font-semibold" : "",
                      ].join(" ")}
                    >
                      {value.toFixed(metric.decimals ?? 1)}
                      {metric.suffix ?? ""}
                    </td>
                  );
                })}
              </tr>
            );
          })}
          <tr className="border-t">
            <td className="text-muted-foreground p-3">Range (total fuel)</td>
            {columns.map((c) => (
              <td key={c.teamNumber} className="text-muted-foreground p-3 text-right text-xs tabular-nums">
                {c.stats.reportCount === 0
                  ? "—"
                  : `${c.stats.minTotalFuel}–${c.stats.maxTotalFuel}`}
              </td>
            ))}
          </tr>
        </tbody>
      </table>
    </div>
  );
}
EOF

say "Client: team compare"
cat > src/routes/teams/compare.tsx <<'EOF'
import { useQuery } from "convex/react";
import { X } from "lucide-react";
import { useSearchParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { CompareTable } from "@/components/compare-table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useState } from "react";

const MAX = 4;

export default function ComparePage() {
  const [searchParams, setSearchParams] = useSearchParams();
  const [search, setSearch] = useState("");

  const selected = (searchParams.get("teams") ?? "")
    .split(",")
    .map((n) => Number.parseInt(n, 10))
    .filter((n) => !Number.isNaN(n));

  const teams = useQuery(api.teams.listWithStatus);
  const rows = useQuery(
    api.stats.compare,
    selected.length > 0 ? { teamNumbers: selected } : "skip",
  );

  const setSelected = (next: number[]) => {
    const params = new URLSearchParams(searchParams);
    if (next.length === 0) params.delete("teams");
    else params.set("teams", next.join(","));
    setSearchParams(params, { replace: true });
  };

  const add = (n: number) => {
    if (selected.includes(n) || selected.length >= MAX) return;
    setSelected([...selected, n]);
    setSearch("");
  };

  const candidates = (teams ?? [])
    .filter((t) => !selected.includes(t.number))
    .filter((t) => {
      const needle = search.trim().toLowerCase();
      if (needle === "") return false;
      return (
        String(t.number).includes(needle) ||
        t.nickname.toLowerCase().includes(needle)
      );
    })
    .slice(0, 8);

  return (
    <PageShell
      title="Compare teams"
      description="Up to four teams on the same metric rows. The URL holds the selection, so this page is shareable."
    >
      <div className="flex flex-wrap items-center gap-2">
        {selected.map((n) => (
          <Badge key={n} variant="secondary" className="h-9 px-3 text-sm">
            {n}
            <button
              className="ml-1"
              aria-label={`Remove team ${n}`}
              onClick={() => setSelected(selected.filter((x) => x !== n))}
            >
              <X className="size-3" />
            </button>
          </Badge>
        ))}
        {selected.length < MAX ? (
          <Input
            className="max-w-56"
            placeholder="Add a team"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        ) : (
          <span className="text-muted-foreground text-xs">
            Four is the maximum — beyond that the rows stop being readable.
          </span>
        )}
      </div>

      {candidates.length > 0 ? (
        <div className="flex flex-wrap gap-2">
          {candidates.map((t) => (
            <Button key={t._id} size="sm" variant="outline" onClick={() => add(t.number)}>
              {t.number} · {t.nickname}
            </Button>
          ))}
        </div>
      ) : null}

      {selected.length === 0 ? (
        <p className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
          Add two or more teams to compare them.
        </p>
      ) : rows === undefined ? (
        <p className="text-muted-foreground text-sm">Loading…</p>
      ) : (
        <>
          <CompareTable columns={rows} />
          <p className="text-muted-foreground text-xs">
            Bold marks the best value in each row. Compare report counts before
            trusting a gap — an average over two matches and one over eleven are
            not the same claim.
          </p>
        </>
      )}
    </PageShell>
  );
}
EOF

say "Client: matches list and preview"
cat > src/routes/matches/index.tsx <<'EOF'
import { useQuery } from "convex/react";
import { ChevronRight } from "lucide-react";
import { useMemo, useState } from "react";
import { Link } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export default function MatchesPage() {
  const matches = useQuery(api.matches.listForEvent);
  const [search, setSearch] = useState("");

  const shown = useMemo(() => {
    if (!matches) return [];
    const needle = search.trim();
    if (needle === "") return matches;
    const n = Number.parseInt(needle, 10);
    return matches.filter(
      (m) =>
        String(m.matchNumber) === needle ||
        (!Number.isNaN(n) &&
          (m.redTeamNumbers.includes(n) || m.blueTeamNumbers.includes(n))),
    );
  }, [matches, search]);

  return (
    <PageShell
      title="Matches"
      description="Open a match to see all six robots side by side before you play it."
    >
      <Input
        className="max-w-72"
        placeholder="Match number or team number"
        inputMode="numeric"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
      />

      {matches === undefined ? (
        <p className="text-muted-foreground text-sm">Loading…</p>
      ) : shown.length === 0 ? (
        <p className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
          {matches.length === 0 ? "No schedule imported yet." : "Nothing matches."}
        </p>
      ) : (
        <div className="space-y-1">
          {shown.map((match) => (
            <Button
              key={match._id}
              variant="outline"
              className="h-auto w-full justify-start py-3"
              render={<Link to={`/matches/${match.matchNumber}`} />}
            >
              <span className="font-medium">Qual {match.matchNumber}</span>
              <span className="text-muted-foreground ml-2 min-w-0 flex-1 truncate text-left text-xs">
                <span className="text-red-600 dark:text-red-400">
                  {match.redTeamNumbers.join(", ")}
                </span>
                {" vs "}
                <span className="text-blue-600 dark:text-blue-400">
                  {match.blueTeamNumbers.join(", ")}
                </span>
              </span>
              <ChevronRight className="size-4 shrink-0" />
            </Button>
          ))}
        </div>
      )}
    </PageShell>
  );
}
EOF

cat > src/routes/matches/preview.tsx <<'EOF'
import { useQuery } from "convex/react";
import { AlertTriangle, ArrowLeft } from "lucide-react";
import { Link, useParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { CompareTable } from "@/components/compare-table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

type Robot = {
  teamNumber: number;
  nickname: string;
  stats: { avgTotalFuel: number; avgClimbPoints: number; reportCount: number };
  thisMatch: {
    scoutName: string;
    autoFuel: number;
    teleopFuel: number;
    deadFuel: number;
    endgameFuel: number;
    totalFuel: number;
    climbPoints: number;
    driver: number;
    defense: number;
    accuracy: number;
    broke: boolean;
    inconsistent: boolean;
    finalNotes: string;
  }[];
};

function projected(side: Robot[]) {
  return side.reduce(
    (sum, r) => sum + r.stats.avgTotalFuel + r.stats.avgClimbPoints,
    0,
  );
}

function Actuals({ side, label }: { side: Robot[]; label: string }) {
  const any = side.some((r) => r.thisMatch.length > 0);
  if (!any) return null;

  return (
    <div className="space-y-2">
      <h3 className="text-sm font-medium">{label} — what happened</h3>
      {side.map((robot) =>
        robot.thisMatch.map((report, i) => (
          <div key={`${robot.teamNumber}-${i}`} className="space-y-1 rounded-lg border p-3 text-sm">
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-medium tabular-nums">{robot.teamNumber}</span>
              <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                {robot.nickname} · {report.scoutName}
              </span>
            </div>
            <div className="text-muted-foreground flex flex-wrap gap-3 text-xs tabular-nums">
              <span>auto {report.autoFuel}</span>
              <span>teleop {report.teleopFuel}</span>
              <span>endgame {report.endgameFuel}</span>
              <span className="font-medium">total {report.totalFuel}</span>
              {report.deadFuel > 0 ? <span>dead {report.deadFuel}</span> : null}
              <span>climb {report.climbPoints}</span>
              <span>drv {report.driver}</span>
              <span>def {report.defense}</span>
              <span>acc {report.accuracy}%</span>
            </div>
            {report.broke || report.inconsistent ? (
              <p className="text-destructive flex items-center gap-1 text-xs">
                <AlertTriangle className="size-3" />
                {report.broke ? "Broke down" : ""}
                {report.broke && report.inconsistent ? " · " : ""}
                {report.inconsistent ? "Inconsistent" : ""}
              </p>
            ) : null}
            {report.finalNotes ? <p className="text-xs">{report.finalNotes}</p> : null}
          </div>
        )),
      )}
    </div>
  );
}

export default function MatchPreviewPage() {
  const params = useParams();
  const matchNumber = Number.parseInt(params.matchNumber ?? "", 10);
  const data = useQuery(
    api.stats.forMatch,
    Number.isNaN(matchNumber) ? "skip" : { matchNumber },
  );

  if (Number.isNaN(matchNumber)) {
    return <PageShell title="Match preview" description="Bad URL." />;
  }
  if (data === undefined) {
    return <PageShell title="Match preview" description="Loading…" />;
  }
  if (data === null) {
    return (
      <PageShell title="Match preview" description="That match is not at the active event.">
        <Button variant="outline" render={<Link to="/matches" />}>
          <ArrowLeft className="size-4" /> Back
        </Button>
      </PageShell>
    );
  }

  const redProjected = projected(data.red);
  const blueProjected = projected(data.blue);

  return (
    <PageShell
      title={`Qual ${data.matchNumber}`}
      description="Season averages predict; the reports below record what actually happened."
      actions={
        <Button variant="outline" render={<Link to="/matches" />}>
          <ArrowLeft className="size-4" /> All matches
        </Button>
      }
    >
      <Card>
        <CardHeader>
          <CardTitle>Projected alliance output</CardTitle>
          <CardDescription>
            Sum of each robot's average total fuel and climb points. A crude
            estimate that ignores defense, field interference and robots with
            no data — treat it as a starting point, not a prediction.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex gap-6">
          <div>
            <p className="text-xs text-red-600 dark:text-red-400">Red</p>
            <p className="text-3xl font-semibold tabular-nums">
              {redProjected.toFixed(0)}
            </p>
          </div>
          <div>
            <p className="text-xs text-blue-600 dark:text-blue-400">Blue</p>
            <p className="text-3xl font-semibold tabular-nums">
              {blueProjected.toFixed(0)}
            </p>
          </div>
          {data.red.concat(data.blue).some((r) => r.stats.reportCount === 0) ? (
            <Badge variant="outline" className="self-center">
              Some robots have no data
            </Badge>
          ) : null}
        </CardContent>
      </Card>

      <h3 className="font-medium text-red-600 dark:text-red-400">Red alliance</h3>
      <CompareTable columns={data.red} />

      <h3 className="font-medium text-blue-600 dark:text-blue-400">Blue alliance</h3>
      <CompareTable columns={data.blue} />

      <Actuals side={data.red} label="Red" />
      <Actuals side={data.blue} label="Blue" />
    </PageShell>
  );
}
EOF

say "Client: coverage and export"
cat > src/routes/admin/data.tsx <<'EOF'
import { useConvex, useQuery } from "convex/react";
import { Download } from "lucide-react";
import { useState } from "react";
import { Link } from "react-router";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

const KINDS = [
  { kind: "teams" as const, label: "Teams" },
  { kind: "matchReports" as const, label: "Match reports" },
  { kind: "pitReports" as const, label: "Pit reports" },
];

export default function AdminDataPage() {
  const data = useQuery(api.stats.coverage);
  const convex = useConvex();
  const [busy, setBusy] = useState<string | null>(null);

  const download = async (kind: (typeof KINDS)[number]["kind"], label: string) => {
    setBusy(kind);
    try {
      const csv = await convex.query(api.exports.csv, { kind });
      const url = URL.createObjectURL(new Blob([csv], { type: "text/csv" }));
      const link = document.createElement("a");
      link.href = url;
      link.download = `circuitscout-${kind}.csv`;
      link.click();
      URL.revokeObjectURL(url);
      toast.success(`${label} exported`);
    } catch (error) {
      toast.error("Export failed", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(null);
    }
  };

  const totals = data?.totals ?? null;

  return (
    <PageShell
      title="Coverage and quality"
      description="Whether the numbers everywhere else are worth trusting."
    >
      {totals ? (
        <div className="grid gap-4 sm:grid-cols-3">
          <Card>
            <CardHeader>
              <CardDescription>Reports</CardDescription>
              <CardTitle className="text-3xl tabular-nums">
                {totals.reports}
                <span className="text-muted-foreground text-lg">
                  /{totals.possible}
                </span>
              </CardTitle>
            </CardHeader>
          </Card>
          <Card>
            <CardHeader>
              <CardDescription>Teams never pit scouted</CardDescription>
              <CardTitle className="text-3xl tabular-nums">
                {data?.teamsNoPit.length ?? 0}
              </CardTitle>
            </CardHeader>
          </Card>
          <Card>
            <CardHeader>
              <CardDescription>Teams with no match data</CardDescription>
              <CardTitle className="text-3xl tabular-nums">
                {data?.teamsNoMatch.length ?? 0}
              </CardTitle>
            </CardHeader>
          </Card>
        </div>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>Matches with gaps</CardTitle>
          <CardDescription>
            Robots nobody covered. Six per match is full coverage.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {data === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : data.matches.length === 0 ? (
            <p className="text-muted-foreground text-sm">
              Every scheduled robot has at least one report.
            </p>
          ) : (
            data.matches.map((m) => (
              <div key={m.matchNumber} className="flex flex-wrap items-center gap-2 rounded-lg border p-3 text-sm">
                <Button size="sm" variant="ghost"
                  render={<Link to={`/matches/${m.matchNumber}`} />}>
                  Qual {m.matchNumber}
                </Button>
                <span className="text-muted-foreground text-xs">
                  {m.reportCount} report{m.reportCount === 1 ? "" : "s"} · missing
                </span>
                {m.missing.map((n) => (
                  <Badge key={n} variant="outline" className="tabular-nums">{n}</Badge>
                ))}
              </div>
            ))
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Teams with no data</CardTitle>
          <CardDescription>
            These cannot be ranked on anything. Unscouted is not the same as bad,
            and a pick list that treats them alike will quietly bury a good robot.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <div>
            <p className="text-muted-foreground mb-1 text-xs">No pit report</p>
            <div className="flex flex-wrap gap-1">
              {(data?.teamsNoPit ?? []).length === 0 ? (
                <span className="text-muted-foreground text-sm">None.</span>
              ) : (
                data?.teamsNoPit.map((n) => (
                  <Button key={n} size="sm" variant="outline" render={<Link to={`/pit/${n}`} />}>
                    {n}
                  </Button>
                ))
              )}
            </div>
          </div>
          <div>
            <p className="text-muted-foreground mb-1 text-xs">No match reports</p>
            <div className="flex flex-wrap gap-1">
              {(data?.teamsNoMatch ?? []).length === 0 ? (
                <span className="text-muted-foreground text-sm">None.</span>
              ) : (
                data?.teamsNoMatch.map((n) => (
                  <Button key={n} size="sm" variant="outline"
                    render={<Link to={`/teams?team=${n}`} />}>
                    {n}
                  </Button>
                ))
              )}
            </div>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>By scout</CardTitle>
          <CardDescription>
            Volume, plus how many of each scout's reports lack a shift split or
            were finished before the buzzer. High counts usually mean the Match
            Start button is being missed, not that someone is careless.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {(data?.byScout ?? []).map((s) => (
            <div key={s.name} className="flex flex-wrap items-center gap-2 rounded-lg border p-3 text-sm">
              <span className="min-w-0 flex-1 truncate font-medium">{s.name}</span>
              <span className="text-muted-foreground text-xs tabular-nums">
                {s.count} report{s.count === 1 ? "" : "s"}
              </span>
              {s.noSplit > 0 ? (
                <Badge variant="outline">{s.noSplit} no split</Badge>
              ) : null}
              {s.early > 0 ? (
                <Badge variant="destructive">{s.early} early</Badge>
              ) : null}
            </div>
          ))}
          {(data?.byScout ?? []).length === 0 ? (
            <p className="text-muted-foreground text-sm">No reports yet.</p>
          ) : null}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Export</CardTitle>
          <CardDescription>
            CSV of the active event. Also your fallback when the app is
            unreachable — which is exactly when venue wifi fails.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap gap-2">
          {KINDS.map((k) => (
            <Button key={k.kind} variant="outline" disabled={busy !== null}
              onClick={() => void download(k.kind, k.label)}>
              <Download className="size-4" />
              {k.label}
            </Button>
          ))}
        </CardContent>
      </Card>
    </PageShell>
  );
}
EOF

say "Compare link on the teams page"
cat > /tmp/h1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/teams/index.tsx";
let s = readFileSync(p, "utf8");
if (s.includes("/teams/compare")) { console.log("already linked"); process.exit(0); }
s = s.replace('import { useSearchParams } from "react-router";',
              'import { Link, useSearchParams } from "react-router";');
s = s.replace(`          : \`\${teams.length} teams at this event. Tap one for its full record.\`
      }
    >`,
`          : \`\${teams.length} teams at this event. Tap one for its full record.\`
      }
      actions={
        <Button variant="outline" render={<Link to="/teams/compare" />}>
          Compare teams
        </Button>
      }
    >`);
writeFileSync(p, s);
console.log("src/routes/teams/index.tsx patched");
MJS
bun /tmp/h1.mjs
rm -f /tmp/h1.mjs

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Track H written.
    /teams/compare        compare up to four teams
    /matches              schedule, searchable
    /matches/:n           six robots side by side, plus what actually happened
    /admin/data           coverage, per-scout quality, CSV export

DONE
