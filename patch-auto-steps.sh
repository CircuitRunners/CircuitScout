#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-auto-steps.sh — depot and outpost pickups become ordered steps.
#
# SCHEMA CHANGE: auto.path gains `steps`, an ordered list of neutral-zone
# trips, depot pickups and outpost pickups. The old cycles/depotPickups/
# outpostPickups fields become optional so reports written before this stay
# readable; nothing new writes them.
#
# RESOLVED 8 in PLAN.md said depot and outpost were counters rather than part
# of a cycle. This reverses that: order carries information a count does not.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/components/field-map/auto-path-editor.tsx ]] || { echo "ERROR: run track-d.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Types"
cat > /tmp/s1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/lib/types.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("AutoStep")) { console.log("already patched"); process.exit(0); }

const from = s.indexOf("/**\n * One neutral-zone trip.");
const to = s.indexOf("export const EMPTY_AUTO_PATH");
if (from === -1 || to === -1) fail("could not find the AutoCycle block");

s = s.slice(0, from) + `/**
 * One neutral-zone trip. inbound is null when auto ended with the robot still
 * out there — only the final step may be exit-only.
 */
export type AutoCycle = { outbound: Lane; inbound: Lane | null };

/**
 * The auto path is an ORDERED list. Depot and outpost pickups used to be plain
 * counters; making them steps records when they happened relative to the field
 * crossings, which is what tells you whether a robot preloaded from the depot
 * before leaving or topped up between trips.
 */
export type AutoStep =
  | ({ kind: "neutral" } & AutoCycle)
  | { kind: "depot" }
  | { kind: "outpost" };

export type AutoPath = {
  start: StartPosition | null;
  steps: AutoStep[];
  /** Written before ordering existed. Read only, never written. */
  cycles?: AutoCycle[];
  depotPickups?: number;
  outpostPickups?: number;
};

/** Reads either shape, so old reports still render. */
export function readSteps(path: AutoPath): AutoStep[] {
  if (path.steps && path.steps.length > 0) return path.steps;
  if (!path.cycles) return [];
  return [
    ...path.cycles.map((c) => ({ kind: "neutral" as const, ...c })),
    ...Array.from({ length: path.depotPickups ?? 0 }, () => ({ kind: "depot" as const })),
    ...Array.from({ length: path.outpostPickups ?? 0 }, () => ({ kind: "outpost" as const })),
  ];
}

export const STEP_LABEL = {
  neutral: "Neutral zone",
  depot: "Depot",
  outpost: "Outpost",
} as const;

` + s.slice(to);

s = s.replace(`export const EMPTY_AUTO_PATH: AutoPath = {
  start: null, cycles: [], depotPickups: 0, outpostPickups: 0,
};`,
`export const EMPTY_AUTO_PATH: AutoPath = { start: null, steps: [] };`);

writeFileSync(p, s);
console.log("convex/lib/types.ts patched");
MJS
bun /tmp/s1.mjs

say "Schema and validators"
cat > /tmp/s2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

const build = (lane, ind) => `${ind}steps: v.array(v.union(
${ind}  v.object({ kind: v.literal("neutral"), outbound: ${lane}, inbound: v.union(${lane}, v.null()) }),
${ind}  v.object({ kind: v.literal("depot") }),
${ind}  v.object({ kind: v.literal("outpost") }),
${ind})),`;

// --- schema.ts ---
let s = readFileSync("convex/schema.ts", "utf8");
if (!s.includes('v.literal("depot")')) {
  const old = `  cycles: v.array(v.object({ outbound: lane, inbound: v.union(lane, v.null()) })),
  depotPickups: v.number(),
  outpostPickups: v.number(),`;
  if (!s.includes(old)) fail("could not find the path fields in schema");
  s = s.replace(old, `${build("lane", "  ")}
  // Written before ordering existed. Kept optional so old reports validate.
  cycles: v.optional(v.array(v.object({ outbound: lane, inbound: v.union(lane, v.null()) }))),
  depotPickups: v.optional(v.number()),
  outpostPickups: v.optional(v.number()),`);
  writeFileSync("convex/schema.ts", s);
  console.log("convex/schema.ts patched");
}

