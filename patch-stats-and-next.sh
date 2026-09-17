#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-stats-and-next.sh
#   1. Avg passing on the team card — teleop + endgame, neutral + full field.
#   2. "Up next" advances on a TBA result as well as on anyone's report, so a
#      refresh moves the card forward even when nobody scouted the match.
#   3. A match where the robot broke no longer averages into driver, defense,
#      accuracy or BPS. Fuel numbers still include it — the fuel it scored
#      before it died is real.
#
# No schema change. `Summary` gains two fields (avgPassing, ratedReportCount),
# which is additive: the compare table, plot and workbook read what they
# already read.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/lib/summarise.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
runjs() { if command -v bun >/dev/null 2>&1; then bun "$1"; else node "$1"; fi; }

# --- 1 + 3. Summarise: whole-file rewrite -----------------------------------
# Rewritten rather than patched: the ratings now run through a branch, which
# touches most of the loop.
say "Summarise: passing, and ratings that skip a broken robot"
cat > convex/lib/summarise.ts <<'TS'
import { climbPoints, countedTeleopFuel, uncountedTeleopFuel } from "./scoring";
import type { Doc } from "../_generated/dataModel";

export type Summary = {
  reportCount: number;
  /**
   * Reports behind the rating averages. Lower than reportCount when the robot
   * broke in some matches — those are left out of driver, defense, accuracy
   * and BPS, so the two counts must be readable separately.
   */
  ratedReportCount: number;
  avgAutoFuel: number;
  avgTeleopFuel: number;
  avgUncountedFuel: number;
  avgEndgameFuel: number;
  avgTotalFuel: number;
  avgClimbPoints: number;
  /** Fuel passed to partners: teleop and endgame, neutral and full field. */
  avgPassing: number;
  avgDriver: number;
  avgDefense: number;
  avgAccuracy: number;
  avgBps: number;
  avgAdjustedBps: number;
  bpsReportCount: number;
  minTotalFuel: number;
  maxTotalFuel: number;
  brokeCount: number;
  inconsistentCount: number;
};

export const EMPTY_SUMMARY: Summary = {
  reportCount: 0, ratedReportCount: 0, avgAutoFuel: 0, avgTeleopFuel: 0,
  avgUncountedFuel: 0, avgEndgameFuel: 0, avgTotalFuel: 0, avgClimbPoints: 0,
  avgPassing: 0, avgDriver: 0, avgDefense: 0, avgAccuracy: 0, avgBps: 0,
  avgAdjustedBps: 0, bpsReportCount: 0, minTotalFuel: 0, maxTotalFuel: 0,
  brokeCount: 0, inconsistentCount: 0,
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
    // Both phases, both distances. A robot that feeds all match scores little
    // fuel itself, and this is the number that says so.
    passing:
      report.teleop.passedNeutral + report.teleop.passedFullField
      + report.endgame.passedNeutral + report.endgame.passedFullField,
  };
}

export function summarise(
  entries: { report: Doc<"matchReports">; isAutoWinner: boolean | null }[],
): Summary {
  if (entries.length === 0) return { ...EMPTY_SUMMARY };

  const auto: number[] = [], tele: number[] = [], dead: number[] = [];
  const end: number[] = [], totals: number[] = [], climbs: number[] = [];
  const passing: number[] = [];
  const drv: number[] = [], def: number[] = [], acc: number[] = [], bps: number[] = [];
  const adjusted: number[] = [];
  let broke = 0, inconsistent = 0;

  for (const { report, isAutoWinner } of entries) {
    const d = derive(report, isAutoWinner);
    auto.push(report.auto.fuel);
    tele.push(d.counted);
    dead.push(d.dead);
    end.push(report.endgame.fuel);
    totals.push(d.total);
    climbs.push(d.climb);
    passing.push(d.passing);

    // A robot that broke spent part of the match not driving, not defending
    // and not shooting. Rating that is rating the breakdown twice, since
    // brokeCount already records it, so those four averages skip the match.
    // Fuel stays in: what it scored before it died actually happened.
    if (report.ratings.broke) {
      broke += 1;
    } else {
      drv.push(report.ratings.driver);
      def.push(report.ratings.defense);
      acc.push(report.ratings.accuracy);
      // Reports written before avgBps existed must not average in as zero.
      if (report.avgBps !== undefined) {
        bps.push(report.avgBps);
        // Accuracy is a percentage; the adjusted rate is per report, then averaged.
        adjusted.push(report.avgBps * (report.ratings.accuracy / 100));
      }
    }
    if (report.ratings.inconsistent) inconsistent += 1;
  }

  return {
    reportCount: entries.length,
    ratedReportCount: drv.length,
    avgAutoFuel: mean(auto),
    avgTeleopFuel: mean(tele),
    avgUncountedFuel: mean(dead),
    avgEndgameFuel: mean(end),
    avgTotalFuel: mean(totals),
    avgClimbPoints: mean(climbs),
    avgPassing: mean(passing),
    avgDriver: mean(drv),
    avgDefense: mean(def),
    avgAccuracy: mean(acc),
    avgBps: mean(bps),
    avgAdjustedBps: mean(adjusted),
    bpsReportCount: bps.length,
    minTotalFuel: Math.min(...totals),
    maxTotalFuel: Math.max(...totals),
    brokeCount: broke,
    inconsistentCount: inconsistent,
  };
}
TS
echo "convex/lib/summarise.ts rewritten"

