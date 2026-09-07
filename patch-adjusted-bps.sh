#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-adjusted-bps.sh — "Adjusted BPS" everywhere stats appear.
#
# Computed PER REPORT and then averaged: mean(bps_i x accuracy_i), not
# avgBps x avgAccuracy. A robot that shot fast-and-wild in one match and
# slow-and-accurate in another has a different effective rate than the product
# of its two averages implies. No schema change — derived on read.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/lib/summarise.ts ]] || { echo "ERROR: run track-h.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Shared summary"
cat > /tmp/a1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/lib/summarise.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("avgAdjustedBps")) { console.log("already patched"); process.exit(0); }

s = s.replace("  avgBps: number;\n  bpsReportCount: number;",
              "  avgBps: number;\n  avgAdjustedBps: number;\n  bpsReportCount: number;");
s = s.replace("avgAccuracy: 0, avgBps: 0, bpsReportCount: 0,",
              "avgAccuracy: 0, avgBps: 0, avgAdjustedBps: 0, bpsReportCount: 0,");

const oldDecl = "  const drv: number[] = [], def: number[] = [], acc: number[] = [], bps: number[] = [];";
if (!s.includes(oldDecl)) fail("could not find the accumulator declarations");
s = s.replace(oldDecl, `${oldDecl}
  const adjusted: number[] = [];`);

const oldPush = `    if (report.avgBps !== undefined) bps.push(report.avgBps);`;
if (!s.includes(oldPush)) fail("could not find the bps push");
s = s.replace(oldPush, `    if (report.avgBps !== undefined) {
      bps.push(report.avgBps);
      // Accuracy is a percentage; the adjusted rate is per report, then averaged.
      adjusted.push(report.avgBps * (report.ratings.accuracy / 100));
    }`);

s = s.replace("    avgBps: mean(bps),\n    bpsReportCount: bps.length,",
              "    avgBps: mean(bps),\n    avgAdjustedBps: mean(adjusted),\n    bpsReportCount: bps.length,");

writeFileSync(p, s);
console.log("convex/lib/summarise.ts patched");
MJS
bun /tmp/a1.mjs

say "Team detail stats"
cat > /tmp/a2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/teams.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("avgAdjustedBps")) { console.log("already patched"); process.exit(0); }

s = s.replace("    const bps: number[] = [];", "    const bps: number[] = [];\n    const adjusted: number[] = [];");
const oldPush = "      if (report.avgBps !== undefined) bps.push(report.avgBps);";
if (!s.includes(oldPush)) {
  console.log("  WARNING: teams.ts has no avgBps — run patch-bps.sh first, then re-run this.");
  process.exit(0);
}
s = s.replace(oldPush, `      if (report.avgBps !== undefined) {
        bps.push(report.avgBps);
        adjusted.push(report.avgBps * (report.ratings.accuracy / 100));
      }`);
s = s.replace("        avgBps: mean(bps),\n        bpsReportCount: bps.length,",
              "        avgBps: mean(bps),\n        avgAdjustedBps: mean(adjusted),\n        bpsReportCount: bps.length,");
writeFileSync(p, s);
console.log("convex/teams.ts patched");
MJS
bun /tmp/a2.mjs

say "CSV export"
cat > /tmp/a3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/exports.ts";
let s = readFileSync(p, "utf8");
if (s.includes("adjustedBps")) { console.log("already patched"); process.exit(0); }
s = s.replace('"driver", "defense", "accuracy", "avgBps",',
              '"driver", "defense", "accuracy", "avgBps", "adjustedBps",');
s = s.replace("          r.avgBps ?? \"\",",
`          r.avgBps ?? "",
          r.avgBps === undefined
            ? ""
            : (r.avgBps * (r.ratings.accuracy / 100)).toFixed(2),`);
writeFileSync(p, s);
console.log("convex/exports.ts patched");
MJS
bun /tmp/a3.mjs

say "Client surfaces"
cat > /tmp/a4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

// compare table
let c = readFileSync("src/components/compare-table.tsx", "utf8");
if (!c.includes("avgAdjustedBps")) {
  c = c.replace("  avgBps: number;\n  bpsReportCount: number;",
                "  avgBps: number;\n  avgAdjustedBps: number;\n  bpsReportCount: number;");
  const row = '  { label: "BPS", get: (s) => s.avgBps, higherIsBetter: true },';
  if (!c.includes(row)) fail("could not find the BPS metric row");
  c = c.replace(row, `${row}
  { label: "Adjusted BPS", get: (s) => s.avgAdjustedBps, higherIsBetter: true },`);
  writeFileSync("src/components/compare-table.tsx", c);
  console.log("src/components/compare-table.tsx patched");
}

// team detail modal
let d = readFileSync("src/routes/teams/team-detail.tsx", "utf8");
if (!d.includes("avgAdjustedBps")) {
  const anchor = `                  {data.stats.bpsReportCount > 0 ? (
                    <Stat label="Avg BPS" value={data.stats.avgBps} />
                  ) : null}`;
  if (!d.includes(anchor)) fail("could not find the BPS stat card");
  d = d.replace(anchor, `                  {data.stats.bpsReportCount > 0 ? (
                    <>
                      <Stat label="Avg BPS" value={data.stats.avgBps} />
                      <Stat label="Adjusted BPS" value={data.stats.avgAdjustedBps} />
                    </>
                  ) : null}`);
  writeFileSync("src/routes/teams/team-detail.tsx", d);
  console.log("src/routes/teams/team-detail.tsx patched");
}

// pick list chip
let t = readFileSync("src/routes/picklists/team-chip.tsx", "utf8");
if (!t.includes("avgAdjustedBps")) {
  t = t.replace("  avgClimbPoints: number;", "  avgClimbPoints: number;\n  avgAdjustedBps: number;");
  const accSpan = `          <span>acc {stats.avgAccuracy.toFixed(0)}%</span>`;
  if (!t.includes(accSpan)) fail("could not find the accuracy span on the chip");
  t = t.replace(accSpan, `${accSpan}
          <span>adj bps {stats.avgAdjustedBps.toFixed(1)}</span>`);
  writeFileSync("src/routes/picklists/team-chip.tsx", t);
  console.log("src/routes/picklists/team-chip.tsx patched");
}
MJS
bun /tmp/a4.mjs
rm -f /tmp/a1.mjs /tmp/a2.mjs /tmp/a3.mjs /tmp/a4.mjs

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
