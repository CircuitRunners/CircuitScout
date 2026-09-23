#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-multi-team.sh — getting ready for other teams on one deployment.
#
# 1. STORED TEAM STATS
#    stats.forEvent (pick list board, plot), stats.forMatch (match preview)
#    and stats.compare read every match report at the event and summarised
#    them on every run. Reports are pooled across scouting teams, so more
#    teams at one event meant more reports AND more phones re-reading them.
#
#      teamSummaries        one row per (event, team): the Summary itself
#      lib/teamSummaries.ts refreshTeamSummary (writes), summariesFor /
#                           summaryFor (reads), isAutoWinnerFor (shared rule)
#
#    Refreshed by: matchReports.submit, matchReports.update,
#    admin.setAutoWinner, admin.deleteReport. Purged with the event.
#    A TBA re-import schedules a rebuild for that event, since a revised
#    schedule can move a team to the other alliance and change which of its
#    fuel counted. A NEW write path that changes a report must call
#    refreshTeamSummary, or that team's stats go stale until a rebuild.
#
#    stats.matchCoverage and stats.coverage still read every report. They
#    count robot-match slots, which a per-team summary cannot answer.
#
# 2. USAGE BY TEAM (admin page, full admins only)
#    A card under "Configuring for": each event collapsible, totals in the
#    banner, one row per scouting team. Loaded once on open and on Refresh —
#    never a live subscription. Reads existing data; nothing new is written.
#
# 3. CROSS-TEAM FIXES
#    - Tiers on the teams list and team detail came from whichever team's
#      primary list the index returned first. Now: the caller's team's.
#    - Merge read every team's submitted lists when run by a full admin, and
#      wrote into the first primary list it found. Now: the caller's team only.
#    - Primary lists were editable only by full admins (any team's). Now: that
#      team's admins, plus full admins — the same rule as marking a team
#      picked. Other teams' admins can finally edit their own primary list.
#    - pickLists.get and entries.forList returned any list to anyone with its
#      id, signed in or not. Now: your own lists, your team's primary, and —
#      for team admins — lists by their own team's scouts.
#    - setAutoWinner, deleteReport, dismissFlag and deletePitReport let any
#      team admin act on another team's reports. Now refused.
#
# Schema: one new table. RUN ON PROD after deploying:
#
#   bunx convex run --prod events:rebuildAllTeamSummaries
#
# Until it runs, stats pages show zeros for existing reports on prod.
# ---------------------------------------------------------------------------
set -euo pipefail
grep -q "reportCounts:" convex/schema.ts 2>/dev/null \
  || { echo "ERROR: run patch-io-diet.sh and patch-io-counters.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# Helpers are imported relative to the importing file: Git Bash translates
# /tmp in arguments but not inside import strings.
cat > /tmp/mt-lib.mjs <<'MJS'
export function swap(s, from, to, label) {
  const i = s.indexOf(from);
  if (i < 0 || s.indexOf(from, i + 1) >= 0) {
    console.error(`ERROR: anchor ${i < 0 ? "missing" : "not unique"}: ${label}`);
    process.exit(1);
  }
  return s.slice(0, i) + to + s.slice(i + from.length);
}
export function swapAll(s, from, to, count, label) {
  const n = s.split(from).length - 1;
  if (n !== count) {
    console.error(`ERROR: expected ${count} of anchor, found ${n}: ${label}`);
    process.exit(1);
  }
  return s.split(from).join(to);
}
export function span(s, start, end, to, label) {
  const i = s.indexOf(start);
  const j = i < 0 ? -1 : s.indexOf(end, i + start.length);
  if (i < 0 || j < 0) {
    console.error(`ERROR: span anchor missing: ${label}`);
    process.exit(1);
  }
  return s.slice(0, i) + to + s.slice(j);
}
MJS

# ===========================================================================
say "1/3 Stored team stats: schema"
cat > /tmp/mt1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./mt-lib.mjs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
if (s.includes("teamSummaries:")) { console.log("schema already patched"); process.exit(0); }

s = swap(s,
`const tier = v.union(`,
`/** Mirrors Summary in lib/summarise.ts; a field added there must be added here. */
const summary = v.object({
  reportCount: v.number(),
  ratedReportCount: v.number(),
  avgAutoFuel: v.number(),
  avgTeleopFuel: v.number(),
  avgUncountedFuel: v.number(),
  avgEndgameFuel: v.number(),
  avgTotalFuel: v.number(),
  avgClimbPoints: v.number(),
  avgPassing: v.number(),
  avgDriver: v.number(),
  avgDefense: v.number(),
  avgAccuracy: v.number(),
  avgBps: v.number(),
  avgAdjustedBps: v.number(),
  bpsReportCount: v.number(),
  minTotalFuel: v.number(),
  maxTotalFuel: v.number(),
  brokeCount: v.number(),
  inconsistentCount: v.number(),
});

const tier = v.union(`,
"schema: summary validator");

s = swap(s,
`    .index("by_event_team", ["eventId", "teamId"]),
});`,
`    .index("by_event_team", ["eventId", "teamId"]),

  /**
   * One team's season summary at one event, stored so the board, plot and
   * match preview read a row per team instead of every report. A cache of
   * the reports: refreshTeamSummary rewrites a row from that team's reports,
   * and events:rebuildTeamSummaries rewrites a whole event. No row means no
   * reports.
   */
  teamSummaries: defineTable({
    eventId: v.id("events"),
    teamId: v.id("teams"),
    summary,
    updatedAt: v.number(),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"]),
});`,
"schema: teamSummaries table");

writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/mt1.mjs

say "1/3 Stored team stats: convex/lib/teamSummaries.ts"
if [[ -f convex/lib/teamSummaries.ts ]]; then
  echo "convex/lib/teamSummaries.ts already exists"
else
cat > convex/lib/teamSummaries.ts <<'EOF'
import type { MutationCtx, QueryCtx } from "../_generated/server";
import type { Doc, Id } from "../_generated/dataModel";
import { summarise, type Summary } from "./summarise";

/**
 * Whether a report's team was on the alliance the scout says won auto. Null
 * when the scout gave no answer or the match or team is gone. The single
 * copy of the rule, so stored summaries and per-match actuals cannot differ.
 */
export function isAutoWinnerFor(
  report: Doc<"matchReports">,
  match: Doc<"matches"> | null,
  team: Doc<"teams"> | null,
): boolean | null {
  if (report.autoWinner === null || !match || !team) return null;
  const onRed = match.redTeamNumbers.includes(team.number);
  return report.autoWinner === (onRed ? "red" : "blue");
}

/**
 * Rewrite one team's stored summary from its own reports at the event. Call
 * after anything that inserts, edits or deletes one of that team's match
 * reports. Reads a few dozen reports at most, never the whole event.
 */
export async function refreshTeamSummary(
  ctx: MutationCtx,
  eventId: Id<"events">,
  teamId: Id<"teams">,
): Promise<void> {
  const [team, reports, existing] = await Promise.all([
    ctx.db.get(teamId),
    ctx.db
      .query("matchReports")
      .withIndex("by_event_team", (q) => q.eq("eventId", eventId).eq("teamId", teamId))
      .collect(),
    ctx.db
      .query("teamSummaries")
      .withIndex("by_event_team", (q) => q.eq("eventId", eventId).eq("teamId", teamId))
      .first(),
  ]);

  if (!team || reports.length === 0) {
    if (existing) await ctx.db.delete(existing._id);
    return;
  }

  const matches = new Map<Id<"matches">, Doc<"matches"> | null>();
  const entries = [];
  for (const report of reports) {
    if (!matches.has(report.matchId)) {
      matches.set(report.matchId, await ctx.db.get(report.matchId));
    }
    const match = matches.get(report.matchId) ?? null;
    entries.push({ report, isAutoWinner: isAutoWinnerFor(report, match, team) });
  }

  const summary = summarise(entries);
  if (existing) {
    await ctx.db.patch(existing._id, { summary, updatedAt: Date.now() });
  } else {
    await ctx.db.insert("teamSummaries", { eventId, teamId, summary, updatedAt: Date.now() });
  }
}

/** Every stored summary at an event, by team. Teams with no reports are absent. */
export async function summariesFor(
  ctx: QueryCtx,
  eventId: Id<"events">,
): Promise<Map<Id<"teams">, Summary>> {
  const rows = await ctx.db
    .query("teamSummaries")
    .withIndex("by_event", (q) => q.eq("eventId", eventId))
    .collect();
  return new Map(rows.map((r) => [r.teamId, r.summary]));
}

/** One team's stored summary, or null when it has no reports. */
export async function summaryFor(
  ctx: QueryCtx,
  eventId: Id<"events">,
  teamId: Id<"teams">,
): Promise<Summary | null> {
  const row = await ctx.db
    .query("teamSummaries")
    .withIndex("by_event_team", (q) => q.eq("eventId", eventId).eq("teamId", teamId))
    .first();
  return row?.summary ?? null;
}
EOF
echo "convex/lib/teamSummaries.ts written"
fi

say "1/3 Stored team stats: write paths"
cat > /tmp/mt2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./mt-lib.mjs";

let p = "convex/matchReports.ts";
let s = readFileSync(p, "utf8");
if (s.includes("refreshTeamSummary")) {
  console.log("matchReports already patched");
} else {
  s = swap(s,
`import { bumpReportCount } from "./lib/reportCounts";`,
`import { bumpReportCount } from "./lib/reportCounts";
import { refreshTeamSummary } from "./lib/teamSummaries";`,
  "matchReports: imports");
  s = swap(s,
`    await bumpReportCount(ctx, event._id, teamId, 1);
`,
`    await bumpReportCount(ctx, event._id, teamId, 1);
    await refreshTeamSummary(ctx, event._id, teamId);
`,
  "matchReports: submit");
  s = swap(s,
`      hubStateSource: args.hubStateSource,
      updatedAt: Date.now(),
    });`,
`      hubStateSource: args.hubStateSource,
      updatedAt: Date.now(),
    });
    await refreshTeamSummary(ctx, report.eventId, report.teamId);`,
  "matchReports: update");
  writeFileSync(p, s);
  console.log("convex/matchReports.ts patched");
}

p = "convex/admin.ts";
s = readFileSync(p, "utf8");
if (s.includes("refreshTeamSummary")) {
  console.log("admin already patched");
} else {
  s = swap(s,
`import { bumpReportCount } from "./lib/reportCounts";`,
`import { bumpReportCount } from "./lib/reportCounts";
import { refreshTeamSummary } from "./lib/teamSummaries";`,
  "admin: imports");
  s = swap(s,
`    await ctx.db.patch(args.reportId, {
      autoWinner: args.autoWinner,
      updatedAt: Date.now(),
    });`,
`    await ctx.db.patch(args.reportId, {
      autoWinner: args.autoWinner,
      updatedAt: Date.now(),
    });
    await refreshTeamSummary(ctx, report.eventId, report.teamId);`,
  "admin: setAutoWinner");
  s = swap(s,
`    await bumpReportCount(ctx, report.eventId, report.teamId, -1);`,
`    await bumpReportCount(ctx, report.eventId, report.teamId, -1);
    await refreshTeamSummary(ctx, report.eventId, report.teamId);`,
  "admin: deleteReport");
  writeFileSync(p, s);
  console.log("convex/admin.ts patched");
}

p = "convex/events.ts";
s = readFileSync(p, "utf8");
if (s.includes("rebuildTeamSummaries")) {
  console.log("events already patched");
} else {
  s = swap(s,
`import { reportCountsFor } from "./lib/reportCounts";`,
`import { reportCountsFor } from "./lib/reportCounts";
import { refreshTeamSummary } from "./lib/teamSummaries";`,
  "events: imports");

  // A revised schedule can move a team between alliances, which changes
  // which of its fuel counted. Rebuilding the event is simpler than working
  // out which teams moved, and a re-import is rare.
  s = swap(s,
`    for (const list of primaries) {
      await seedPrimaryEntries(ctx, eventId, list._id);
    }

    return {
      eventId,`,
`    for (const list of primaries) {
      await seedPrimaryEntries(ctx, eventId, list._id);
    }

    // A revised schedule can move a team to the other alliance, which
    // changes which of its fuel counted.
    await ctx.scheduler.runAfter(0, internal.events.rebuildTeamSummaries, { eventId });

    return {
      eventId,`,
  "events: applyImport");

  s = swap(s,
`    const counters = await ctx.db
      .query("reportCounts")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of counters) await ctx.db.delete(row._id);`,
`    const counters = await ctx.db
      .query("reportCounts")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of counters) await ctx.db.delete(row._id);
    const summaries = await ctx.db
      .query("teamSummaries")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of summaries) await ctx.db.delete(row._id);`,
  "events: purge");

  s += `
/**
 * Rewrite every stored team summary at one event from its reports. Always
 * safe to run: after deploying the table, after a re-import (scheduled
 * automatically), or whenever a team's stats look wrong.
 */
export const rebuildTeamSummaries = internalMutation({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    const existing = await ctx.db
      .query("teamSummaries")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    // Rows for teams no longer at the event, then one refresh per team.
    const current = new Set(teams.map((t) => t._id));
    for (const row of existing) {
      if (!current.has(row.teamId)) await ctx.db.delete(row._id);
    }
    for (const team of teams) await refreshTeamSummary(ctx, args.eventId, team._id);
    return { teams: teams.length };
  },
});

/**
 * Rebuild every event, one mutation per event.
 *   bunx convex run events:rebuildAllTeamSummaries          (dev)
 *   bunx convex run --prod events:rebuildAllTeamSummaries   (prod)
 */
export const rebuildAllTeamSummaries = internalMutation({
  args: {},
  handler: async (ctx) => {
    const events = await ctx.db.query("events").collect();
    for (const event of events) {
      await ctx.scheduler.runAfter(0, internal.events.rebuildTeamSummaries, {
        eventId: event._id,
      });
    }
    return { scheduled: events.length };
  },
});
`;
  writeFileSync(p, s);
  console.log("convex/events.ts patched");
}
MJS
bun /tmp/mt2.mjs

say "1/3 Stored team stats: stats.forEvent, compare, forMatch read the rows"
cat > /tmp/mt3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap, span } from "./mt-lib.mjs";
const p = "convex/stats.ts";
let s = readFileSync(p, "utf8");
if (s.includes("summariesFor")) { console.log("stats already patched"); process.exit(0); }