// --- matchReports.ts ---
let r = readFileSync("convex/matchReports.ts", "utf8");
if (!r.includes('v.literal("depot")')) {
  const old = `      cycles: v.array(v.object({ outbound: lane, inbound: v.union(lane, v.null()) })),
      depotPickups: v.number(),
      outpostPickups: v.number(),`;
  if (!r.includes(old)) fail("could not find the path fields in matchReports");
  r = r.replace(old, build("lane", "      "));

  const oldGuard = `    if (args.auto.path.cycles.length > MAX_AUTO_CYCLES) {
      throw new Error(\`Autonomous allows at most \${MAX_AUTO_CYCLES} cycles.\`);
    }
    if (args.auto.path.cycles.slice(0, -1).some((c) => c.inbound === null)) {
      throw new Error("Only the final cycle can be exit-only.");
    }`;
  const newGuard = `    const neutral = args.auto.path.steps.filter((s) => s.kind === "neutral");
    if (neutral.length > MAX_AUTO_CYCLES) {
      throw new Error(\`Autonomous allows at most \${MAX_AUTO_CYCLES} neutral-zone cycles.\`);
    }
    const lastStep = args.auto.path.steps.at(-1);
    if (
      args.auto.path.steps.some(
        (s, i) => s.kind === "neutral" && s.inbound === null && s !== lastStep,
      )
    ) {
      throw new Error("Only the final step can be exit-only.");
    }`;
  if (!r.includes(oldGuard)) fail("could not find the cycle guards");
  r = r.split(oldGuard).join(newGuard);
  writeFileSync("convex/matchReports.ts", r);
  console.log("convex/matchReports.ts patched");
}
MJS
bun /tmp/s2.mjs

say "Field map: depot and outpost targets"
cat > /tmp/s3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

// --- geometry ---
let g = readFileSync("src/components/field-map/geometry.ts", "utf8");
if (!g.includes("DEPOT")) {
  g += `
/** In-zone pickup markers. Schematic positions, not surveyed. */
export const DEPOT = { x: 70, y: 185 } as const;
export const OUTPOST = { x: 300, y: 185 } as const;
`;
  writeFileSync("src/components/field-map/geometry.ts", g);
  console.log("geometry.ts patched");
}

// --- field map ---
let m = readFileSync("src/components/field-map/field-map.tsx", "utf8");
if (m.includes("onPickPickup")) { console.log("field-map already patched"); process.exit(0); }

m = m.replace(`import {
  HUB_X, LANE_LABEL, LANE_ORDER, LANE_X, START_LINE_Y, START_ORDER,
  VIEW, WALL_Y, startX,
} from "./geometry";`,
`import {
  DEPOT, HUB_X, LANE_LABEL, LANE_ORDER, LANE_X, OUTPOST, START_LINE_Y,
  START_ORDER, VIEW, WALL_Y, startX,
} from "./geometry";`);

m = m.replace(`  onPickStart: (position: StartPosition) => void;
  onPickLane: (lane: Lane) => void;
}) {`,
`  onPickStart: (position: StartPosition) => void;
  onPickLane: (lane: Lane) => void;
  onPickPickup: (kind: "depot" | "outpost") => void;
  canPickPickup: boolean;
}) {`);

// depot / outpost markers, drawn inside the alliance zone
m = m.replace(`      {/* robot starting line */}`,
`      {/* in-zone pickups */}
      {([["depot", DEPOT], ["outpost", OUTPOST]] as const).map(([kind, pos]) => (
        <g key={kind}
          onClick={() => canPickPickup && onPickPickup(kind)}
          className={canPickPickup ? "cursor-pointer" : ""}>
          <rect x={pos.x - 26} y={pos.y - 14} width="52" height="28" rx="6"
            className={
              canPickPickup
                ? "fill-yellow-400/20 stroke-yellow-500"
                : "fill-muted stroke-border"
            }
            strokeWidth="1.5" />
          <text x={pos.x} y={pos.y + 4} textAnchor="middle"
            className="fill-foreground text-[9px] capitalize">
            {kind}
          </text>
        </g>
      ))}

      {/* robot starting line */}`);

