#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-statbotics.sh — EPA from Statbotics.
#   1. EPA as a stat in the team detail modal
#   2. A second projection on the match preview, labelled EPA, beside the one
#      built from your own scouting
#
# SCHEMA CHANGE: teamEpa table.
#
# FIELD PATHS ARE DEFENSIVE. The v3 response nests EPA differently across
# versions, so the parser tries several known shapes and keeps the raw JSON of
# the first team it sees. If EPA reads 0 everywhere, look at that raw value —
# it will show which path is right.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/tba.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema"
cat > /tmp/s1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("teamEpa")) { console.log("already patched"); process.exit(0); }
const anchor = "  teams: defineTable({";
if (!s.includes(anchor)) fail("could not find the teams table");
s = s.replace(anchor, `  /**
   * Statbotics EPA for one team at one event. Kept in its own table rather
   * than on teams, so a refresh never touches imported TBA data and a failed
   * fetch leaves the roster intact.
   */
  teamEpa: defineTable({
    eventId: v.id("events"),
    teamNumber: v.number(),
    epa: v.number(),
    autoEpa: v.union(v.number(), v.null()),
    teleopEpa: v.union(v.number(), v.null()),
    endgameEpa: v.union(v.number(), v.null()),
    fetchedAt: v.number(),
    /** Raw JSON for one team, so a wrong field path is diagnosable. */
    sample: v.optional(v.string()),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamNumber"]),

${anchor}`);
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/s1.mjs

say "Convex: statbotics"
cat > convex/statbotics.ts <<'EOF'
/// <reference types="node" />

import { v } from "convex/values";
import { action, internalMutation, internalQuery, query } from "./_generated/server";
import { internal } from "./_generated/api";
import { activeEvent, requireTeamAdmin } from "./lib/guards";
import type { Id } from "./_generated/dataModel";

const BASE = "https://api.statbotics.io/v3";

/**
 * The v3 response has nested EPA objects and the exact shape has moved between
 * versions. Rather than pin one path and silently read zero, try the ones that
 * have existed and take the first number found.
 */
function pluck(row: unknown, paths: string[][]): number | null {
  for (const path of paths) {
    let node: unknown = row;
    for (const key of path) {
      if (node === null || typeof node !== "object") { node = undefined; break; }
      node = (node as Record<string, unknown>)[key];
    }
    if (typeof node === "number" && Number.isFinite(node)) return node;
  }
  return null;
}

const TOTAL_PATHS = [
  ["epa", "total_points", "mean"],
  ["epa", "breakdown", "total_points"],
  ["epa_end"],
  ["epa", "mean"],
];
const AUTO_PATHS = [
  ["epa", "breakdown", "auto_points"],
  ["epa", "breakdown", "auto_points", "mean"],
  ["auto_epa_end"],
];
const TELEOP_PATHS = [
  ["epa", "breakdown", "teleop_points"],
  ["epa", "breakdown", "teleop_points", "mean"],
  ["teleop_epa_end"],
];
const ENDGAME_PATHS = [
  ["epa", "breakdown", "endgame_points"],
  ["epa", "breakdown", "endgame_points", "mean"],
  ["endgame_epa_end"],
];

export const forEvent = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return { rows: [], fetchedAt: null, sample: null };
    const rows = await ctx.db
      .query("teamEpa")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    return {
      rows: rows.map((r) => ({
        teamNumber: r.teamNumber,
        epa: r.epa,
        autoEpa: r.autoEpa,
        teleopEpa: r.teleopEpa,
        endgameEpa: r.endgameEpa,
      })),
      fetchedAt: rows.reduce<number | null>(
        (max, r) => (max === null || r.fetchedAt > max ? r.fetchedAt : max), null),
      sample: rows.find((r) => r.sample)?.sample ?? null,
    };
  },
});

export const activeEventKey = internalQuery({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    return event ? { eventId: event._id, eventKey: event.tbaEventKey } : null;
  },
});

export const store = internalMutation({
  args: {
    eventId: v.id("events"),
    rows: v.array(v.object({
      teamNumber: v.number(),
      epa: v.number(),
      autoEpa: v.union(v.number(), v.null()),
      teleopEpa: v.union(v.number(), v.null()),
      endgameEpa: v.union(v.number(), v.null()),
    })),
    sample: v.string(),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("teamEpa")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    const byTeam = new Map(existing.map((r) => [r.teamNumber, r]));
    const now = Date.now();

    let first = true;
    for (const row of args.rows) {
      const fields = { ...row, fetchedAt: now, sample: first ? args.sample : undefined };
      first = false;
      const found = byTeam.get(row.teamNumber);
      if (found) await ctx.db.patch(found._id, fields);
      else await ctx.db.insert("teamEpa", { eventId: args.eventId, ...fields });
    }
    return { stored: args.rows.length };
  },
});