s = swap(s,
`import { EMPTY_SUMMARY, derive, summarise, type Summary } from "./lib/summarise";`,
`import { EMPTY_SUMMARY, derive, type Summary } from "./lib/summarise";
import { isAutoWinnerFor, summariesFor, summaryFor } from "./lib/teamSummaries";`,
"stats: imports");

s = span(s,
`export const forEvent = query({`,
`/** Is the data trustworthy? The view that decides whether anything else is. */`,
`/**
 * Every team's summary at the active event, keyed by team id. Reads one
 * stored row per team; this used to read and summarise every report at the
 * event, on every phone with the board or plot open, on every submission.
 */
export const forEvent = query({
  args: {},
  handler: async (ctx): Promise<Record<string, Summary>> => {
    const event = await activeEvent(ctx);
    if (!event) return {};

    const [teams, summaries] = await Promise.all([
      ctx.db.query("teams").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      summariesFor(ctx, event._id),
    ]);

    const out: Record<string, Summary> = {};
    for (const team of teams) {
      out[team._id] = summaries.get(team._id) ?? { ...EMPTY_SUMMARY };
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
    const event = await activeEvent(ctx);
    if (!event) return [];
    const myTeam = await currentTeamNumber(ctx);

    const rows: CompareRow[] = [];
    for (const number of args.teamNumbers) {
      const team = await ctx.db
        .query("teams")
        .withIndex("by_event_number", (q) => q.eq("eventId", event._id).eq("number", number))
        .first();
      if (!team) continue;
      // Pit reports are per scouting team; only your own team's count here.
      const pit = await ctx.db
        .query("pitReports")
        .withIndex("by_event_team", (q) => q.eq("eventId", event._id).eq("teamId", team._id))
        .collect();
      rows.push({
        teamNumber: team.number,
        nickname: team.nickname,
        pitScouted: pit.some((p) => p.scoutingTeamNumber === myTeam),
        stats: (await summaryFor(ctx, event._id, team._id)) ?? { ...EMPTY_SUMMARY },
      });
    }
    return rows;
  },
});

/**
 * A match, with each robot's season averages AND what it actually did in this
 * match if anyone scouted it. The two together answer different questions:
 * averages say what to expect, the actuals say what happened.
 *
 * Reads this match's reports and six stored summaries, not the whole event.
 */
export const forMatch = query({
  args: { matchNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;

    const match = await ctx.db
      .query("matches")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("matchNumber", args.matchNumber))
      .first();
    if (!match) return null;

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_match", (q) => q.eq("matchId", match._id))
      .collect();

    const names = new Map<Id<"users">, string>();
    const scoutName = async (userId: Id<"users">): Promise<string> => {
      const known = names.get(userId);
      if (known !== undefined) return known;
      const profile = await ctx.db
        .query("profiles")
        .withIndex("by_user", (q) => q.eq("userId", userId))
        .first();
      const name = profile?.displayName ?? "Unknown scout";
      names.set(userId, name);
      return name;
    };

    const side = (numbers: number[]) =>
      Promise.all(numbers.map(async (number) => {
        const team = await ctx.db
          .query("teams")
          .withIndex("by_event_number", (q) => q.eq("eventId", event._id).eq("number", number))
          .first();
        if (!team) {
          return {
            teamNumber: number, nickname: "Not at this event",
            stats: { ...EMPTY_SUMMARY }, thisMatch: [],
          };
        }

        const thisMatch = await Promise.all(
          reports
            .filter((r) => r.teamId === team._id)
            .map(async (report) => {
              const d = derive(report, isAutoWinnerFor(report, match, team));
              return {
                scoutName: await scoutName(report.scoutId),
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
            }),
        );

        return {
          teamNumber: team.number,
          nickname: team.nickname,
          stats: (await summaryFor(ctx, event._id, team._id)) ?? { ...EMPTY_SUMMARY },
          thisMatch,
        };
      }));

    return {
      matchNumber: match.matchNumber,
      scheduledTime: match.scheduledTime,
      predictedTime: match.predictedTime ?? null,
      actualTime: match.actualTime ?? null,
      redScore: match.redScore ?? null,
      blueScore: match.blueScore ?? null,
      winningAlliance: match.winningAlliance ?? "",
      importedAt: event.importedAt,
      red: await side(match.redTeamNumbers),
      blue: await side(match.blueTeamNumbers),
    };
  },
});

`,
"stats: forEvent/compare/forMatch");