writeFileSync("src/components/field-map/field-map.tsx", m);
console.log("field-map.tsx patched");
MJS
bun /tmp/s3.mjs

say "Editor: ordered step list"
cat > src/components/field-map/auto-path-editor.tsx <<'EOF'
import { LogOut, Map, Rows3, Trash2, Undo2 } from "lucide-react";
import { useState } from "react";

import { FieldMap } from "./field-map";
import { LANE_LABEL, START_ORDER, startLabel } from "./geometry";
import { SegmentedChoice } from "@/components/scouting/segmented-choice";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { MAX_AUTO_CYCLES } from "@/lib/scoring";
import type { AutoStep, Lane, StartPosition } from "@/lib/types";
import { useUIStore } from "@/stores/ui-store";

const LANE_OPTIONS: ReadonlyArray<{ value: Lane; label: string }> = [
  { value: "trench-left", label: "Trench L" },
  { value: "trench-right", label: "Trench R" },
  { value: "bump-left", label: "Bump L" },
  { value: "bump-right", label: "Bump R" },
];

const START_OPTIONS = START_ORDER.map((value) => ({
  value,
  label: value === "hub" ? "Hub" : `${startLabel(value)} ${value.endsWith("left") ? "L" : "R"}`,
}));

const DRIVER_HINT = "left / right as that alliance's drivers see it";

const side = (lane: Lane) => (lane.endsWith("left") ? "L" : "R");

function describe(step: AutoStep): string {
  if (step.kind === "depot") return "Depot pickup";
  if (step.kind === "outpost") return "Outpost pickup";
  return step.inbound === null
    ? `Out ${LANE_LABEL[step.outbound]} ${side(step.outbound)} · did not return`
    : `Out ${LANE_LABEL[step.outbound]} ${side(step.outbound)} · back ${LANE_LABEL[step.inbound]} ${side(step.inbound)}`;
}