async function fetchEvent(eventKey: string) {
  // One request for the whole event rather than one per team — 40-odd calls
  // per refresh would be rude to a free API and slow besides.
  const response = await fetch(
    `${BASE}/team_events?event=${encodeURIComponent(eventKey)}&limit=200`,
    { headers: { Accept: "application/json" } },
  );
  if (!response.ok) {
    throw new Error(`Statbotics returned ${response.status} for ${eventKey}.`);
  }
  const body = (await response.json()) as unknown;
  const list = Array.isArray(body) ? body : [];
  if (list.length === 0) {
    throw new Error(`Statbotics has no data for ${eventKey} yet.`);
  }

  const rows = list.flatMap((row) => {
    const teamNumber = pluck(row, [["team"], ["team_number"]]);
    const epa = pluck(row, TOTAL_PATHS);
    if (teamNumber === null || epa === null) return [];
    return [{
      teamNumber,
      epa,
      autoEpa: pluck(row, AUTO_PATHS),
      teleopEpa: pluck(row, TELEOP_PATHS),
      endgameEpa: pluck(row, ENDGAME_PATHS),
    }];
  });

  return { rows, sample: JSON.stringify(list[0]) };
}

/** Manual refresh. Statbotics updates as matches are played. */
export const refresh = action({
  args: {},
  handler: async (ctx): Promise<{ stored: number }> => {
    await ctx.runQuery(internal.statbotics.requireAdminCheck, {});
    const event = await ctx.runQuery(internal.statbotics.activeEventKey, {});
    if (!event) throw new Error("No active event.");

    const { rows, sample } = await fetchEvent(event.eventKey);
    return await ctx.runMutation(internal.statbotics.store, {
      eventId: event.eventId as Id<"events">,
      rows,
      sample,
    });
  },
});

export const requireAdminCheck = internalQuery({
  args: {},
  handler: async (ctx) => {
    await requireTeamAdmin(ctx);
    return true;
  },
});

/** Called by the cron for every event a team currently has active. */
export const refreshAll = action({
  args: {},
  handler: async (ctx): Promise<{ events: number }> => {
    const events = await ctx.runQuery(internal.statbotics.activeEventKeys, {});
    let done = 0;
    for (const event of events) {
      try {
        const { rows, sample } = await fetchEvent(event.eventKey);
        await ctx.runMutation(internal.statbotics.store, {
          eventId: event.eventId as Id<"events">,
          rows,
          sample,
        });
        done += 1;
      } catch {
        // One event without Statbotics data must not stop the others.
      }
    }
    return { events: done };
  },
});

export const activeEventKeys = internalQuery({
  args: {},
  handler: async (ctx) => {
    const settings = await ctx.db.query("teamSettings").collect();
    const ids = [...new Set(settings.flatMap((s) => (s.activeEventId ? [s.activeEventId] : [])))];
    const out = [];
    for (const id of ids) {
      const event = await ctx.db.get(id);
      if (event && !event.deletedAt) {
        out.push({ eventId: event._id, eventKey: event.tbaEventKey });
      }
    }
    return out;
  },
});
EOF

say "Cron: refresh EPA"
cat > /tmp/s2.mjs <<'MJS'
import { readFileSync, writeFileSync, existsSync } from "node:fs";
const p = "convex/crons.ts";
if (!existsSync(p)) {
  writeFileSync(p, `import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

export default crons;
`);
}
let s = readFileSync(p, "utf8");
if (s.includes("statbotics")) { console.log("cron already patched"); process.exit(0); }
s = s.replace("export default crons;",
`// Statbotics recomputes as matches are played, so this follows the event
// rather than the schedule release. Two hours is often enough to be current
// without hammering a free API.
crons.interval(
  "refresh statbotics epa",
  { hours: 2 },
  internal.statbotics.refreshAll,
  {},
);

export default crons;`);
writeFileSync(p, s);
console.log("convex/crons.ts patched");
MJS
bun /tmp/s2.mjs

say "Team detail: EPA stat"
cat > /tmp/s3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/teams/team-detail.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("statbotics")) { console.log("already patched"); process.exit(0); }

s = s.replace("export function TeamDetail({", `function useEpa(teamNumber: number | null) {
  const data = useQuery(api.statbotics.forEvent);
  if (teamNumber === null) return null;
  return data?.rows.find((r) => r.teamNumber === teamNumber) ?? null;
}

export function TeamDetail({`);

s = s.replace(`  const data = useQuery(
    api.teams.detail,
    teamNumber === null ? "skip" : { teamNumber },
  );`,
`  const data = useQuery(
    api.teams.detail,
    teamNumber === null ? "skip" : { teamNumber },
  );
  const epa = useEpa(teamNumber);`);

const anchor = `                  <Stat label="Dead-hub fuel" value={data.stats.avgUncountedFuel} />`;
if (!s.includes(anchor)) fail("could not find the stat grid");
s = s.replace(anchor, `${anchor}
                  {epa ? (
                    <div className="rounded-lg border p-3">
                      <p className="text-muted-foreground text-xs">EPA</p>
                      <p className="text-xl font-semibold tabular-nums">
                        {epa.epa.toFixed(1)}
                      </p>
                      <p className="text-muted-foreground text-[10px]">
                        Statbotics, not your scouting
                      </p>
                    </div>
                  ) : null}`);