writeFileSync(p, s);
console.log("convex/stats.ts patched");
MJS
bun /tmp/mt3.mjs

# ===========================================================================
say "2/3 Usage by team: admin queries"
cat > /tmp/mt4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./mt-lib.mjs";
const p = "convex/admin.ts";
let s = readFileSync(p, "utf8");
if (s.includes("usageForEvent")) { console.log("admin usage already patched"); process.exit(0); }

s = swap(s,
`import {
  activeEvent, managesTeam, requireTeamAdmin, requireUser,
} from "./lib/guards";`,
`import {
  activeEvent, managesTeam, requireAdmin, requireTeamAdmin, requireUser,
} from "./lib/guards";`,
"admin: guards import");

s += `
/**
 * Events for the usage card, newest first. Deleted events are left out.
 * Full admins only: the card compares teams, which no single team's admin
 * needs to see.
 */
export const usageEvents = query({
  args: {},
  handler: async (ctx) => {
    await requireAdmin(ctx);
    const events = await ctx.db.query("events").collect();
    return events
      .filter((e) => !e.deletedAt)
      .sort((a, b) => b._creationTime - a._creationTime)
      .map((e) => ({ eventId: e._id, name: e.name, tbaEventKey: e.tbaEventKey }));
  },
});

export type UsageRow = {
  /** Null for scouts with no team number on their profile. */
  teamNumber: number | null;
  scouts: number;
  matchReports: number;
  pitReports: number;
};

/**
 * Scouting activity at one event, per SCOUTING team. Match reports go to the
 * scout's current team; pit reports to the team recorded on the report.
 * Scouts counts people who submitted either kind.
 *
 * Reads every report at the event, so the card calls this once per event on
 * open and on Refresh — never as a live subscription.
 */
export const usageForEvent = query({
  args: { eventId: v.id("events") },
  handler: async (ctx, args): Promise<UsageRow[]> => {
    await requireAdmin(ctx);
    const [reports, pit] = await Promise.all([
      ctx.db.query("matchReports").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("pitReports").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
    ]);

    const teamOf = new Map<Id<"users">, number | null>();
    const scoutTeam = async (userId: Id<"users">): Promise<number | null> => {
      if (!teamOf.has(userId)) {
        const profile = await ctx.db
          .query("profiles")
          .withIndex("by_user", (q) => q.eq("userId", userId))
          .first();
        teamOf.set(userId, profile?.teamNumber ?? null);
      }
      return teamOf.get(userId) ?? null;
    };

    const rows = new Map<number | null, UsageRow & { scoutIds: Set<Id<"users">> }>();
    const rowFor = (teamNumber: number | null) => {
      let row = rows.get(teamNumber);
      if (!row) {
        row = { teamNumber, scouts: 0, matchReports: 0, pitReports: 0, scoutIds: new Set() };
        rows.set(teamNumber, row);
      }
      return row;
    };

    for (const r of reports) {
      const row = rowFor(await scoutTeam(r.scoutId));
      row.matchReports += 1;
      row.scoutIds.add(r.scoutId);
    }
    for (const p of pit) {
      const row = rowFor(p.scoutingTeamNumber ?? (await scoutTeam(p.scoutId)));
      row.pitReports += 1;
      row.scoutIds.add(p.scoutId);
    }

    return [...rows.values()]
      .map(({ scoutIds, ...row }) => ({ ...row, scouts: scoutIds.size }))
      .sort((a, b) => b.matchReports - a.matchReports || b.pitReports - a.pitReports);
  },
});
`;