# --- 2. Up next: a TBA result counts as a match being over ------------------
say "Assignments: up next follows TBA and other scouts"
cat > /tmp/cs-up-next.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/assignments.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
if (s.includes("reportedMatchIds")) { console.log("already patched"); process.exit(0); }

const old = `    // "Current" is the furthest match anyone has scouted. Distance is measured
    // in matches rather than minutes: scheduled times drift during an event
    // and only refresh on re-import, so a countdown would be confidently wrong.
    const allReports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    let current = 0;
    for (const report of allReports) {
      const match = matches.find((m) => m._id === report.matchId);
      if (match && match.matchNumber > current) current = match.matchNumber;
    }`;
if (!s.includes(old)) fail("could not find the current-match block in mine()");

s = s.replace(old, `    // "Current" is the furthest match the app can see is over, from two
    // signals, whichever is further along:
    //   - a TBA result, which is authoritative but only as fresh as the last
    //     refresh, and arrives even for matches nobody scouted;
    //   - anyone's submitted report, which is immediate and pooled across
    //     scouts, so scout 1 finishing qual 12 moves everyone on to 13.
    // Distance stays in matches rather than minutes: scheduled times drift
    // during an event, so a countdown would be confidently wrong.
    const allReports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const reportedMatchIds = new Set(allReports.map((r) => r.matchId));
    let current = 0;
    for (const match of matches) {
      const played =
        (match.redScore ?? null) !== null
        || (match.blueScore ?? null) !== null
        || (match.actualTime ?? null) !== null
        || reportedMatchIds.has(match._id);
      if (played && match.matchNumber > current) current = match.matchNumber;
    }`);

writeFileSync(p, s);
console.log("convex/assignments.ts patched");
MJS
runjs /tmp/cs-up-next.mjs
rm -f /tmp/cs-up-next.mjs

# --- 1 + 3 (backend). teams.detail onto the shared summariser ---------------
# The team card's numbers came from a second copy of the averaging inside
# teams.detail, so fixing summarise alone would not have moved them. Pointing
# detail at summarise fixes it and removes the copy.
say "teams.detail: use the shared summariser"
cat > /tmp/cs-team-detail.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/teams.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
if (s.includes("./lib/summarise")) { console.log("already patched"); process.exit(0); }

const imports = `import {
  climbPoints, countedTeleopFuel, uncountedTeleopFuel,
} from "./lib/scoring";
import type { Id } from "./_generated/dataModel";`;
if (!s.includes(imports)) fail("could not find the scoring imports");

const meanHelper = `const mean = (xs: number[]) =>
  xs.length === 0 ? 0 : xs.reduce((a, b) => a + b, 0) / xs.length;

`;
if (!s.includes(meanHelper)) fail("could not find the local mean helper");

const accumulators = `    const rows = [];
    const autoF: number[] = [];
    const teleF: number[] = [];
    const deadF: number[] = [];
    const endF: number[] = [];
    const totals: number[] = [];
    const climbs: number[] = [];
    const drivers: number[] = [];
    const defenses: number[] = [];
    const accuracies: number[] = [];
    const bps: number[] = [];
    const adjusted: number[] = [];`;
