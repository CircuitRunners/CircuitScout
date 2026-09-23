#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-io-coverage.sh — coverage without reading every report.
#
# stats.matchCoverage (dashboard, on every phone) and stats.coverage (admin
# data page) were the last queries loading every match report at the event.
# Both only need tallies, so the tallies are now stored:
#
#   matchTallies   one row per match that has reports:
#                  { reportCount, teamNumbers } — which robots were scouted
#   scoutTallies   one row per scout per event:
#                  { count, noSplit, early } — the data page's per-scout table
#   lib/coverage.ts  refreshMatchTally / refreshScoutTally rewrite a row from
#                    that match's or that scout's own reports
#
# Covered slots are still worked out at READ time against the current
# schedule, so a revised TBA schedule needs no rebuild: a report filed
# against a robot that is no longer in that match stops counting, exactly
# as before.
#
# Refreshed by: matchReports.submit, matchReports.update (it can change the
# timing that marks a report early or unsplit), admin.deleteReport. Purged
# with the event. A NEW write path that inserts, deletes or re-times a match
# report must call these, or coverage drifts until a rebuild.
#
# teamsNoMatch now comes from reportCounts (patch-io-counters.sh).
# With this, nothing on the dashboard reads every report any more.
#
# One small visible change: scouts with the same report count are listed by
# name. They used to be listed in order of first submission.
#
# Schema: two new tables. RUN ON PROD after deploying:
#
#   bunx convex run --prod events:rebuildAllDerived
#
# That rebuilds counters, team summaries AND these tallies for every event,
# so it is the one command to remember after deploying any of the io patches.
# ---------------------------------------------------------------------------
set -euo pipefail
grep -q "teamSummaries:" convex/schema.ts 2>/dev/null \
  || { echo "ERROR: run patch-multi-team.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# Relative import: Git Bash translates /tmp in arguments, not in import strings.
cat > /tmp/cv-lib.mjs <<'MJS'
export function swap(s, from, to, label) {
  const i = s.indexOf(from);
  if (i < 0 || s.indexOf(from, i + 1) >= 0) {
    console.error(`ERROR: anchor ${i < 0 ? "missing" : "not unique"}: ${label}`);
    process.exit(1);
  }
  return s.slice(0, i) + to + s.slice(i + from.length);
}
export function span(s, start, end, to, label) {
  const i = s.indexOf(start);
  const j = i < 0 ? -1 : (end === null ? s.length : s.indexOf(end, i + start.length));
  if (i < 0 || j < 0) {
    console.error(`ERROR: span anchor missing: ${label}`);
    process.exit(1);
  }
  return s.slice(0, i) + to + s.slice(j);
}
MJS

say "Schema: matchTallies and scoutTallies"
cat > /tmp/cv1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./cv-lib.mjs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
if (s.includes("matchTallies:")) { console.log("schema already patched"); process.exit(0); }

s = swap(s,
`  teamSummaries: defineTable({
    eventId: v.id("events"),
    teamId: v.id("teams"),
    summary,
    updatedAt: v.number(),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"]),
});`,
`  teamSummaries: defineTable({
    eventId: v.id("events"),
    teamId: v.id("teams"),
    summary,
    updatedAt: v.number(),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"]),

  /**
   * Which robots were scouted in one match, and how many reports it has.
   * Coverage is computed from these against the CURRENT schedule, so a
   * revised schedule needs no rebuild. No row means no reports.
   */
  matchTallies: defineTable({
    eventId: v.id("events"),
    matchId: v.id("matches"),
    reportCount: v.number(),
    /** Distinct team numbers with at least one report in this match. */
    teamNumbers: v.array(v.number()),
  })
    .index("by_event", ["eventId"])
    .index("by_match", ["matchId"]),

  /** One scout's report quality at one event, for the admin data page. */
  scoutTallies: defineTable({
    eventId: v.id("events"),
    scoutId: v.id("users"),
    count: v.number(),
    /** Reports with no time anchor, so fuel could not be split by shift. */
    noSplit: v.number(),
    /** Reports submitted before the match could have ended. */
    early: v.number(),
  })
    .index("by_event", ["eventId"])
    .index("by_event_scout", ["eventId", "scoutId"]),
});`,
"schema: tallies");

writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/cv1.mjs

say "Helpers: convex/lib/coverage.ts"
if [[ -f convex/lib/coverage.ts ]]; then
  echo "convex/lib/coverage.ts already exists"
else
cat > convex/lib/coverage.ts <<'EOF'
import type { MutationCtx } from "../_generated/server";
import type { Id } from "../_generated/dataModel";
import { submittedBeforeMatchEnd } from "./scoring";

/**
 * Rewrite one match's tally from that match's reports — a dozen at most.
 * Call after any report in the match is inserted or deleted.
 */
export async function refreshMatchTally(
  ctx: MutationCtx,
  eventId: Id<"events">,
  matchId: Id<"matches">,
): Promise<void> {
  const [reports, existing] = await Promise.all([
    ctx.db
      .query("matchReports")
      .withIndex("by_match", (q) => q.eq("matchId", matchId))
      .collect(),
    ctx.db
      .query("matchTallies")
      .withIndex("by_match", (q) => q.eq("matchId", matchId))
      .first(),
  ]);

  if (reports.length === 0) {
    if (existing) await ctx.db.delete(existing._id);
    return;
  }

  // A report whose team row is gone still counts as a report, but covers no
  // robot — the same as when coverage read the reports directly.
  const numbers = new Set<number>();
  const seen = new Set<Id<"teams">>();
  for (const report of reports) {
    if (seen.has(report.teamId)) continue;
    seen.add(report.teamId);
    const team = await ctx.db.get(report.teamId);
    if (team) numbers.add(team.number);
  }

  const fields = {
    reportCount: reports.length,
    teamNumbers: [...numbers].sort((a, b) => a - b),
  };
  if (existing) {
    await ctx.db.patch(existing._id, fields);
  } else {
    await ctx.db.insert("matchTallies", { eventId, matchId, ...fields });
  }
}

/**
 * Rewrite one scout's tally at one event from their own reports there. Call
 * after any of their reports is inserted, deleted, or has its timing edited.
 */
export async function refreshScoutTally(
  ctx: MutationCtx,
  eventId: Id<"events">,
  scoutId: Id<"users">,
): Promise<void> {
  const [reports, existing] = await Promise.all([
    ctx.db
      .query("matchReports")
      .withIndex("by_scout_event", (q) => q.eq("scoutId", scoutId).eq("eventId", eventId))
      .collect(),
    ctx.db
      .query("scoutTallies")
      .withIndex("by_event_scout", (q) => q.eq("eventId", eventId).eq("scoutId", scoutId))
      .first(),
  ]);

  if (reports.length === 0) {
    if (existing) await ctx.db.delete(existing._id);
    return;
  }

  const fields = {
    count: reports.length,
    noSplit: reports.filter((r) => r.hubStateSource === "none").length,
    early: reports.filter((r) => submittedBeforeMatchEnd(r.matchStartedAt, r.submittedAt)).length,
  };
  if (existing) {
    await ctx.db.patch(existing._id, fields);
  } else {
    await ctx.db.insert("scoutTallies", { eventId, scoutId, ...fields });
  }
}
EOF
echo "convex/lib/coverage.ts written"
fi

say "Write paths: submit, update, delete, purge"
cat > /tmp/cv2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./cv-lib.mjs";

let p = "convex/matchReports.ts";
let s = readFileSync(p, "utf8");
if (s.includes("refreshMatchTally")) {
  console.log("matchReports already patched");
} else {
  s = swap(s,
`import { refreshTeamSummary } from "./lib/teamSummaries";`,
`import { refreshTeamSummary } from "./lib/teamSummaries";
import { refreshMatchTally, refreshScoutTally } from "./lib/coverage";`,
  "matchReports: imports");
  s = swap(s,
`    await refreshTeamSummary(ctx, event._id, teamId);
`,
`    await refreshTeamSummary(ctx, event._id, teamId);
    await refreshMatchTally(ctx, event._id, matchId);
    await refreshScoutTally(ctx, event._id, scoutId);
`,
  "matchReports: submit");
  // An edit keeps the match and team, but can change the timing fields that
  // mark a report early or unsplit.
  s = swap(s,
`    await refreshTeamSummary(ctx, report.eventId, report.teamId);`,
`    await refreshTeamSummary(ctx, report.eventId, report.teamId);
    await refreshScoutTally(ctx, report.eventId, report.scoutId);`,
  "matchReports: update");
  writeFileSync(p, s);
  console.log("convex/matchReports.ts patched");
}

p = "convex/admin.ts";
s = readFileSync(p, "utf8");
if (s.includes("refreshMatchTally")) {
  console.log("admin already patched");
} else {
  s = swap(s,
`import { refreshTeamSummary } from "./lib/teamSummaries";`,
`import { refreshTeamSummary } from "./lib/teamSummaries";
import { refreshMatchTally, refreshScoutTally } from "./lib/coverage";`,
  "admin: imports");
  s = swap(s,
`    await bumpReportCount(ctx, report.eventId, report.teamId, -1);
    await refreshTeamSummary(ctx, report.eventId, report.teamId);`,
`    await bumpReportCount(ctx, report.eventId, report.teamId, -1);
    await refreshTeamSummary(ctx, report.eventId, report.teamId);
    await refreshMatchTally(ctx, report.eventId, report.matchId);
    await refreshScoutTally(ctx, report.eventId, report.scoutId);`,
  "admin: deleteReport");
  writeFileSync(p, s);
  console.log("convex/admin.ts patched");
}

p = "convex/events.ts";
s = readFileSync(p, "utf8");
if (s.includes("rebuildCoverage")) {
  console.log("events already patched");
} else {
  s = swap(s,
`import { refreshTeamSummary } from "./lib/teamSummaries";`,
`import { refreshTeamSummary } from "./lib/teamSummaries";
import { refreshMatchTally, refreshScoutTally } from "./lib/coverage";`,
  "events: imports");

  s = swap(s,
`    const summaries = await ctx.db
      .query("teamSummaries")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of summaries) await ctx.db.delete(row._id);`,
`    const summaries = await ctx.db
      .query("teamSummaries")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of summaries) await ctx.db.delete(row._id);
    const matchTallies = await ctx.db
      .query("matchTallies")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of matchTallies) await ctx.db.delete(row._id);
    const scoutTallies = await ctx.db
      .query("scoutTallies")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of scoutTallies) await ctx.db.delete(row._id);`,
  "events: purge");

  s += `
/**
 * Rewrite one event's match and scout tallies from its reports. Always safe
 * to run: after deploying the tables, or whenever coverage looks wrong.
 */
export const rebuildCoverage = internalMutation({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    const [matches, reports, matchRows, scoutRows] = await Promise.all([
      ctx.db.query("matches").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("matchReports").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("matchTallies").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("scoutTallies").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
    ]);

    // Every match on the schedule or holding a row, and every scout with a
    // report or a row: refreshing each rewrites or removes it.
    const matchIds = new Set([...matches.map((m) => m._id), ...matchRows.map((r) => r.matchId)]);
    for (const matchId of matchIds) await refreshMatchTally(ctx, args.eventId, matchId);
    const scoutIds = new Set([...reports.map((r) => r.scoutId), ...scoutRows.map((r) => r.scoutId)]);
    for (const scoutId of scoutIds) await refreshScoutTally(ctx, args.eventId, scoutId);

    return { matches: matchIds.size, scouts: scoutIds.size };
  },
});

/**
 * Rebuild every event's tallies, one mutation per event.
 *   bunx convex run --prod events:rebuildAllCoverage
 */
export const rebuildAllCoverage = internalMutation({
  args: {},
  handler: async (ctx) => {
    const events = await ctx.db.query("events").collect();
    for (const event of events) {
      await ctx.scheduler.runAfter(0, internal.events.rebuildCoverage, { eventId: event._id });
    }
    return { scheduled: events.length };
  },
});

/**
 * Everything the io patches store, rebuilt for every event: report counts,
 * team summaries and coverage tallies. The one command to run on prod after
 * deploying any of them.
 *   bunx convex run --prod events:rebuildAllDerived
 */
export const rebuildAllDerived = internalMutation({
  args: {},
  handler: async (ctx) => {
    const events = await ctx.db.query("events").collect();
    for (const event of events) {
      const args = { eventId: event._id };
      await ctx.scheduler.runAfter(0, internal.events.rebuildReportCounts, args);
      await ctx.scheduler.runAfter(0, internal.events.rebuildTeamSummaries, args);
      await ctx.scheduler.runAfter(0, internal.events.rebuildCoverage, args);
    }
    return { events: events.length };
  },
});
`;
  writeFileSync(p, s);
  console.log("convex/events.ts patched");
}
MJS
bun /tmp/cv2.mjs

say "stats.matchCoverage and stats.coverage read the tallies"
cat > /tmp/cv3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap, span } from "./cv-lib.mjs";
const p = "convex/stats.ts";
let s = readFileSync(p, "utf8");
if (s.includes("matchTallies")) { console.log("stats already patched"); process.exit(0); }