writeFileSync(p, s);
console.log("convex/admin.ts usage queries added");
MJS
bun /tmp/mt4.mjs

say "2/3 Usage by team: src/routes/admin/usage-card.tsx"
if [[ -f src/routes/admin/usage-card.tsx ]]; then
  echo "src/routes/admin/usage-card.tsx already exists"
else
cat > src/routes/admin/usage-card.tsx <<'EOF'
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
  const run = useCallback((isCurrent: () => boolean) => {
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
      });
  }, [fetchUsage]);

  useEffect(() => {
    let current = true;
    run(() => current);
    return () => { current = false; };
  }, [run]);

  const refresh = () => {
    setLoading(true);
    run(() => true);
  };

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
          <Button variant="outline" size="sm" disabled={loading} onClick={refresh}>
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
EOF
echo "src/routes/admin/usage-card.tsx written"
fi

say "2/3 Usage by team: mount under Configuring for"
cat > /tmp/mt5.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./mt-lib.mjs";
const p = "src/routes/admin/index.tsx";
let s = readFileSync(p, "utf8");
if (s.includes("UsageByTeamCard")) { console.log("admin page already patched"); process.exit(0); }

s = swap(s,
`import { RolesTable } from "./roles-table";`,
`import { RolesTable } from "./roles-table";
import { UsageByTeamCard } from "./usage-card";`,
"admin page: import");