if (!s.includes(accumulators)) fail("could not find the stat accumulators");

const loopMath = `      const counted =
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
      if (report.avgBps !== undefined) {
        bps.push(report.avgBps);
        adjusted.push(report.avgBps * (report.ratings.accuracy / 100));
      }`;
if (!s.includes(loopMath)) fail("could not find the per-report arithmetic");

const statsObject = `      stats: {
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
        avgBps: mean(bps),
        avgAdjustedBps: mean(adjusted),
        bpsReportCount: bps.length,
        minTotalFuel: totals.length ? Math.min(...totals) : 0,
        maxTotalFuel: totals.length ? Math.max(...totals) : 0,
      },`;
if (!s.includes(statsObject)) fail("could not find the stats object");

s = s.replace(imports, `import { derive, summarise } from "./lib/summarise";
import type { Doc, Id } from "./_generated/dataModel";`);

s = s.replace(meanHelper, "");

s = s.replace(accumulators, `    const rows = [];
    // Averages come from the shared summariser rather than a second copy of
    // the arithmetic, so the team card and the compare table cannot disagree
    // about what a driver rating is.
    const entries: { report: Doc<"matchReports">; isAutoWinner: boolean | null }[] = [];`);

s = s.replace(loopMath, `      const { counted, dead, total, climb } = derive(report, isWinner);
      entries.push({ report, isAutoWinner: isWinner });`);

s = s.replace(statsObject, `      stats: summarise(entries),`);

writeFileSync(p, s);
console.log("convex/teams.ts patched");
MJS
runjs /tmp/cs-team-detail.mjs
rm -f /tmp/cs-team-detail.mjs

# --- 1 + 3 (UI). Team card --------------------------------------------------
say "Team card: passing, and ratings that say what they exclude"
cat > /tmp/cs-team-card.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/teams/team-detail.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
if (s.includes("avgPassing")) { console.log("already patched"); process.exit(0); }

const ratings = `                  <Stat label="Climb points" value={data.stats.avgClimbPoints} />
                  <Stat label="Driver" value={data.stats.avgDriver} />
                  <Stat label="Defense" value={data.stats.avgDefense} />
                  <Stat label="Accuracy" value={data.stats.avgAccuracy} suffix="%" />`;
if (!s.includes(ratings)) fail("could not find the rating stat cards");

const ranged = `                <p className="text-muted-foreground text-xs">
                  Total fuel ranged {data.stats.minTotalFuel}–
                  {data.stats.maxTotalFuel} across those matches. Total fuel
                  counts only fuel scored into a live hub.
                </p>`;
if (!s.includes(ranged)) fail("could not find the total-fuel range note");

// Passing sits with the volume stats; the three ratings drop out entirely
// when every report had the robot broken, rather than showing 0.0.
s = s.replace(ratings, `                  <Stat label="Climb points" value={data.stats.avgClimbPoints} />
                  <Stat label="Passing" value={data.stats.avgPassing} />
                  {data.stats.ratedReportCount > 0 ? (
                    <>
                      <Stat label="Driver" value={data.stats.avgDriver} />
                      <Stat label="Defense" value={data.stats.avgDefense} />
                      <Stat label="Accuracy" value={data.stats.avgAccuracy} suffix="%" />
                    </>
                  ) : null}`);

s = s.replace(ranged, `${ranged}

                {data.stats.brokeCount > 0 ? (
                  <p className="text-muted-foreground text-xs">
                    Driver, defense, accuracy and BPS come from{" "}
                    {data.stats.ratedReportCount} of {data.stats.reportCount}{" "}
                    report{data.stats.reportCount === 1 ? "" : "s"} — the{" "}
                    {data.stats.brokeCount} where the robot broke {data.stats.brokeCount === 1 ? "is" : "are"}{" "}
                    left out. Fuel and passing still include them.
                  </p>
                ) : null}`);

writeFileSync(p, s);
console.log("src/routes/teams/team-detail.tsx patched");
MJS
runjs /tmp/cs-team-card.mjs
rm -f /tmp/cs-team-card.mjs

say "Typecheck"
if command -v bun >/dev/null 2>&1; then
  bun run typecheck || echo "Typecheck reported issues — see above."
else
  npx tsc -b --noEmit || echo "Typecheck reported issues — see above."
fi