// Nothing reads the whole event's reports any more, so the loader goes.
s = span(s,
`/** Whether each report's team was on the alliance that won auto. */`,
`/**
 * Every team's summary at the active event`,
``,
"stats: remove winnerFlags and loadEvent");

s = span(s,
`/** Is the data trustworthy? The view that decides whether anything else is. */`,
null,
`/**
 * Robot-matches covered, out of robot-matches on the schedule. One robot in
 * one match is one slot: it fills once, however many scouts watched it. That
 * is the whole point — counting reports instead runs past 100% the moment two
 * scouts double up, which is a thing this app encourages.
 *
 * Worked out against the CURRENT schedule, from stored per-match tallies, so
 * a revised schedule is reflected without a rebuild.
 */
function coveredSlots(
  matches: Doc<"matches">[],
  scoutedIn: Map<Id<"matches">, Set<number>>,
) {
  let slots = 0;
  let covered = 0;
  for (const match of matches) {
    const seen = scoutedIn.get(match._id) ?? new Set<number>();
    // The schedule's own alliances, not a hardcoded six: a match short a team
    // should not read as a robot nobody scouted. And only teams actually in
    // the match count, so a report filed against the wrong robot fills
    // nothing rather than covering for the one it displaced.
    const expected = [...match.redTeamNumbers, ...match.blueTeamNumbers];
    slots += expected.length;
    covered += expected.filter((number) => seen.has(number)).length;
  }
  return { slots, covered };
}

/** One small row per scouted match, plus the schedule. */
async function loadTallies(ctx: QueryCtx, eventId: Id<"events">) {
  const [matches, tallies] = await Promise.all([
    ctx.db.query("matches").withIndex("by_event", (q) => q.eq("eventId", eventId)).collect(),
    ctx.db.query("matchTallies").withIndex("by_event", (q) => q.eq("eventId", eventId)).collect(),
  ]);
  const tallyByMatch = new Map(tallies.map((t) => [t.matchId, t]));
  const scoutedIn = new Map(tallies.map((t) => [t.matchId, new Set(t.teamNumbers)]));
  return { matches, tallies, tallyByMatch, scoutedIn };
}

/** Just the fraction, for the dashboard metric. */
export const matchCoverage = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return { slots: 0, covered: 0 };
    const { matches, scoutedIn } = await loadTallies(ctx, event._id);
    return coveredSlots(matches, scoutedIn);
  },
});

/** Is the data trustworthy? The view that decides whether anything else is. */
export const coverage = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) {
      return { matches: [], teamsNoPit: [], teamsNoMatch: [], byScout: [], totals: null };
    }

    const myTeam = await currentTeamNumber(ctx);
    const [{ matches, tallies, tallyByMatch, scoutedIn }, teams, pit, counts, scouts] =
      await Promise.all([
        loadTallies(ctx, event._id),
        ctx.db.query("teams").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
        // Your own team's pit reports only.
        ctx.db
          .query("pitReports")
          .withIndex("by_event_scouting_team", (q) =>
            q.eq("eventId", event._id).eq("scoutingTeamNumber", myTeam))
          .collect(),
        reportCountsFor(ctx, event._id),
        ctx.db.query("scoutTallies").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ]);
    const pitScouted = new Set(pit.map((p) => p.teamId));

    const matchRows = matches
      .map((match) => {
        const covered = scoutedIn.get(match._id) ?? new Set<number>();
        const expected = [...match.redTeamNumbers, ...match.blueTeamNumbers];
        return {
          matchNumber: match.matchNumber,
          reportCount: tallyByMatch.get(match._id)?.reportCount ?? 0,
          missing: expected.filter((n) => !covered.has(n)),
        };
      })
      .filter((m) => m.missing.length > 0)
      .sort((a, b) => a.matchNumber - b.matchNumber);

    // A few dozen scouts, looked up once each.
    const byScout = await Promise.all(scouts.map(async (row) => {
      const profile = await ctx.db
        .query("profiles")
        .withIndex("by_user", (q) => q.eq("userId", row.scoutId))
        .first();
      return {
        name: profile?.displayName ?? "Unknown scout",
        count: row.count,
        noSplit: row.noSplit,
        early: row.early,
      };
    }));

    return {
      matches: matchRows,
      teamsNoPit: teams
        .filter((t) => !pitScouted.has(t._id))
        .map((t) => t.number)
        .sort((a, b) => a - b),
      teamsNoMatch: teams
        .filter((t) => (counts.get(t._id) ?? 0) === 0)
        .map((t) => t.number)
        .sort((a, b) => a - b),
      // Busiest first; equal counts by name, so the order is stable.
      byScout: byScout.sort((a, b) => b.count - a.count || a.name.localeCompare(b.name)),
      totals: {
        teams: teams.length,
        matches: matches.length,
        reports: tallies.reduce((n, t) => n + t.reportCount, 0),
        possible: matches.length * 6,
        ...coveredSlots(matches, scoutedIn),
      },
    };
  },
});
`,
"stats: coverage queries");

s = swap(s,
`import { submittedBeforeMatchEnd } from "./lib/scoring";
`,
`import { reportCountsFor } from "./lib/reportCounts";
`,
"stats: imports");

writeFileSync(p, s);
console.log("convex/stats.ts patched");
MJS
bun /tmp/cv3.mjs
rm -f /tmp/cv-lib.mjs /tmp/cv1.mjs /tmp/cv2.mjs /tmp/cv3.mjs

say "Push, rebuild on dev, typecheck"
if bunx convex dev --once; then
  bunx convex run events:rebuildAllDerived || echo "Rebuild failed — run it by hand."
else
  echo "Convex push failed — see above."
fi
bun run typecheck || echo "Typecheck reported issues — see above."

printf '\n\033[1;33m%s\033[0m\n' \
  "After deploying to prod, run:  bunx convex run --prod events:rebuildAllDerived"