s = swap(s,
`      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>Statbotics &amp; TBA</CardTitle>`,
`      ) : null}

      {isFullAdmin ? <UsageByTeamCard myTeamNumber={me?.teamNumber} /> : null}

      <Card>
        <CardHeader>
          <CardTitle>Statbotics &amp; TBA</CardTitle>`,
"admin page: mount");

writeFileSync(p, s);
console.log("src/routes/admin/index.tsx patched");
MJS
bun /tmp/mt5.mjs

# ===========================================================================
say "3/3 Cross-team fixes: shared guards"
cat > /tmp/mt6.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./mt-lib.mjs";
const p = "convex/lib/guards.ts";
let s = readFileSync(p, "utf8");
if (s.includes("canEditList")) { console.log("guards already patched"); process.exit(0); }

s = swap(s,
`/** The team whose data the caller is working with. */`,
`/**
 * A primary list belongs to a team: that team's admins and full admins edit
 * it — the same rule as marking a team picked. A personal list is its
 * owner's alone.
 */
export function canEditList(
  profile: Doc<"profiles"> | null,
  userId: Id<"users"> | null,
  list: Doc<"pickLists">,
): boolean {
  if (list.ownerId === null) return managesTeam(profile, list.teamNumber);
  return userId !== null && list.ownerId === userId;
}

/**
 * Who may SEE a list. A primary list: its team, and full admins. A personal
 * list: its owner, and admins who manage the owner's team — which is how a
 * team admin reviews submitted lists. \`ownerTeam\` is the owner's team,
 * for lists written before teamNumber was stored on them.
 */
export function canReadList(
  profile: Doc<"profiles"> | null,
  userId: Id<"users"> | null,
  list: Doc<"pickLists">,
  ownerTeam: number | undefined,
): boolean {
  if (!profile) return false;
  if (list.ownerId === null) {
    return (list.teamNumber !== undefined && profile.teamNumber === list.teamNumber)
      || managesTeam(profile, list.teamNumber);
  }
  if (userId !== null && list.ownerId === userId) return true;
  return managesTeam(profile, list.teamNumber ?? ownerTeam);
}

/** The team whose data the caller is working with. */`,
"guards: list access");