export function AutoPathEditor({
  alliance,
  start,
  onStartChange,
  steps,
  onStepsChange,
}: {
  alliance: "red" | "blue";
  start: StartPosition | null;
  onStartChange: (next: StartPosition) => void;
  steps: AutoStep[];
  onStepsChange: (next: AutoStep[]) => void;
}) {
  const inputMode = useUIStore((s) => s.autoInputMode);
  const setInputMode = useUIStore((s) => s.setAutoInputMode);
  const [pending, setPending] = useState<Lane | null>(null);

  const neutralCount = steps.filter((s) => s.kind === "neutral").length;
  const last = steps.at(-1);
  const endedOutside = last?.kind === "neutral" && last.inbound === null;

  const cyclesFull = neutralCount >= MAX_AUTO_CYCLES;
  // Nothing follows an exit-only step: auto ended with the robot still out.
  const closed = endedOutside;

  const mode = start === null
    ? ({ kind: "start" } as const)
    : pending !== null
      ? ({ kind: "inbound", outbound: pending } as const)
      : cyclesFull || closed
        ? ({ kind: "full" } as const)
        : ({ kind: "outbound" } as const);

  const pickLane = (lane: Lane) => {
    if (pending === null) {
      if (cyclesFull || closed) return;
      setPending(lane);
      return;
    }
    onStepsChange([...steps, { kind: "neutral", outbound: pending, inbound: lane }]);
    setPending(null);
  };

  const addPickup = (kind: "depot" | "outpost") => {
    if (closed || pending !== null) return;
    onStepsChange([...steps, { kind }]);
  };

  const prompt =
    start === null
      ? "Tap where the robot lined up."
      : pending !== null
        ? `Out through ${LANE_LABEL[pending]}. Tap the lane it came back through, or mark it as not returning.`
        : closed
          ? "Auto ended with the robot still out. Remove the last step to change it."
          : cyclesFull
            ? `${MAX_AUTO_CYCLES} neutral-zone cycles — the most auto allows. Depot and outpost pickups can still be added.`
            : `Tap a lane, the depot or the outpost, in the order it happened. ${neutralCount} of ${MAX_AUTO_CYCLES} cycles.`;

  return (
    <>
      <Card>
        <CardHeader className="flex-row items-center justify-between space-y-0">
          <CardTitle>Auto path</CardTitle>
          <Button variant="ghost" size="sm"
            onClick={() => setInputMode(inputMode === "map" ? "buttons" : "map")}>
            {inputMode === "map" ? <Rows3 className="size-4" /> : <Map className="size-4" />}
            {inputMode === "map" ? "Buttons" : "Map"}
          </Button>
        </CardHeader>
        <CardContent className="space-y-4">
          {inputMode === "map" ? (
            <>
              <FieldMap
                alliance={alliance}
                start={start}
                cycles={steps.flatMap((s) => (s.kind === "neutral" ? [s] : []))}
                mode={mode}
                onPickStart={onStartChange}
                onPickLane={pickLane}
                onPickPickup={addPickup}
                canPickPickup={!closed && pending === null}
              />
              <div className="flex flex-wrap items-center gap-2">
                <p className="text-muted-foreground min-w-0 flex-1 text-sm">{prompt}</p>
                {pending !== null ? (
                  <>
                    <Button variant="outline" size="sm"
                      onClick={() => {
                        onStepsChange([...steps,
                          { kind: "neutral", outbound: pending, inbound: null }]);
                        setPending(null);
                      }}>
                      <LogOut className="size-3" /> Did not return
                    </Button>
                    <Button variant="ghost" size="sm" onClick={() => setPending(null)}>
                      <Undo2 className="size-3" /> Cancel
                    </Button>
                  </>
                ) : null}
              </div>
            </>
          ) : (
            <>
              <SegmentedChoice label="Lined up in front of" hint={DRIVER_HINT}
                options={START_OPTIONS} value={start} onChange={onStartChange} />

              {steps.map((step, index) =>
                step.kind === "neutral" ? (
                  <div key={index} className="space-y-3 rounded-lg border p-3">
                    <div className="flex items-center justify-between">
                      <span className="text-sm font-medium">
                        {index + 1}. Neutral zone
                      </span>
                      <Button variant="ghost" size="icon"
                        aria-label={`Remove step ${index + 1}`}
                        onClick={() => onStepsChange(steps.filter((_, i) => i !== index))}>
                        <Trash2 className="size-4" />
                      </Button>
                    </div>
                    <SegmentedChoice label="Out through" hint={DRIVER_HINT}
                      options={LANE_OPTIONS} value={step.outbound}
                      onChange={(lane) => onStepsChange(steps.map((s, i) =>
                        i === index && s.kind === "neutral" ? { ...s, outbound: lane } : s))} />
                    <SegmentedChoice
                      label="Back through"
                      hint={DRIVER_HINT}
                      options={
                        index === steps.length - 1
                          ? [...LANE_OPTIONS, { value: "none" as const, label: "Did not return" }]
                          : LANE_OPTIONS
                      }
                      value={step.inbound ?? "none"}
                      onChange={(value) => onStepsChange(steps.map((s, i) =>
                        i === index && s.kind === "neutral"
                          ? { ...s, inbound: value === "none" ? null : (value as Lane) }
                          : s))} />
                  </div>
                ) : (
                  <div key={index}
                    className="flex items-center gap-2 rounded-lg border p-3 text-sm">
                    <span className="font-medium">
                      {index + 1}. {step.kind === "depot" ? "Depot" : "Outpost"} pickup
                    </span>
                    <div className="flex-1" />
                    <Button variant="ghost" size="icon"
                      aria-label={`Remove step ${index + 1}`}
                      onClick={() => onStepsChange(steps.filter((_, i) => i !== index))}>
                      <Trash2 className="size-4" />
                    </Button>
                  </div>
                ),
              )}

              <div className="grid grid-cols-3 gap-2">
                <Button variant="outline" className="h-12" disabled={cyclesFull || closed}
                  onClick={() => onStepsChange([...steps,
                    { kind: "neutral", outbound: "bump-left", inbound: "bump-left" }])}>
                  Cycle
                </Button>
                <Button variant="outline" className="h-12" disabled={closed}
                  onClick={() => addPickup("depot")}>
                  Depot
                </Button>
                <Button variant="outline" className="h-12" disabled={closed}
                  onClick={() => addPickup("outpost")}>
                  Outpost
                </Button>
              </div>
            </>
          )}

          {/* The ordered list is the record; both modes write into it. */}
          {steps.length > 0 && inputMode === "map" ? (
            <div className="space-y-1">
              {steps.map((step, index) => (
                <div key={index}
                  className="flex items-center gap-2 rounded-md border px-3 py-2 text-sm">
                  <span className="text-muted-foreground text-xs tabular-nums">
                    {index + 1}
                  </span>
                  <span className="min-w-0 flex-1 truncate">{describe(step)}</span>
                  <Button variant="ghost" size="icon"
                    aria-label={`Remove step ${index + 1}`}
                    onClick={() => onStepsChange(steps.filter((_, i) => i !== index))}>
                    <Trash2 className="size-4" />
                  </Button>
                </div>
              ))}
            </div>
          ) : null}
        </CardContent>
      </Card>
    </>
  );
}
EOF

