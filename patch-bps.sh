#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-bps.sh — "Average BPS (observed)" slider, 0-35, in the Conclusion tab.
# SCHEMA CHANGE: matchReports.avgBps (optional, so existing reports stay valid).
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/scout/form.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema"
cat > /tmp/b1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
if (s.includes("avgBps")) { console.log("already present"); process.exit(0); }
const anchor = "    finalNotes: v.optional(v.string()),";
if (!s.includes(anchor)) { console.error("could not find finalNotes — run patch-match-form.sh first"); process.exit(1); }
s = s.replace(anchor, "    avgBps: v.optional(v.number()),   // observed balls per second\n" + anchor);
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/b1.mjs

say "Mutation validators"
cat > /tmp/b2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/matchReports.ts";
let s = readFileSync(p, "utf8");
if (s.includes("avgBps")) { console.log("already patched"); process.exit(0); }
s = s.replace("  finalNotes: v.string(),", "  avgBps: v.number(),\n  finalNotes: v.string(),");
s = s.replace("      finalNotes: args.finalNotes,", "      avgBps: args.avgBps,\n      finalNotes: args.finalNotes,");
writeFileSync(p, s);
console.log("convex/matchReports.ts patched");
MJS
bun /tmp/b2.mjs

say "Form: slider in Conclusion"
cat > /tmp/b3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/scout/form.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("avgBps")) { console.log("already patched"); process.exit(0); }

s = s.replace('  const [accuracy, setAccuracy] = useState<number | null>(null);',
              '  const [accuracy, setAccuracy] = useState<number | null>(null);\n  const [avgBps, setAvgBps] = useState<number | null>(null);');

// hydrate when editing
s = s.replace("    setAccuracy(editing.ratings.accuracy);",
              "    setAccuracy(editing.ratings.accuracy);\n    setAvgBps(editing.avgBps ?? null);");

// send it
s = s.replace("        finalNotes,", "        avgBps: avgBps ?? 0,\n        finalNotes,");

// the slider itself, after shooting accuracy
const anchor = `          <RatingScale
            label="Shooting accuracy"
            value={accuracy}
            onChange={setAccuracy}
            min={0}
            max={100}
            step={5}
            unit="%"
          />`;
if (!s.includes(anchor)) fail("could not find the accuracy slider — run patch-match-form.sh first");
s = s.replace(anchor, anchor + `
          <RatingScale
            label="Average BPS (observed)"
            value={avgBps}
            onChange={setAvgBps}
            min={0}
            max={35}
            step={1}
            unit=" bps"
          />`);

writeFileSync(p, s);
console.log("src/routes/scout/form.tsx patched");
MJS
bun /tmp/b3.mjs

say "Team detail: surface the average"
cat > /tmp/b4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const q = "convex/teams.ts";
let a = readFileSync(q, "utf8");
if (!a.includes("avgBps")) {
  a = a.replace("    const accuracies: number[] = [];",
                "    const accuracies: number[] = [];\n    const bps: number[] = [];");
  // Reports written before this field existed must not be averaged in as zero.
  a = a.replace("      accuracies.push(report.ratings.accuracy);",
                "      accuracies.push(report.ratings.accuracy);\n      if (report.avgBps !== undefined) bps.push(report.avgBps);");
  a = a.replace("        avgAccuracy: mean(accuracies),",
                "        avgAccuracy: mean(accuracies),\n        avgBps: mean(bps),\n        bpsReportCount: bps.length,");
  writeFileSync(q, a);
  console.log("convex/teams.ts patched");
} else { console.log("teams.ts already patched"); }

const p = "src/routes/teams/team-detail.tsx";
let s = readFileSync(p, "utf8");
if (!s.includes("avgBps")) {
  s = s.replace('                  <Stat label="Dead-hub fuel" value={data.stats.avgUncountedFuel} />',
`                  <Stat label="Dead-hub fuel" value={data.stats.avgUncountedFuel} />
                  {data.stats.bpsReportCount > 0 ? (
                    <Stat label="Avg BPS" value={data.stats.avgBps} />
                  ) : null}`);
  writeFileSync(p, s);
  console.log("src/routes/teams/team-detail.tsx patched");
} else { console.log("team-detail already patched"); }
MJS
bun /tmp/b4.mjs
rm -f /tmp/b1.mjs /tmp/b2.mjs /tmp/b3.mjs /tmp/b4.mjs

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