writeFileSync(p, s);
console.log("convex/lib/guards.ts patched");
MJS
bun /tmp/mt6.mjs

say "3/3 Cross-team fixes: tiers come from your team's primary list"
cat > /tmp/mt7.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap, swapAll } from "./mt-lib.mjs";
const p = "convex/teams.ts";
let s = readFileSync(p, "utf8");
if (s.includes("primaries.find((l) => l.teamNumber === teamNumber)")) {
  console.log("teams already patched"); process.exit(0);
}

s = swap(s,
`async function primaryTiers(
  ctx: QueryCtx,
  eventId: Id<"events">,
): Promise<Map<string, Tier>> {
  const primary = await ctx.db
    .query("pickLists")
    .withIndex("by_event_owner", (q) =>
      q.eq("eventId", eventId).eq("ownerId", null))
    .first();
  if (!primary) return new Map();`,
`async function primaryTiers(
  ctx: QueryCtx,
  eventId: Id<"events">,
  teamNumber: number | undefined,
): Promise<Map<string, Tier>> {
  // Every scouting team at an event has its own primary list. Taking the
  // index's first showed another team's tiers whenever two teams shared an
  // event.
  if (teamNumber === undefined) return new Map();
  const primaries = await ctx.db
    .query("pickLists")
    .withIndex("by_event_owner", (q) =>
      q.eq("eventId", eventId).eq("ownerId", null))
    .collect();
  const primary = primaries.find((l) => l.teamNumber === teamNumber);
  if (!primary) return new Map();`,
"teams: primaryTiers");

s = swapAll(s,
`    const tiers = await primaryTiers(ctx, event._id);`,
`    const tiers = await primaryTiers(ctx, event._id, myTeam);`,
2, "teams: primaryTiers callers");

writeFileSync(p, s);
console.log("convex/teams.ts patched");
MJS
bun /tmp/mt7.mjs

say "3/3 Cross-team fixes: merge reads and writes your team only"
cat > /tmp/mt8.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./mt-lib.mjs";
const p = "convex/merge.ts";
let s = readFileSync(p, "utf8");
if (s.includes("Full admins included")) { console.log("merge already patched"); process.exit(0); }

s = swap(s,
`import { activeEvent, managesTeam, requireTeamAdmin } from "./lib/guards";`,
`import { activeEvent, requireTeamAdmin } from "./lib/guards";`,
"merge: imports");

