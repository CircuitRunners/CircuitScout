#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-io-counters.sh — report counts without reading the reports.
#
# teams.listWithStatus sits on the dashboard, pit, teams, compare, plot and
# pick list pages, and read every match report at the event to count them per
# team. events.list did the same for every event. Convex cannot count rows
# without reading them, so the count is now kept in its own small table.
#
#   reportCounts          one row per (event, team): { count }
#   lib/reportCounts.ts   bumpReportCount (writes), reportCountsFor (reads)
#
# EVERY path that inserts or deletes a match report must call bumpReportCount.
# Today that is: matchReports.submit, admin.deleteReport, and the event purge
# (which drops the event's counter rows). A new write path that forgets this
# drifts the counts; events:rebuildReportCounts recomputes them from the
# reports and is always safe to re-run.
#
# events.list still decides "removable" from the reports themselves — a stale
# counter must never make scouting data look deletable.
#
# Schema: one new table. Existing reports are counted by a one-off rebuild,
# which this script runs on your dev deployment. RUN IT ON PROD after deploy:
#
#   bunx convex run --prod events:rebuildAllReportCounts
#
# Until it runs, teams show 0 reports on prod.
# ---------------------------------------------------------------------------
set -euo pipefail
grep -q "by_event_broke" convex/schema.ts 2>/dev/null \
  || { echo "ERROR: run patch-io-diet.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

cat > /tmp/ioc-lib.mjs <<'MJS'
export function swap(s, from, to, label) {
  const i = s.indexOf(from);
  if (i < 0 || s.indexOf(from, i + 1) >= 0) {
    console.error(`ERROR: anchor ${i < 0 ? "missing" : "not unique"}: ${label}`);
    process.exit(1);
  }
  return s.slice(0, i) + to + s.slice(i + from.length);
}
MJS

say "Schema: reportCounts table"
cat > /tmp/ioc1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./ioc-lib.mjs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
if (s.includes("reportCounts:")) { console.log("schema already patched"); process.exit(0); }
s = swap(s,
`    .index("by_list", ["pickListId"])
    .index("by_list_tier", ["pickListId", "tier"]),
});`,
`    .index("by_list", ["pickListId"])
    .index("by_list_tier", ["pickListId", "tier"]),

  /**
   * Match reports per team per event. Denormalised so a count never means
   * reading the reports: the team list re-ran on every submission, on every
   * phone, and read every report each time. Maintained by bumpReportCount;
   * events:rebuildReportCounts recomputes it from scratch.
   */
  reportCounts: defineTable({
    eventId: v.id("events"),
    teamId: v.id("teams"),
    count: v.number(),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"]),
});`,
"schema: end of tables");
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/ioc1.mjs

say "Helpers: convex/lib/reportCounts.ts"
if [[ -f convex/lib/reportCounts.ts ]]; then
  echo "convex/lib/reportCounts.ts already exists"
else
cat > convex/lib/reportCounts.ts <<'EOF'
import type { MutationCtx, QueryCtx } from "../_generated/server";
import type { Id } from "../_generated/dataModel";

/**
 * Adjust one team's report count at one event. Call on every insert (+1) and
 * delete (-1) of a match report. Floors at zero so a missed increment cannot
 * push a count negative; rebuildReportCounts corrects any drift.
 */
export async function bumpReportCount(
  ctx: MutationCtx,
  eventId: Id<"events">,
  teamId: Id<"teams">,
  delta: number,
): Promise<void> {
  const row = await ctx.db
    .query("reportCounts")
    .withIndex("by_event_team", (q) => q.eq("eventId", eventId).eq("teamId", teamId))
    .first();
  if (row) {
    await ctx.db.patch(row._id, { count: Math.max(0, row.count + delta) });
  } else if (delta > 0) {
    await ctx.db.insert("reportCounts", { eventId, teamId, count: delta });
  }
}

/** Report count per team at one event. Teams with none are simply absent. */
export async function reportCountsFor(
  ctx: QueryCtx,
  eventId: Id<"events">,
): Promise<Map<Id<"teams">, number>> {
  const rows = await ctx.db
    .query("reportCounts")
    .withIndex("by_event", (q) => q.eq("eventId", eventId))
    .collect();
  return new Map(rows.map((r) => [r.teamId, r.count]));
}
EOF
echo "convex/lib/reportCounts.ts written"
fi

say "Write paths: submit and delete keep the count"
cat > /tmp/ioc2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./ioc-lib.mjs";

let p = "convex/matchReports.ts";
let s = readFileSync(p, "utf8");
if (s.includes("bumpReportCount")) {
  console.log("matchReports already patched");
} else {
  s = swap(s,
`import { MAX_AUTO_CYCLES } from "./lib/scoring";`,
`import { MAX_AUTO_CYCLES } from "./lib/scoring";
import { bumpReportCount } from "./lib/reportCounts";`,
  "matchReports: imports");
  s = swap(s,
`      autoWinnerFlagged: false,
      ...rest,
    });

    return reportId;`,
`      autoWinnerFlagged: false,
      ...rest,
    });
    await bumpReportCount(ctx, event._id, teamId, 1);

    return reportId;`,
  "matchReports: submit");
  writeFileSync(p, s);
  console.log("convex/matchReports.ts patched");
}

p = "convex/admin.ts";
s = readFileSync(p, "utf8");
if (s.includes("bumpReportCount")) {
  console.log("admin already patched");
} else {
  s = swap(s,
`} from "./lib/scoring";
import type { Doc, Id } from "./_generated/dataModel";`,
`} from "./lib/scoring";
import { bumpReportCount } from "./lib/reportCounts";
import type { Doc, Id } from "./_generated/dataModel";`,
  "admin: imports");
  s = swap(s,
`    await ctx.db.delete(args.reportId);`,
`    await ctx.db.delete(args.reportId);
    await bumpReportCount(ctx, report.eventId, report.teamId, -1);`,
  "admin: deleteReport");
  writeFileSync(p, s);
  console.log("convex/admin.ts patched");
}
MJS
bun /tmp/ioc2.mjs

say "Events: purge, rebuild, and events.list counts"
cat > /tmp/ioc3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./ioc-lib.mjs";
const p = "convex/events.ts";
let s = readFileSync(p, "utf8");
if (s.includes("rebuildReportCounts")) { console.log("events already patched"); process.exit(0); }

s = swap(s,
`import type { Id } from "./_generated/dataModel";`,
`import type { Id } from "./_generated/dataModel";
import { internal } from "./_generated/api";
import { reportCountsFor } from "./lib/reportCounts";`,
"events: imports");

// events.list: count from the counter table, removable from the reports.
s = swap(s,
`      const reports = await ctx.db
        .query("matchReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const pit = await ctx.db
        .query("pitReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const lists = await ctx.db`,
`      // The count comes from reportCounts. Whether the event is removable is
      // checked against the reports themselves: a stale counter must never
      // make scouting data look deletable.
      let reportCount = 0;
      for (const n of (await reportCountsFor(ctx, event._id)).values()) reportCount += n;
      const anyReport = await ctx.db
        .query("matchReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .first();
      const pit = await ctx.db
        .query("pitReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const lists = await ctx.db`,
"events.list: reports");
s = swap(s,
`        reportCount: reports.length,`,
`        reportCount,`,
"events.list: reportCount");
s = swap(s,
`        removable: reports.length === 0 && pit.length === 0 && !hasEntries,`,
`        removable: anyReport === null && pit.length === 0 && !hasEntries,`,
"events.list: removable");

// Purge: the event's counter rows go with its reports.
s = swap(s,
`    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of pit) { await ctx.db.delete(row._id); counts.pitReports += 1; }`,
`    const counters = await ctx.db
      .query("reportCounts")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of counters) await ctx.db.delete(row._id);

    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of pit) { await ctx.db.delete(row._id); counts.pitReports += 1; }`,
"purge: counters");

s += `
/**
 * Recount one event's match reports from scratch. The counter table is a
 * cache of the reports, so this is always safe to run — after deploying the
 * table, or any time a count looks wrong.
 */
export const rebuildReportCounts = internalMutation({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    const tally = new Map<Id<"teams">, number>();
    for (const r of reports) tally.set(r.teamId, (tally.get(r.teamId) ?? 0) + 1);

    const existing = await ctx.db
      .query("reportCounts")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of existing) await ctx.db.delete(row._id);
    for (const [teamId, count] of tally) {
      await ctx.db.insert("reportCounts", { eventId: args.eventId, teamId, count });
    }
    return { reports: reports.length, teams: tally.size };
  },
});

/**
 * Recount every event, one mutation per event so a season's worth of reports
 * never lands in a single transaction.
 *   bunx convex run events:rebuildAllReportCounts          (dev)
 *   bunx convex run --prod events:rebuildAllReportCounts   (prod)
 */
export const rebuildAllReportCounts = internalMutation({
  args: {},
  handler: async (ctx) => {
    const events = await ctx.db.query("events").collect();
    for (const event of events) {
      await ctx.scheduler.runAfter(0, internal.events.rebuildReportCounts, {
        eventId: event._id,
      });
    }
    return { scheduled: events.length };
  },
});
`;

writeFileSync(p, s);
console.log("convex/events.ts patched");
MJS
bun /tmp/ioc3.mjs

say "teams.listWithStatus: counts from the counter table"
cat > /tmp/ioc4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./ioc-lib.mjs";
const p = "convex/teams.ts";
let s = readFileSync(p, "utf8");
if (s.includes("reportCountsFor")) { console.log("teams already patched"); process.exit(0); }
s = swap(s,
`import { derive, summarise } from "./lib/summarise";`,
`import { derive, summarise } from "./lib/summarise";
import { reportCountsFor } from "./lib/reportCounts";`,
"teams: imports");
s = swap(s,
`    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const counts = new Map<string, number>();
    for (const r of reports) {
      counts.set(r.teamId, (counts.get(r.teamId) ?? 0) + 1);
    }

    const tiers = await primaryTiers(ctx, event._id);`,
`    // One small row per team, rather than every report at the event.
    const counts = await reportCountsFor(ctx, event._id);

    const tiers = await primaryTiers(ctx, event._id);`,
"teams.listWithStatus: counts");
writeFileSync(p, s);
console.log("convex/teams.ts patched");
MJS
bun /tmp/ioc4.mjs
rm -f /tmp/ioc-lib.mjs /tmp/ioc1.mjs /tmp/ioc2.mjs /tmp/ioc3.mjs /tmp/ioc4.mjs

say "Push, count existing reports on dev, typecheck"
if bunx convex dev --once; then
  bunx convex run events:rebuildAllReportCounts || echo "Rebuild failed — run it by hand."
else
  echo "Convex push failed — see above."
fi
bun run typecheck || echo "Typecheck reported issues — see above."

printf '\n\033[1;33m%s\033[0m\n' \
  "After deploying to prod, run:  bunx convex run --prod events:rebuildAllReportCounts"
