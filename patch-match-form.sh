#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-match-form.sh
#   1. Fuel steppers ordered -10 -5 -1 +1 +5 +10
#   2. Ratings become sliders; accuracy is a percentage
#   3. Auto winner moves into the Auto section
#   4. Final notes added to Endgame  (SCHEMA CHANGE — see below)
#   5. Start position, ratings, auto winner and final notes are required
#
# SCHEMA CHANGE: adds matchReports.finalNotes as v.optional(v.string()).
# Optional, not required, so reports written before this patch stay valid.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/scout/form.tsx ]] || { echo "ERROR: run from the repo root, after track-c" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Slider component"
bunx shadcn@latest add -y slider

say "Schema: finalNotes"
cat > /tmp/patch-schema.mjs <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
if (s.includes("finalNotes")) { console.log("schema already has finalNotes"); process.exit(0); }
const anchor = "    matchStartedAt: v.union(v.number(), v.null()),";
if (!s.includes(anchor)) { console.error("could not find matchStartedAt in schema"); process.exit(1); }
s = s.replace(anchor, "    finalNotes: v.optional(v.string()),\n" + anchor);
writeFileSync(p, s);
console.log("convex/schema.ts patched");
EOF
bun /tmp/patch-schema.mjs

cat > /tmp/patch-reports.mjs <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/matchReports.ts";
let s = readFileSync(p, "utf8");
if (!s.includes("finalNotes")) {
  s = s.replace("  matchStartedAt: v.union(v.number(), v.null()),",
                "  finalNotes: v.string(),\n  matchStartedAt: v.union(v.number(), v.null()),");
  s = s.replace("      matchStartedAt: args.matchStartedAt,",
                "      finalNotes: args.finalNotes,\n      matchStartedAt: args.matchStartedAt,");
  writeFileSync(p, s);
  console.log("convex/matchReports.ts patched");
} else { console.log("matchReports already patched"); }
EOF
bun /tmp/patch-reports.mjs
rm -f /tmp/patch-schema.mjs /tmp/patch-reports.mjs

say "Stepper: -10 -5 -1 +1 +5 +10"
cat > src/components/scouting/stepper.tsx <<'EOF'
import { Button } from "@/components/ui/button";

const DOWN = [-10, -5, -1] as const;
const UP = [1, 5, 10] as const;

/**
 * Large counter, ordered so the buttons read as a number line: the six taps
 * run -10 -5 -1 +1 +5 +10 left to right. No keyboard entry — this is tapped
 * one-handed while watching a match.
 */
export function Stepper({
  label,
  value,
  onChange,
  min = 0,
}: {
  label: string;
  value: number;
  onChange: (next: number) => void;
  min?: number;
}) {
  const bump = (delta: number) => onChange(Math.max(min, value + delta));

  return (
    <div className="space-y-3">
      <div className="flex items-baseline justify-between">
        <span className="text-sm font-medium">{label}</span>
        <span className="text-3xl font-semibold tabular-nums">{value}</span>
      </div>
      <div className="grid grid-cols-6 gap-2">
        {DOWN.map((step) => (
          <Button
            key={step}
            variant="outline"
            className="h-14 text-base"
            disabled={value <= min}
            onClick={() => bump(step)}
            aria-label={`${step} ${label}`}
          >
            {step}
          </Button>
        ))}
        {UP.map((step) => (
          <Button
            key={step}
            variant="secondary"
            className="h-14 text-base"
            onClick={() => bump(step)}
            aria-label={`Add ${step} to ${label}`}
          >
            +{step}
          </Button>
        ))}
      </div>
    </div>
  );
}
EOF

say "Ratings as sliders"
cat > src/components/scouting/rating-scale.tsx <<'EOF'
import { Slider } from "@/components/ui/slider";

/**
 * `value` stays null until the scout touches it, so "not rated" is
 * distinguishable from "rated as the default" — which matters when ratings
 * are required before submit.
 */
export function RatingScale({
  label,
  value,
  onChange,
  min = 1,
  max = 10,
  step = 1,
  unit = "",
}: {
  label: string;
  value: number | null;
  onChange: (next: number) => void;
  min?: number;
  max?: number;
  step?: number;
  unit?: string;
}) {
  const fallback = Math.round((min + max) / 2);

  return (
    <div className="space-y-3">
      <div className="flex items-baseline justify-between">
        <span className="text-sm font-medium">{label}</span>
        <span className="text-2xl font-semibold tabular-nums">
          {value === null ? (
            <span className="text-muted-foreground text-base font-normal">
              Not set
            </span>
          ) : (
            `${value}${unit}`
          )}
        </span>
      </div>
      <Slider
        min={min}
        max={max}
        step={step}
        value={[value ?? fallback]}
        onValueChange={(next: number | number[]) =>
          onChange(Array.isArray(next) ? (next[0] ?? fallback) : next)
        }
        className="py-3"
      />
      <div className="text-muted-foreground flex justify-between text-xs">
        <span>{min}{unit}</span>
        <span>{max}{unit}</span>
      </div>
    </div>
  );
}
EOF

say "Match form"
cat > /tmp/patch-form.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/scout/form.tsx";
let s = readFileSync(p, "utf8");

// --- final notes state ---
s = s.replace('  const [endNotes, setEndNotes] = useState("");',
  '  const [endNotes, setEndNotes] = useState("");\n  const [finalNotes, setFinalNotes] = useState("");');

// --- send it ---
s = s.replace("        matchStartedAt: startedAt,",
  "        finalNotes,\n        matchStartedAt: startedAt,");