s = swap(s,
`    // A team's merge reads its own scouts' lists and nobody else's.
    if (actor.role !== "admin" && profile?.teamNumber !== actor.teamNumber) continue;`,
`    // A team's merge reads its own scouts' lists and nobody else's. Full
    // admins included: the merge lands in one team's primary list, so votes
    // from another team's scouts have no business in it.
    if (actor.teamNumber === undefined || profile?.teamNumber !== actor.teamNumber) continue;`,
"merge: build lists");

s = swap(s,
`    .filter((p) => actor.role === "admin" || p.teamNumber === actor.teamNumber)`,
`    .filter((p) => actor.teamNumber !== undefined && p.teamNumber === actor.teamNumber)`,
"merge: missing");

s = swap(s,
`    const primary = primaries.find((l) => managesTeam(me, l.teamNumber));`,
`    // The caller's own team's list. A full admin "manages" every team, so
    // managesTeam here picked whichever primary came first.
    const primary = primaries.find(
      (l) => l.teamNumber !== undefined && l.teamNumber === me.teamNumber,
    );`,
"merge: apply target");

writeFileSync(p, s);
console.log("convex/merge.ts patched");
MJS
bun /tmp/mt8.mjs

say "3/3 Cross-team fixes: who can see and edit pick lists"
cat > /tmp/mt9.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap, swapAll } from "./mt-lib.mjs";

let p = "convex/pickLists.ts";
let s = readFileSync(p, "utf8");
if (s.includes("canReadList")) {
  console.log("pickLists already patched");
} else {
  s = swap(s,
`async function assertCanEdit(
  ctx: MutationCtx,
  listId: Id<"pickLists">,
  userId: Id<"users">,
  isAdmin: boolean,
): Promise<Doc<"pickLists">> {
  const list = await ctx.db.get(listId);
  if (!list) throw new Error("That list no longer exists.");
  // The primary list is the team's, so only an admin edits it. Personal lists
  // are the scout's own working notes and nobody else touches them.
  if (list.ownerId === null) {
    if (!isAdmin) throw new Error("Only your team's admin can edit the primary list.");
  } else if (list.ownerId !== userId) {
    throw new Error("That is someone else's list.");
  }
  return list;
}`,
`async function assertCanEdit(
  ctx: MutationCtx,
  listId: Id<"pickLists">,
  userId: Id<"users">,
  profile: Doc<"profiles"> | null,
): Promise<Doc<"pickLists">> {
  const list = await ctx.db.get(listId);
  if (!list) throw new Error("That list no longer exists.");
  // The primary list is the team's, so only that team's admins edit it.
  // Personal lists are the scout's own working notes and nobody else
  // touches them.
  if (!canEditList(profile, userId, list)) {
    throw new Error(list.ownerId === null
      ? "Only your team's admin can edit the primary list."
      : "That is someone else's list.");
  }
  return list;
}`,
  "pickLists: assertCanEdit");

  s = swapAll(s,
`assertCanEdit(ctx, args.listId, userId, profile?.role === "admin")`,
`assertCanEdit(ctx, args.listId, userId, profile)`,
  2, "pickLists: assertCanEdit callers");

  s = swap(s,
`    const list = await ctx.db.get(args.listId);
    if (!list) return null;
    const profile = await currentProfile(ctx);
    const userId = profile?.userId ?? null;

    const canEdit =
      list.ownerId === null
        ? profile?.role === "admin"
        : list.ownerId === userId;

    return { ...list, canEdit };`,
`    const list = await ctx.db.get(args.listId);
    if (!list) return null;
    const profile = await currentProfile(ctx);
    const userId = profile?.userId ?? null;

    // An id in a URL is not permission. Another team's lists read as absent.
    const owner = list.ownerId === null ? null : await ctx.db
      .query("profiles")
      .withIndex("by_user", (q) => q.eq("userId", list.ownerId!))
      .first();
    if (!canReadList(profile, userId, list, owner?.teamNumber)) return null;

    return { ...list, canEdit: canEditList(profile, userId, list) };`,
  "pickLists: get");

  // Add the new guards to whatever this file already imports from them.
  const m = s.match(/import \{([^}]*)\} from "\.\/lib\/guards";/);
  if (!m) { console.error("ERROR: pickLists guards import not found"); process.exit(1); }
  const names = new Set(m[1].split(",").map((x) => x.trim()).filter(Boolean));
  names.add("canEditList"); names.add("canReadList");
  s = s.replace(m[0], `import {\n  ${[...names].join(", ")},\n} from "./lib/guards";`);

  writeFileSync(p, s);
  console.log("convex/pickLists.ts patched");
}