writeFileSync(p, s);
console.log("src/routes/teams/team-detail.tsx patched");
MJS
bun /tmp/s3.mjs

say "Match preview: EPA projection"
cat > /tmp/s4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/matches/preview.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("statbotics")) { console.log("already patched"); process.exit(0); }

s = s.replace("export default function MatchPreviewPage() {",
`export default function MatchPreviewPage() {
  const epaData = useQuery(api.statbotics.forEvent);`);

s = s.replace("  const redProjected = projected(data.red);",
`  const epaByTeam = new Map((epaData?.rows ?? []).map((r) => [r.teamNumber, r.epa]));
  const epaSum = (side: Robot[]) =>
    side.reduce((sum, r) => sum + (epaByTeam.get(r.teamNumber) ?? 0), 0);
  const epaCovered = (side: Robot[]) =>
    side.filter((r) => epaByTeam.has(r.teamNumber)).length;

  const redProjected = projected(data.red);`);

const anchor = `        <Card>
          <CardHeader>
            <CardTitle>Projected output</CardTitle>`;
if (!s.includes(anchor)) fail("could not find the projected output card");
s = s.replace(anchor, `        <Card>
          <CardHeader>
            <CardTitle>Projected · scouter data</CardTitle>`);

// second projection, from EPA
const insertAfter = `          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{played ? "Actual score" : "Scheduled"}</CardTitle>`;
if (!s.includes(insertAfter)) fail("could not find the score card");
s = s.replace(insertAfter, `          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Projected · EPA</CardTitle>
            <CardDescription>
              Statbotics EPA summed per alliance. Independent of your scouting,
              so a wide gap between the two is worth a look rather than a
              tiebreak.
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap items-center gap-6">
            {epaData === undefined ? (
              <p className="text-muted-foreground text-sm">Loading…</p>
            ) : epaByTeam.size === 0 ? (
              <p className="text-muted-foreground text-sm">
                No EPA yet — an admin can pull it from the Admin page.
              </p>
            ) : (
              <>
                <div>
                  <p className="text-xs text-red-600 dark:text-red-400">Red</p>
                  <p className="text-3xl font-semibold tabular-nums">
                    {epaSum(data.red).toFixed(0)}
                  </p>
                </div>
                <div>
                  <p className="text-xs text-blue-600 dark:text-blue-400">Blue</p>
                  <p className="text-3xl font-semibold tabular-nums">
                    {epaSum(data.blue).toFixed(0)}
                  </p>
                </div>
                {epaCovered(data.red) + epaCovered(data.blue) < 6 ? (
                  <Badge variant="outline">
                    Only {epaCovered(data.red) + epaCovered(data.blue)} of 6 have EPA
                  </Badge>
                ) : null}
              </>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{played ? "Actual score" : "Scheduled"}</CardTitle>`);

s = s.replace('<div className="grid gap-4 md:grid-cols-2">',
              '<div className="grid gap-4 md:grid-cols-3">');

writeFileSync(p, s);
console.log("src/routes/matches/preview.tsx patched");
MJS
bun /tmp/s4.mjs

say "Admin: refresh button"
cat > /tmp/s5.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/index.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("statbotics")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { useAction, useMutation, useQuery } from "convex/react";',
              'import { useAction, useMutation, useQuery } from "convex/react";');
s = s.replace("  const importEvent = useAction(api.tba.importEvent);",
`  const importEvent = useAction(api.tba.importEvent);
  const refreshEpa = useAction(api.statbotics.refresh);
  const epa = useQuery(api.statbotics.forEvent);
  const [refreshing, setRefreshing] = useState(false);`);

const anchor = `      <RolesTable />`;
if (!s.includes(anchor)) fail("could not find RolesTable");
s = s.replace(anchor, `      <Card>
        <CardHeader>
          <CardTitle>Statbotics EPA</CardTitle>
          <CardDescription>
            Refreshes automatically every two hours during an event. Pull it
            now if you want the numbers current before alliance selection.
            {epa?.fetchedAt
              ? \` Last pulled \${new Date(epa.fetchedAt).toLocaleString()}.\`
              : " Never pulled."}
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap items-center gap-3">
          <Button variant="outline" disabled={refreshing}
            onClick={() => {
              setRefreshing(true);
              void refreshEpa({})
                .then((r) => toast.success(\`EPA pulled for \${r.stored} teams\`))
                .catch((error: unknown) =>
                  toast.error("Could not reach Statbotics", {
                    description: error instanceof Error ? error.message : String(error),
                  }))
                .finally(() => setRefreshing(false));
            }}>
            Refresh EPA
          </Button>
          <span className="text-muted-foreground text-xs tabular-nums">
            {epa?.rows.length ?? 0} teams
          </span>
        </CardContent>
      </Card>

${anchor}`);

writeFileSync(p, s);
console.log("src/routes/admin/index.tsx patched");
MJS
bun /tmp/s5.mjs
rm -f /tmp/s1.mjs /tmp/s2.mjs /tmp/s3.mjs /tmp/s4.mjs /tmp/s5.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
