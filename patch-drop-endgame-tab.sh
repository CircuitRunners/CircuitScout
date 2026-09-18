#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-drop-endgame-tab.sh
#   The endgame tab goes. Climb moves to the top of Conclusion.
#
#   Endgame fuel really is redundant: the clock already has an "endgame" phase
#   (the last 30 seconds), and bucketFor() banks it into `transition`, which
#   counts for BOTH alliances — the same treatment endgame fuel deserves. So
#   fuel put up in the last 30 seconds, entered on the Teleop stepper, is
#   already scored correctly without a second field for it.
#
#   The schema does not change and the endgame fields are still submitted.
#   That is deliberate: a scout editing an OLD report would otherwise zero out
#   the endgame fuel it was written with and quietly change that team's
#   totals. The form keeps hydrating those values and passes them straight
#   back; new reports simply submit zeros, because the fuel is in the shift
#   buckets now. When editing a report that carries old endgame numbers, the
#   climb card says so rather than hiding them.
#
# One thing this does NOT do: the "Endgame fuel" average on the team card now
# only reflects reports written before this change, and will drift toward zero
# as new ones come in. Say the word and I will drop that stat.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/scout/form.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
runjs() { if command -v bun >/dev/null 2>&1; then bun "$1"; else node "$1"; fi; }

say "Scout form: climb in Conclusion, endgame tab removed"
cat > /tmp/cs-endgame.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/scout/form.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
const count = (hay, needle) => hay.split(needle).length - 1;
const once = (needle, what) => {
  const n = count(s, needle);
  if (n === 0) fail(`could not find ${what}`);
  if (n > 1) fail(`${what} matched ${n} times — too ambiguous to patch`);
};
if (s.includes("legacyEndgame")) { console.log("already patched"); process.exit(0); }

const trigger = `          <TabsTrigger value="endgame" className="flex-1">Endgame</TabsTrigger>
`;
once(trigger, "the endgame tab trigger");

const tab = `        <TabsContent value="endgame" className="space-y-4 pt-4">
          <Card>
            <CardHeader><CardTitle>Endgame</CardTitle></CardHeader>
            <CardContent className="space-y-6">
              <SegmentedChoice label="Climb" options={CLIMB_OPTIONS}
                value={climb} onChange={setClimb} />
              <Stepper label="Fuel scored" value={endFuel} onChange={setEndFuel} />
              <Stepper label="Passed from neutral zone"
                value={ePassedNeutral} onChange={setEPassedNeutral} />
              <Stepper label="Passed full field"
                value={ePassedFull} onChange={setEPassedFull} />
              <Stepper label="Stole fuel" value={endStole} onChange={setEndStole} />
              <Textarea placeholder="Endgame notes" rows={2}
                value={endNotes} onChange={(e) => setEndNotes(e.target.value)} />
            </CardContent>
          </Card>

        </TabsContent>
`;
once(tab, "the endgame tab content");

const conclusionOpen = `        <TabsContent value="conclusion" className="space-y-4 pt-4">
`;
once(conclusionOpen, "the conclusion tab");

const hubStateLine = `  const hubStateSource: "timed" | "estimated" | "none" =`;
once(hubStateLine, "the hubStateSource line");

s = s.replace(trigger, "");
s = s.replace(tab, "");

// Old reports keep whatever the endgame tab recorded; the form passes it
// through untouched, so say so rather than letting it look lost.
s = s.replace(hubStateLine, `  // Values only an old report can have: the endgame tab that wrote them is
  // gone, but editing must not silently zero them.
  const legacyEndgame =
    editId !== null
    && (endFuel > 0 || ePassedNeutral > 0 || ePassedFull > 0
      || endStole > 0 || endNotes.trim() !== "");

${hubStateLine}`);

s = s.replace(conclusionOpen, `${conclusionOpen}          <Card>
            <CardHeader><CardTitle>Endgame</CardTitle></CardHeader>
            <CardContent className="space-y-3">
              <SegmentedChoice label="Climb" options={CLIMB_OPTIONS}
                value={climb} onChange={setClimb} />
              <p className="text-muted-foreground text-xs">
                Fuel scored in the last 30 seconds goes on the Teleop stepper —
                the shift timer banks it for you.
              </p>
              {legacyEndgame ? (
                <p className="text-muted-foreground border-t pt-3 text-xs">
                  This report was written with the old endgame tab: {endFuel} fuel,{" "}
                  {ePassedNeutral + ePassedFull} passed, {endStole} stolen. Those
                  stay as they were — editing here does not clear them.
                </p>
              ) : null}
            </CardContent>
          </Card>

`);

writeFileSync(p, s);
console.log("src/routes/scout/form.tsx patched");
MJS
runjs /tmp/cs-endgame.mjs
rm -f /tmp/cs-endgame.mjs

say "UI store: drop the endgame tab value"
cat > /tmp/cs-store.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/stores/ui-store.ts";
let s = readFileSync(p, "utf8");
const old = `  matchFormPeriod: "auto" | "teleop" | "endgame" | "conclusion";`;
if (!s.includes(old)) { console.log("already patched"); process.exit(0); }
s = s.replace(old, `  matchFormPeriod: "auto" | "teleop" | "conclusion";`);
writeFileSync(p, s);
console.log("src/stores/ui-store.ts patched");
MJS
runjs /tmp/cs-store.mjs
rm -f /tmp/cs-store.mjs

say "Typecheck"
if command -v bun >/dev/null 2>&1; then
  bun run typecheck || echo "Typecheck reported issues — see above."
else
  npx tsc -b --noEmit || echo "Typecheck reported issues — see above."
fi
