#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-conclusion.sh
#   1. Ratings + final notes move into their own "Conclusion" tab
#   2. Reports submitted before the match ends are flagged
#
# The early-submit flag is DERIVED from matchStartedAt and submittedAt, so
# there is no schema change and it stays correct if the timing constants move.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/scout/form.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Timing helper"
cat > /tmp/p1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/lib/scoring.ts";
let s = readFileSync(p, "utf8");
if (s.includes("MATCH_DURATION_SECONDS")) { console.log("scoring.ts already patched"); process.exit(0); }
s += `
export const MATCH_DURATION_SECONDS =
  MATCH_TIMING.autoSeconds + MATCH_TIMING.autoPauseSeconds + MATCH_TIMING.teleopSeconds;

/**
 * A report finished before the buzzer cannot have observed the endgame — the
 * climb, the last shift's fuel, whether the robot died at 0:15. Derived rather
 * than stored so it stays correct if the timing constants change.
 * Unknowable without a time anchor, so an untimed report is never flagged.
 */
export function submittedBeforeMatchEnd(
  matchStartedAt: number | null,
  submittedAt: number,
): boolean {
  if (matchStartedAt === null) return false;
  return submittedAt < matchStartedAt + MATCH_DURATION_SECONDS * 1000;
}
`;
writeFileSync(p, s);
console.log("convex/lib/scoring.ts patched");
MJS
bun /tmp/p1.mjs

say "UI store: conclusion period"
cat > /tmp/p2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/stores/ui-store.ts";
let s = readFileSync(p, "utf8");
if (s.includes('"conclusion"')) { console.log("ui-store already patched"); process.exit(0); }
s = s.replace('matchFormPeriod: "auto" | "teleop" | "endgame";',
              'matchFormPeriod: "auto" | "teleop" | "endgame" | "conclusion";');
writeFileSync(p, s);
console.log("src/stores/ui-store.ts patched");
MJS
bun /tmp/p2.mjs

say "Match form: Conclusion tab + early-submit warning"
cat > /tmp/p3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/scout/form.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };

// --- 1. lift the Ratings card out ---
const rStart = s.indexOf('      <Card>\n        <CardHeader><CardTitle>Ratings</CardTitle></CardHeader>');
const rEnd = s.indexOf('      {suspicious && !override ? (');
if (rStart === -1 || rEnd === -1 || rEnd < rStart) fail("could not locate the Ratings card");
const ratingsCard = s.slice(rStart, rEnd).trimEnd();
s = s.slice(0, rStart) + s.slice(rEnd);

// --- 2. lift the Final notes card out of the Endgame tab ---
const fStart = s.indexOf('          <Card>\n            <CardHeader><CardTitle>Final notes</CardTitle></CardHeader>');
if (fStart === -1) fail("could not locate the Final notes card — run patch-match-form.sh first");
const fEndMarker = '          </Card>\n';
const fEnd = s.indexOf(fEndMarker, fStart);
if (fEnd === -1) fail("could not find the end of the Final notes card");
const finalNotesCard = s.slice(fStart, fEnd + fEndMarker.length).trimEnd();
s = s.slice(0, fStart) + s.slice(fEnd + fEndMarker.length);

// --- 3. add the tab trigger ---
const oldList = '          <TabsTrigger value="endgame" className="flex-1">Endgame</TabsTrigger>\n        </TabsList>';
if (!s.includes(oldList)) fail("could not find the TabsList");
s = s.replace(oldList,
  '          <TabsTrigger value="endgame" className="flex-1">Endgame</TabsTrigger>\n' +
  '          <TabsTrigger value="conclusion" className="flex-1">Conclusion</TabsTrigger>\n' +
  '        </TabsList>');

// --- 4. add the Conclusion tab before </Tabs> ---
const closeTabs = '      </Tabs>';
if (!s.includes(closeTabs)) fail("could not find </Tabs>");
const conclusion =
  '        <TabsContent value="conclusion" className="space-y-4 pt-4">\n' +
  ratingsCard + '\n\n' + finalNotesCard + '\n' +
  '        </TabsContent>\n' + closeTabs;
s = s.replace(closeTabs, conclusion);

// --- 5. early-submit detection ---
s = s.replace(
  'import {\n  EMPTY_BY_SHIFT, countedTeleopFuel, uncountedTeleopFuel, type ByShift,\n} from "@/lib/scoring";',
  'import {\n  EMPTY_BY_SHIFT, countedTeleopFuel, uncountedTeleopFuel, type ByShift,\n} from "@/lib/scoring";');

s = s.replace('  const hubStateSource =',
`  // A report finished before the buzzer cannot have seen the endgame.
  const beforeMatchEnd = startedAt !== null && phase !== "over";

  const hubStateSource =`);

const oldGate = `      {missing.length > 0 ? (`;
if (!s.includes(oldGate)) fail("could not find the missing-fields notice");
s = s.replace(oldGate,
`      {beforeMatchEnd && !earlyAck ? (
        <Card className="border-destructive">
          <CardContent className="space-y-3 pt-6">
            <div className="flex items-start gap-2">
              <AlertTriangle className="mt-0.5 size-4 shrink-0" />
              <p className="text-sm">
                The match is not over yet. A report submitted now cannot have
                seen the endgame — the climb, the last shift's fuel, or a robot
                that died in the final seconds. It will be flagged as early.
              </p>
            </div>
            <Button variant="outline" className="w-full"
              onClick={() => setEarlyAck(true)}>
              Submit early anyway
            </Button>
          </CardContent>
        </Card>
      ) : null}

      {missing.length > 0 ? (`);

s = s.replace('  const [override, setOverride] = useState(false);',
              '  const [override, setOverride] = useState(false);\n  const [earlyAck, setEarlyAck] = useState(false);');

s = s.replace('        disabled={saving || missing.length > 0 || (suspicious && !override)}',
              '        disabled={\n          saving ||\n          missing.length > 0 ||\n          (suspicious && !override) ||\n          (beforeMatchEnd && !earlyAck)\n        }');

writeFileSync(p, s);
console.log("src/routes/scout/form.tsx patched");
MJS
bun /tmp/p3.mjs

say "Reports list: early badge"
cat > /tmp/p4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/scout/index.tsx";
let s = readFileSync(p, "utf8");
if (s.includes("submittedBeforeMatchEnd")) { console.log("already patched"); process.exit(0); }
s = s.replace('import { PageShell } from "@/routes/page-shell";',
              'import { PageShell } from "@/routes/page-shell";\nimport { submittedBeforeMatchEnd } from "@/lib/scoring";');
s = s.replace(`                {report.hubStateSource === "none" ? (
                  <Badge variant="outline">No shift split</Badge>
                ) : null}`,
`                {submittedBeforeMatchEnd(report.matchStartedAt, report.submittedAt) ? (
                  <Badge variant="destructive">Early</Badge>
                ) : null}
                {report.hubStateSource === "none" ? (
                  <Badge variant="outline">No shift split</Badge>
                ) : null}`);
writeFileSync(p, s);
console.log("src/routes/scout/index.tsx patched");
MJS
bun /tmp/p4.mjs
rm -f /tmp/p1.mjs /tmp/p2.mjs /tmp/p3.mjs /tmp/p4.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
