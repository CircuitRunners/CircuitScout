#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-refresh-both.sh
#   1. TBA score refresh — scores only, not a full re-import
#   2. One cron and one button refreshing Statbotics and TBA together
#   3. Automatic refresh runs only for events a team actually has active
#   4. Adds the match-preview EPA card, which patch-statbotics could not place
#      without patch-match-scores applied
#
# RUN patch-match-scores.sh FIRST. No schema change here — that one adds the
# score fields.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/statbotics.ts ]] || { echo "ERROR: run patch-statbotics.sh first" >&2; exit 1; }
grep -q "redScore" convex/schema.ts || {
  echo "ERROR: run patch-match-scores.sh first — the score fields are missing." >&2
  exit 1
}
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "TBA: score-only refresh"
cat > /tmp/rb1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

let t = readFileSync("convex/tba.ts", "utf8");
if (!t.includes("refreshScores")) {
  t += `
/**
 * Re-reads only the qualification schedule and patches scores and times.
 * Deliberately not a full import: teams and match pairings do not change every
 * few minutes, and rewriting them during an event risks disturbing rows that
 * scouting data points at.
 */
export const refreshScores = action({
  args: { eventKey: v.string() },
  handler: async (ctx, args): Promise<{ updated: number }> => {
    const matches = await tbaFetch<TbaMatch[]>(\`/event/\${args.eventKey}/matches/simple\`);
    const quals = matches.filter((m) => m.comp_level === "qm");

    return await ctx.runMutation(internal.events.applyScores, {
      tbaEventKey: args.eventKey,
      rows: quals.map((m) => ({
        tbaMatchKey: m.key,
        scheduledTime: seconds(m.time),
        predictedTime: seconds(m.predicted_time),
        actualTime: seconds(m.actual_time),
        redScore: score(m.alliances.red.score),
        blueScore: score(m.alliances.blue.score),
        winningAlliance: m.winning_alliance ?? "",
      })),
    });
  },
});
`;
  writeFileSync("convex/tba.ts", t);
  console.log("convex/tba.ts patched");
}

let e = readFileSync("convex/events.ts", "utf8");
if (!e.includes("applyScores")) {
  e += `
/** Patches score and timing fields on existing matches. Adds nothing. */
export const applyScores = internalMutation({
  args: {
    tbaEventKey: v.string(),
    rows: v.array(v.object({
      tbaMatchKey: v.string(),
      scheduledTime: v.union(v.number(), v.null()),
      predictedTime: v.union(v.number(), v.null()),
      actualTime: v.union(v.number(), v.null()),
      redScore: v.union(v.number(), v.null()),
      blueScore: v.union(v.number(), v.null()),
      winningAlliance: v.string(),
    })),
  },
  handler: async (ctx, args) => {
    const event = await ctx.db
      .query("events")
      .withIndex("by_key", (q) => q.eq("tbaEventKey", args.tbaEventKey))
      .unique();
    if (!event) return { updated: 0 };

    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const byKey = new Map(matches.map((m) => [m.tbaMatchKey, m]));

    let updated = 0;
    for (const row of args.rows) {
      const match = byKey.get(row.tbaMatchKey);
      if (!match) continue;
      await ctx.db.patch(match._id, {
        scheduledTime: row.scheduledTime,
        predictedTime: row.predictedTime,
        actualTime: row.actualTime,
        redScore: row.redScore,
        blueScore: row.blueScore,
        winningAlliance: row.winningAlliance,
      });
      updated += 1;
    }
    return { updated };
  },
});
`;
  writeFileSync("convex/events.ts", e);
  console.log("convex/events.ts patched");
}
MJS
bun /tmp/rb1.mjs

say "Combined refresh"
cat > convex/refresh.ts <<'EOF'
import { action } from "./_generated/server";
import { internal, api } from "./_generated/api";

/**
 * Statbotics EPA and TBA scores together — they go stale at the same rate and
 * for the same reason, so refreshing them separately just means one of them is
 * always older than the other.
 */
export const now = action({
  args: {},
  handler: async (ctx): Promise<{ epaTeams: number; matchesUpdated: number }> => {
    await ctx.runQuery(internal.statbotics.requireAdminCheck, {});
    const event = await ctx.runQuery(internal.statbotics.activeEventKey, {});
    if (!event) throw new Error("No active event.");

    // Independent failures: Statbotics having no data for a new event should
    // not stop scores coming through, and vice versa.
    let epaTeams = 0;
    let matchesUpdated = 0;
    const problems: string[] = [];

    try {
      const result = await ctx.runAction(api.statbotics.refresh, {});
      epaTeams = result.stored;
    } catch (error) {
      problems.push(error instanceof Error ? error.message : String(error));
    }

    try {
      const result = await ctx.runAction(api.tba.refreshScores, {
        eventKey: event.eventKey,
      });
      matchesUpdated = result.updated;
    } catch (error) {
      problems.push(error instanceof Error ? error.message : String(error));
    }

    if (epaTeams === 0 && matchesUpdated === 0 && problems.length > 0) {
      throw new Error(problems.join(" · "));
    }
    return { epaTeams, matchesUpdated };
  },
});

/**
 * The cron. Iterates only events some team currently has active, so a
 * deployment sitting idle between competitions makes no outbound calls at all.
 */