p = "convex/entries.ts";
s = readFileSync(p, "utf8");
if (s.includes("canReadList")) {
  console.log("entries already patched");
} else {
  s = swap(s,
`import { currentProfile, requireUser } from "./lib/guards";`,
`import { canEditList, canReadList, currentProfile, requireUser } from "./lib/guards";`,
  "entries: imports");

  s = swap(s,
`  handler: async (ctx, args) => {
    const entries = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", args.listId))
      .collect();`,
`  handler: async (ctx, args) => {
    // Same rule as pickLists.get: another team's list reads as empty.
    const list = await ctx.db.get(args.listId);
    if (!list) return [];
    const profile = await currentProfile(ctx);
    const owner = list.ownerId === null ? null : await ctx.db
      .query("profiles")
      .withIndex("by_user", (q) => q.eq("userId", list.ownerId!))
      .first();
    if (!canReadList(profile, profile?.userId ?? null, list, owner?.teamNumber)) return [];

    const entries = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", args.listId))
      .collect();`,
  "entries: forList");

  s = swapAll(s,
`    if (list.ownerId === null) {
      if (profile?.role !== "admin") {
        throw new Error("Only an admin can edit the primary list.");
      }
    } else if (list.ownerId !== userId) {
      throw new Error("That is someone else's list.");
    }`,
`    if (!canEditList(profile, userId, list)) {
      throw new Error(list.ownerId === null
        ? "Only your team's admin can edit the primary list."
        : "That is someone else's list.");
    }`,
  2, "entries: move and setNote");

  s = swap(s,
`    if (list.ownerId === null ? profile?.role !== "admin" : list.ownerId !== userId) {
      throw new Error("You cannot edit that list.");
    }`,
`    if (!canEditList(profile, userId, list)) {
      throw new Error("You cannot edit that list.");
    }`,
  "entries: renormalise");

  writeFileSync(p, s);
  console.log("convex/entries.ts patched");
}
MJS
bun /tmp/mt9.mjs

say "3/3 Cross-team fixes: admins act only on their own team's reports"
cat > /tmp/mt10.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./mt-lib.mjs";
const p = "convex/admin.ts";
let s = readFileSync(p, "utf8");
if (s.includes("assertManagesReport")) { console.log("admin checks already patched"); process.exit(0); }

s = swap(s,
`export const flagLabels = query({`,
`/**
 * A team admin acts on reports written by their own team's scouts; a full
 * admin on anyone's. The reports view already hid other teams' reports, but
 * the mutations behind it did not check, so an id was enough.
 */
async function assertManagesReport(
  ctx: MutationCtx,
  admin: Doc<"profiles">,
  report: Doc<"matchReports">,
): Promise<void> {
  const scout = await ctx.db
    .query("profiles")
    .withIndex("by_user", (q) => q.eq("userId", report.scoutId))
    .first();
  if (!managesTeam(admin, scout?.teamNumber)) {
    throw new Error("That report was written by another team's scout.");
  }
}

export const flagLabels = query({`,
"admin: helper");

s = swap(s,
`import { mutation, query } from "./_generated/server";`,
`import { mutation, query } from "./_generated/server";
import type { MutationCtx } from "./_generated/server";`,
"admin: MutationCtx import");

// setAutoWinner and deleteReport share this opening; dismissFlag's differs.
const opening =
`    const report = await ctx.db.get(args.reportId);
    if (!report) throw new Error("That report no longer exists.");
`;
const count = s.split(opening).length - 1;
if (count !== 3) {
  console.error(`ERROR: expected 3 report loads in admin.ts, found ${count}`);
  process.exit(1);
}
s = s.split(opening).join(opening + `    await assertManagesReport(ctx, admin, report);
`);

s = swap(s,
`    const report = await ctx.db.get(args.pitReportId);
    if (!report) throw new Error("That report no longer exists.");
`,
`    const report = await ctx.db.get(args.pitReportId);
    if (!report) throw new Error("That report no longer exists.");
    if (!managesTeam(admin, report.scoutingTeamNumber)) {
      throw new Error("That pit report belongs to another team.");
    }
`,
"admin: deletePitReport");

writeFileSync(p, s);
console.log("convex/admin.ts patched");
MJS
bun /tmp/mt10.mjs
rm -f /tmp/mt-lib.mjs /tmp/mt[0-9].mjs /tmp/mt10.mjs

say "Push, rebuild summaries on dev, typecheck"
if bunx convex dev --once; then
  bunx convex run events:rebuildAllTeamSummaries || echo "Rebuild failed — run it by hand."
else
  echo "Convex push failed — see above."
fi
bun run typecheck || echo "Typecheck reported issues — see above."

printf '\n\033[1;33m%s\033[0m\n' \
  "After deploying to prod, run:  bunx convex run --prod events:rebuildAllTeamSummaries"