say "Match form: steps state"
cat > /tmp/s4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/scout/form.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("const [steps,")) { console.log("already patched"); process.exit(0); }

s = s.replace(`  const [cycles, setCycles] = useState<AutoCycle[]>([]);
  const [depotPickups, setDepot] = useState(0);
  const [outpostPickups, setOutpost] = useState(0);`,
`  const [steps, setSteps] = useState<AutoStep[]>([]);`);

s = s.replace(`import type { AutoCycle, ClimbLevel, StartPosition } from "@/lib/types";`,
`import type { AutoStep, ClimbLevel, StartPosition } from "@/lib/types";`);

const oldEditor = `          <AutoPathEditor
            alliance={data.alliance === "red" ? "red" : "blue"}
            start={start}
            onStartChange={setStart}
            cycles={cycles}
            onCyclesChange={setCycles}
            depotPickups={depotPickups}
            onDepotChange={setDepot}
            outpostPickups={outpostPickups}
            onOutpostChange={setOutpost}
          />`;
if (!s.includes(oldEditor)) fail("could not find the AutoPathEditor call");
s = s.replace(oldEditor, `          <AutoPathEditor
            alliance={data.alliance === "red" ? "red" : "blue"}
            start={start}
            onStartChange={setStart}
            steps={steps}
            onStepsChange={setSteps}
          />`);

s = s.replace(`          path: { start, cycles, depotPickups, outpostPickups },`,
              `          path: { start, steps },`);

// Only present once admin edit mode has been applied; readSteps handles
// reports written before ordering existed.
const oldHydrate = `    setCycles(editing.auto.path.cycles);
    setDepot(editing.auto.path.depotPickups);
    setOutpost(editing.auto.path.outpostPickups);`;
if (s.includes(oldHydrate)) {
  s = s.replace(oldHydrate, `    setSteps(readSteps(editing.auto.path));`);
  s = s.replace(`import type { AutoStep, ClimbLevel, StartPosition } from "@/lib/types";`,
    `import type { AutoStep, ClimbLevel, StartPosition } from "@/lib/types";\nimport { readSteps } from "@/lib/types";`);
} else {
  console.log("  (no edit-mode hydration block — skipped)");
}

writeFileSync(p, s);
console.log("src/routes/scout/form.tsx patched");
MJS
bun /tmp/s4.mjs
rm -f /tmp/s1.mjs /tmp/s2.mjs /tmp/s3.mjs /tmp/s4.mjs

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