export const scheduled = action({
  args: {},
  handler: async (ctx): Promise<{ events: number }> => {
    const events = await ctx.runQuery(internal.statbotics.activeEventKeys, {});
    if (events.length === 0) return { events: 0 };

    for (const event of events) {
      try {
        await ctx.runAction(api.tba.refreshScores, { eventKey: event.eventKey });
      } catch {
        // A single event failing must not stop the rest.
      }
    }
    const epa = await ctx.runAction(api.statbotics.refreshAll, {});
    return { events: epa.events };
  },
});
EOF
echo "convex/refresh.ts written"

say "Cron"
cat > /tmp/rb2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/crons.ts";
let s = readFileSync(p, "utf8");
if (s.includes("refresh.scheduled")) { console.log("already patched"); process.exit(0); }
s = s.replace(/crons\.interval\(\s*"refresh statbotics epa",[\s\S]*?\);/,
`crons.interval(
  "refresh statbotics and tba",
  { hours: 2 },
  internal.refresh.scheduled,
  {},
);`);
if (!s.includes("refresh.scheduled")) {
  s = s.replace("export default crons;",
`crons.interval(
  "refresh statbotics and tba",
  { hours: 2 },
  internal.refresh.scheduled,
  {},
);

export default crons;`);
}
writeFileSync(p, s);
console.log("convex/crons.ts patched");
MJS
bun /tmp/rb2.mjs

say "Admin button"
cat > /tmp/rb3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/index.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("refresh.now")) { console.log("already patched"); process.exit(0); }

const card = `      <Card>
        <CardHeader>
          <CardTitle>Statbotics &amp; TBA</CardTitle>
          <CardDescription>
            EPA and match scores refresh together every two hours, and only
            while a team has an event active. Pull them now if you want the
            numbers current before alliance selection.
            {epa?.fetchedAt
              ? \` Last pulled \${new Date(epa.fetchedAt).toLocaleString()}.\`
              : " Never pulled."}
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap items-center gap-3">
          <Button variant="outline" disabled={refreshing}
            onClick={() => {
              setRefreshing(true);
              void refreshBoth({})
                .then((r) =>
                  toast.success("Refreshed", {
                    description:
                      \`EPA for \${r.epaTeams} teams · \${r.matchesUpdated} matches updated.\`,
                  }))
                .catch((error: unknown) =>
                  toast.error("Refresh failed", {
                    description: error instanceof Error ? error.message : String(error),
                  }))
                .finally(() => setRefreshing(false));
            }}>
            Refresh Statbotics/TBA
          </Button>
          <span className="text-muted-foreground text-xs tabular-nums">
            {epa?.rows.length ?? 0} teams
          </span>
        </CardContent>
      </Card>

`;

// patch-statbotics aborted before reaching this file for many repos, so the
// card may not exist at all. Add it if missing, convert it if present.
if (s.includes("Refresh EPA")) {
  const from = s.indexOf("      <Card>\n        <CardHeader>\n          <CardTitle>Statbotics EPA</CardTitle>");
  const to = s.indexOf("      <RolesTable />");
  if (from === -1 || to === -1) fail("could not locate the existing EPA card");
  s = s.slice(0, from) + card + s.slice(to);
  s = s.replace("  const refreshEpa = useAction(api.statbotics.refresh);",
                "  const refreshBoth = useAction(api.refresh.now);");
  console.log("  converted the existing card");
} else {
  const anchor = "      <RolesTable />";
  if (!s.includes(anchor)) fail("could not find RolesTable");
  s = s.replace(anchor, card + anchor);
  s = s.replace("  const importEvent = useAction(api.tba.importEvent);",
`  const importEvent = useAction(api.tba.importEvent);
  const refreshBoth = useAction(api.refresh.now);
  const epa = useQuery(api.statbotics.forEvent);
  const [refreshing, setRefreshing] = useState(false);`);
  console.log("  added the card (patch-statbotics never reached this file)");
}

writeFileSync(p, s);
console.log("src/routes/admin/index.tsx patched");
MJS
bun /tmp/rb3.mjs

say "Match preview: EPA card (missed earlier)"
cat > /tmp/rb4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/matches/preview.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("statbotics")) { console.log("EPA card already present"); process.exit(0); }

s = s.replace("export default function MatchPreviewPage() {",
`export default function MatchPreviewPage() {
  const epaData = useQuery(api.statbotics.forEvent);`);

const projAnchor = "  const redProjected = projected(data.red);";
if (!s.includes(projAnchor)) fail("could not find the projection calc");
s = s.replace(projAnchor,
`  const epaByTeam = new Map((epaData?.rows ?? []).map((r) => [r.teamNumber, r.epa]));
  const epaSum = (side: Robot[]) =>
    side.reduce((sum, r) => sum + (epaByTeam.get(r.teamNumber) ?? 0), 0);
  const epaCovered = (side: Robot[]) =>
    side.filter((r) => epaByTeam.has(r.teamNumber)).length;

${projAnchor}`);

s = s.replace("<CardTitle>Projected output</CardTitle>",
              "<CardTitle>Projected · scouter data</CardTitle>");

const scoreCard = `        <Card>
          <CardHeader>
            <CardTitle>{played ? "Actual score" : "Scheduled"}</CardTitle>`;
if (!s.includes(scoreCard)) fail("could not find the score card — run patch-match-scores.sh first");
s = s.replace(scoreCard, `        <Card>
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

${scoreCard}`);

s = s.replace('<div className="grid gap-4 md:grid-cols-2">',
              '<div className="grid gap-4 md:grid-cols-3">');

writeFileSync(p, s);
console.log("src/routes/matches/preview.tsx patched");
MJS
bun /tmp/rb4.mjs
rm -f /tmp/rb1.mjs /tmp/rb2.mjs /tmp/rb3.mjs /tmp/rb4.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
