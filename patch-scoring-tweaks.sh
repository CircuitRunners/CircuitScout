#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-scoring-tweaks.sh
#   1. Auto fouls step by -15 -5 +5 +15
#   2. Custom amount box with plus/minus, left of the readout
#   3. Stealing added to endgame
#
# SCHEMA CHANGE: endgame.stoleFuel (optional).
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/components/scouting/stepper.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Stepper: custom steps and a typed amount"
cat > src/components/scouting/stepper.tsx <<'EOF'
import { useState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

const DOWN = [-10, -5, -1] as const;
const UP = [1, 5, 10] as const;

/**
 * Large counter. The fixed buttons read as a number line, and the typed box
 * beside the readout covers the amounts the buttons cannot reach in one tap —
 * a scout who saw eleven fuel go in should not have to tap four times.
 */
export function Stepper({
  label,
  value,
  onChange,
  min = 0,
  downSteps = DOWN,
  upSteps = UP,
}: {
  label: string;
  value: number;
  onChange: (next: number) => void;
  min?: number;
  downSteps?: ReadonlyArray<number>;
  upSteps?: ReadonlyArray<number>;
}) {
  const [custom, setCustom] = useState("");
  const bump = (delta: number) => onChange(Math.max(min, value + delta));

  const amount = Number.parseInt(custom, 10);
  const usable = Number.isFinite(amount) && amount !== 0;

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-sm font-medium">{label}</span>
        <div className="flex items-center gap-1.5">
          <Input
            className="h-9 w-16 text-center"
            inputMode="numeric"
            placeholder="±"
            aria-label={`Custom amount for ${label}`}
            value={custom}
            onChange={(e) => setCustom(e.target.value)}
          />
          <Button variant="outline" size="icon" className="h-9 w-9"
            disabled={!usable} aria-label={`Subtract ${custom || "custom"} from ${label}`}
            onClick={() => bump(-Math.abs(amount))}>
            −
          </Button>
          <Button variant="outline" size="icon" className="h-9 w-9"
            disabled={!usable} aria-label={`Add ${custom || "custom"} to ${label}`}
            onClick={() => bump(Math.abs(amount))}>
            +
          </Button>
          <span className="ml-1 w-12 text-right text-3xl font-semibold tabular-nums">
            {value}
          </span>
        </div>
      </div>
      <div
        className="grid gap-2"
        style={{ gridTemplateColumns: `repeat(${downSteps.length + upSteps.length}, minmax(0, 1fr))` }}
      >
        {downSteps.map((step) => (
          <Button key={step} variant="outline" className="h-14 text-base"
            disabled={value <= min}
            aria-label={`${step} ${label}`}
            onClick={() => bump(step)}>
            {step}
          </Button>
        ))}
        {upSteps.map((step) => (
          <Button key={step} variant="secondary" className="h-14 text-base"
            aria-label={`Add ${step} to ${label}`}
            onClick={() => bump(step)}>
            +{step}
          </Button>
        ))}
      </div>
    </div>
  );
}
EOF

say "Schema and validators: endgame stealing"
cat > /tmp/t1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

let s = readFileSync("convex/schema.ts", "utf8");
if (!s.includes("endgame: v.object({\n      climb")) {
  // nothing
}
if (!/endgame: v\.object\(\{[\s\S]{0,400}?stoleFuel/.test(s)) {
  const anchor = `    endgame: v.object({
      climb: v.union(v.literal("none"), v.literal("low"),
                     v.literal("mid"), v.literal("high")),
      fuel: v.number(),`;
  if (!s.includes(anchor)) fail("could not find the endgame object in schema");
  s = s.replace(anchor, `${anchor}
      stoleFuel: v.optional(v.number()),`);
  writeFileSync("convex/schema.ts", s);
  console.log("convex/schema.ts patched");
}

let r = readFileSync("convex/matchReports.ts", "utf8");
if (!/endgame: v\.object\(\{[\s\S]{0,400}?stoleFuel/.test(r)) {
  const anchor = `  endgame: v.object({
    climb: v.union(v.literal("none"), v.literal("low"),
                   v.literal("mid"), v.literal("high")),
    fuel: v.number(),`;
  if (!r.includes(anchor)) fail("could not find the endgame object in matchReports");
  r = r.replace(anchor, `${anchor}
    stoleFuel: v.number(),`);
  writeFileSync("convex/matchReports.ts", r);
  console.log("convex/matchReports.ts patched");
}
MJS
bun /tmp/t1.mjs

say "Match form"
cat > /tmp/t2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/scout/form.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("endStole")) { console.log("already patched"); process.exit(0); }

// fouls step in foul-sized amounts
const foulStepper = `<Stepper label="Fouls" value={autoFouls} onChange={setAutoFouls} />`;
if (!s.includes(foulStepper)) fail("could not find the fouls stepper");
s = s.replace(foulStepper,
  `<Stepper label="Fouls" value={autoFouls} onChange={setAutoFouls}\n                downSteps={[-15, -5]} upSteps={[5, 15]} />`);

// endgame stealing
s = s.replace("  const [endNotes, setEndNotes] = useState(\"\");",
              "  const [endStole, setEndStole] = useState(0);\n  const [endNotes, setEndNotes] = useState(\"\");");
s = s.replace("          passedFullField: ePassedFull,\n          notes: endNotes,",
              "          passedFullField: ePassedFull,\n          stoleFuel: endStole,\n          notes: endNotes,");
s = s.replace("    setEPassedFull(editing.endgame.passedFullField);",
              "    setEPassedFull(editing.endgame.passedFullField);\n    setEndStole(editing.endgame.stoleFuel ?? 0);");

const endAnchor = `              <Stepper label="Passed full field"
                value={ePassedFull} onChange={setEPassedFull} />`;
if (!s.includes(endAnchor)) fail("could not find the endgame passed-full-field stepper");
s = s.replace(endAnchor, `${endAnchor}
              <Stepper label="Stole fuel" value={endStole} onChange={setEndStole} />`);

writeFileSync(p, s);
console.log("src/routes/scout/form.tsx patched");
MJS
bun /tmp/t2.mjs
rm -f /tmp/t1.mjs /tmp/t2.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
