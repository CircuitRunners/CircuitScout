#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-coverage.sh
#   Coverage becomes the share of robot-matches with at least one report.
#
#   It was reports / (matches * 6), which sails past 100% as soon as two
#   scouts cover the same robot — and redundant coverage is deliberate here,
#   so the old number was guaranteed to be wrong at a well-staffed event.
#
#   The numerator is now slots filled, not reports filed. A slot is one robot
#   in one match; it counts once no matter how many scouts watched it, and a
#   report filed against a team that was not in that match fills nothing.
#
#   The denominator comes from the schedule's own alliances rather than a
#   hardcoded 6, so a match listed with a missing team is not counted as a
#   robot nobody scouted.
#
# No schema change. stats.coverage totals gain `slots` and `covered`, and a
# new lightweight stats.matchCoverage query backs the dashboard metric.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/stats.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
runjs() { if command -v bun >/dev/null 2>&1; then bun "$1"; else node "$1"; fi; }

say "Stats: slot-based coverage"
cat > /tmp/cs-coverage.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/stats.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
const count = (hay, needle) => hay.split(needle).length - 1;
const once = (needle, what) => {
  const n = count(s, needle);
  if (n === 0) fail(`could not find ${what}`);
  if (n > 1) fail(`${what} matched ${n} times — too ambiguous to patch`);
};
if (s.includes("coveredSlots")) { console.log("already patched"); process.exit(0); }

const anchor = `export const coverage = query({`;
once(anchor, "the coverage query");

const totals = `      totals: {
        teams: loaded.teams.length,
        matches: loaded.matches.length,
        reports: loaded.reports.length,
        possible: loaded.matches.length * 6,
      },`;
once(totals, "the coverage totals");

s = s.replace(anchor, `/**
 * Robot-matches covered, out of robot-matches on the schedule. One robot in
 * one match is one slot: it fills once, however many scouts watched it. That
 * is the whole point — counting reports instead runs past 100% the moment two
 * scouts double up, which is a thing this app encourages.
 */
function coveredSlots(loaded: NonNullable<Awaited<ReturnType<typeof loadEvent>>>) {
  const seenByMatch = new Map<Id<"matches">, Set<number>>();
  for (const report of loaded.reports) {
    const team = loaded.teamById.get(report.teamId);
    if (!team) continue;
    const seen = seenByMatch.get(report.matchId) ?? new Set<number>();
    seen.add(team.number);
    seenByMatch.set(report.matchId, seen);
  }

  let slots = 0;
  let covered = 0;
  for (const match of loaded.matches) {
    const seen = seenByMatch.get(match._id) ?? new Set<number>();
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

/** Just the fraction, for the dashboard metric. */
export const matchCoverage = query({
  args: {},
  handler: async (ctx) => {
    const loaded = await loadEvent(ctx);
    if (!loaded) return { slots: 0, covered: 0 };
    return coveredSlots(loaded);
  },
});

${anchor}`);

s = s.replace(totals, `      totals: {
        teams: loaded.teams.length,
        matches: loaded.matches.length,
        reports: loaded.reports.length,
        possible: loaded.matches.length * 6,
        ...coveredSlots(loaded),
      },`);

writeFileSync(p, s);
console.log("convex/stats.ts patched");
MJS
runjs /tmp/cs-coverage.mjs
rm -f /tmp/cs-coverage.mjs

say "Dashboard: coverage metric"
cat > /tmp/cs-dash-coverage.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/dashboard.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
if (s.includes("matchCoverage")) { console.log("already patched"); process.exit(0); }

const maths = `  // Six robots per match is full coverage. Anything less is a gap you want to
  // see now rather than during alliance selection.
  const expected = (matches?.length ?? 0) * 6;
  const coverage = expected === 0 ? 0 : Math.round((reports / expected) * 100);`;
if (!s.includes(maths)) fail("could not find the coverage maths");

const metric = `        <Metric label="Coverage" value={\`\${coverage}%\`}
          hint={\`of \${expected} possible robot-matches\`} />`;
if (!s.includes(metric)) fail("could not find the coverage metric");

const queries = `  const assignments = useQuery(api.assignments.mine);`;
if (!s.includes(queries)) fail("could not find the dashboard queries");

s = s.replace(queries, `${queries}
  const slots = useQuery(api.stats.matchCoverage);`);

s = s.replace(maths, `  // A robot-match counts once it has any report at all. Reports over slots
  // would pass 100% whenever two scouts double up, which is encouraged.
  const covered = slots?.covered ?? 0;
  const totalSlots = slots?.slots ?? 0;
  const coverage = totalSlots === 0 ? 0 : Math.round((covered / totalSlots) * 100);`);

s = s.replace(metric, `        <Metric label="Coverage" value={\`\${coverage}%\`}
          hint={\`\${covered} of \${totalSlots} robot-matches\`} />`);

writeFileSync(p, s);
console.log("src/routes/dashboard.tsx patched");
MJS
runjs /tmp/cs-dash-coverage.mjs
rm -f /tmp/cs-dash-coverage.mjs

say "Coverage page: say how many slots are filled"
cat > /tmp/cs-data-coverage.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/data.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
if (s.includes("robot-matches covered")) { console.log("already patched"); process.exit(0); }

const card = `          <Card>
            <CardHeader>
              <CardDescription>Reports</CardDescription>
              <CardTitle className="text-3xl tabular-nums">
                {totals.reports}
                <span className="text-muted-foreground text-lg">
                  /{totals.possible}
                </span>
              </CardTitle>
            </CardHeader>
          </Card>`;
if (!s.includes(card)) fail("could not find the reports card");

// The headline stays a report count, which can exceed the slot count on
// purpose. The line under it is the number that answers "are we covered".
s = s.replace(card, `          <Card>
            <CardHeader>
              <CardDescription>Reports</CardDescription>
              <CardTitle className="text-3xl tabular-nums">
                {totals.reports}
                <span className="text-muted-foreground text-lg">
                  /{totals.possible}
                </span>
              </CardTitle>
              <CardDescription>
                {totals.covered} of {totals.slots} robot-matches covered
              </CardDescription>
            </CardHeader>
          </Card>`);

writeFileSync(p, s);
console.log("src/routes/admin/data.tsx patched");
MJS
runjs /tmp/cs-data-coverage.mjs
rm -f /tmp/cs-data-coverage.mjs

say "Typecheck"
if command -v bun >/dev/null 2>&1; then
  bun run typecheck || echo "Typecheck reported issues — see above."
else
  npx tsc -b --noEmit || echo "Typecheck reported issues — see above."
fi