// --- required-field gate ---
s = s.replace("  const hubStateSource =",
`  const missing: string[] = [];
  if (start === null) missing.push("start position");
  if (driver === null) missing.push("driver rating");
  if (defense === null) missing.push("defense rating");
  if (accuracy === null) missing.push("shooting accuracy");
  if (autoWinner === null) missing.push("auto winner");
  if (finalNotes.trim() === "") missing.push("final notes");

  const hubStateSource =`);

// --- accuracy becomes a percentage ---
s = s.replace(
  '          <RatingScale label="Shooting accuracy" value={accuracy} onChange={setAccuracy} />',
  `          <RatingScale
            label="Shooting accuracy"
            value={accuracy}
            onChange={setAccuracy}
            min={0}
            max={100}
            step={5}
            unit="%"
          />`);

// --- lift the auto-winner card out of its standalone position ---
const winnerCard = `      <Card>
        <CardHeader><CardTitle>Which alliance won auto?</CardTitle></CardHeader>
        <CardContent className="space-y-4">
          <p className="text-muted-foreground text-sm">
            The alliance scoring more auto fuel has its hub inactive first. This
            decides which of your teleop fuel actually scored points.
          </p>
          <SegmentedChoice
            label="More auto fuel"
            options={[
              { value: "red", label: "Red" },
              { value: "blue", label: "Blue" },
            ]}
            value={autoWinner}
            onChange={setAutoWinner}
          />
          {autoWinner !== null ? (
            <div className="flex gap-4 text-sm">
              <span>Counted: <strong className="tabular-nums">{counted}</strong></span>
              <span className="text-muted-foreground">
                Dead hub: <strong className="tabular-nums">{dead}</strong>
              </span>
            </div>
          ) : null}
        </CardContent>
      </Card>

`;
if (!s.includes(winnerCard)) { console.error("could not find the auto winner card"); process.exit(1); }
s = s.replace(winnerCard, "");

// --- drop it into the Auto tab, after the auto scoring card ---
const autoTabEnd = `              <Textarea placeholder="Auto notes" rows={2}
                value={autoNotes} onChange={(e) => setAutoNotes(e.target.value)} />
            </CardContent>
          </Card>
        </TabsContent>`;
const autoTabNew = `              <Textarea placeholder="Auto notes" rows={2}
                value={autoNotes} onChange={(e) => setAutoNotes(e.target.value)} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>Which alliance won auto?</CardTitle></CardHeader>
            <CardContent className="space-y-4">
              <p className="text-muted-foreground text-sm">
                The alliance scoring more auto fuel has its hub inactive first,
                which decides how much of the teleop fuel actually scored.
              </p>
              <SegmentedChoice
                label="More auto fuel"
                options={[
                  { value: "red", label: "Red" },
                  { value: "blue", label: "Blue" },
                ]}
                value={autoWinner}
                onChange={setAutoWinner}
              />
              {autoWinner !== null ? (
                <div className="flex gap-4 text-sm">
                  <span>Counted: <strong className="tabular-nums">{counted}</strong></span>
                  <span className="text-muted-foreground">
                    Dead hub: <strong className="tabular-nums">{dead}</strong>
                  </span>
                </div>
              ) : null}
            </CardContent>
          </Card>
        </TabsContent>`;
if (!s.includes(autoTabEnd)) { console.error("could not find the end of the Auto tab"); process.exit(1); }
s = s.replace(autoTabEnd, autoTabNew);

// --- final notes in the Endgame tab ---
const endTab = `              <Textarea placeholder="Endgame notes" rows={2}
                value={endNotes} onChange={(e) => setEndNotes(e.target.value)} />
            </CardContent>
          </Card>
        </TabsContent>`;
const endTabNew = `              <Textarea placeholder="Endgame notes" rows={2}
                value={endNotes} onChange={(e) => setEndNotes(e.target.value)} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>Final notes</CardTitle></CardHeader>
            <CardContent className="space-y-2">
              <p className="text-muted-foreground text-sm">
                Anything a strategy lead should know when they read this report
                during alliance selection.
              </p>
              <Textarea
                placeholder="Overall impression of this robot"
                rows={4}
                value={finalNotes}
                onChange={(e) => setFinalNotes(e.target.value)}
              />
            </CardContent>
          </Card>
        </TabsContent>`;
if (!s.includes(endTab)) { console.error("could not find the end of the Endgame tab"); process.exit(1); }
s = s.replace(endTab, endTabNew);

// --- submit button: block on missing fields, say which ---
const oldSubmit = `      <Button
        className="h-14 w-full text-base"
        disabled={saving || (suspicious && !override)}
        onClick={() => void save()}
      >
        {saving ? <LoaderCircle className="size-4 animate-spin" /> : null}
        Submit report
      </Button>`;
const newSubmit = `      {missing.length > 0 ? (
        <p className="text-muted-foreground rounded-lg border border-dashed p-3 text-sm">
          Still needed: {missing.join(", ")}.
        </p>
      ) : null}

      <Button
        className="h-14 w-full text-base"
        disabled={saving || missing.length > 0 || (suspicious && !override)}
        onClick={() => void save()}
      >
        {saving ? <LoaderCircle className="size-4 animate-spin" /> : null}
        Submit report
      </Button>`;
if (!s.includes(oldSubmit)) { console.error("could not find the submit button"); process.exit(1); }
s = s.replace(oldSubmit, newSubmit);

writeFileSync(p, s);
console.log("src/routes/scout/form.tsx patched");
MJS
bun /tmp/patch-form.mjs
rm -f /tmp/patch-form.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Patched. Note the schema change: matchReports.finalNotes.
  Convex will push it on the next `bunx convex dev` cycle.

DONE
