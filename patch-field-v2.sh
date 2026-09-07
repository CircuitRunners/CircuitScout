#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-field-v2.sh
#   1. Neutral zone cropped; alliance zone unchanged.
#   2. Opponent side removed.
#   3. Start positions sit directly under their lane.
#   4. Depot, tower and outpost moved to the back wall.
#   5. The tower is the L1 climb toggle. Climb is a STEP in the ordered path,
#      excluded from the three-cycle cap.
#
# SCHEMA CHANGE: AutoStep gains { kind: "climb" }. auto.climbL1 stays and is
# derived on save, so climbPoints() and every average are untouched.
#
# Blocking rules, enforced in the editor and again in the mutation:
#   - while climbed: nothing else can be added
#   - while mid-cycle (robot in the neutral zone): no climb, depot or outpost
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/components/field-map/field-map.tsx ]] || { echo "ERROR: run track-d.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Types"
cat > /tmp/v1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/lib/types.ts";
let s = readFileSync(p, "utf8");
if (s.includes('"climb"')) { console.log("already patched"); process.exit(0); }
s = s.replace(`export type AutoStep =
  | ({ kind: "neutral" } & AutoCycle)
  | { kind: "depot" }
  | { kind: "outpost" };`,
`export type AutoStep =
  | ({ kind: "neutral" } & AutoCycle)
  | { kind: "depot" }
  | { kind: "outpost" }
  | { kind: "climb" };`);
s = s.replace(`export const STEP_LABEL = {
  neutral: "Neutral zone",
  depot: "Depot",
  outpost: "Outpost",
} as const;`,
`export const STEP_LABEL = {
  neutral: "Neutral zone",
  depot: "Depot",
  outpost: "Outpost",
  climb: "L1 climb",
} as const;`);
writeFileSync(p, s);
console.log("convex/lib/types.ts patched");
MJS
bun /tmp/v1.mjs

say "Schema and guards"
cat > /tmp/v2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

const MISSING = [];
for (const file of ["convex/schema.ts", "convex/matchReports.ts"]) {
  let s = readFileSync(file, "utf8");
  if (s.includes('v.literal("climb")')) { console.log(`${file} already has climb`); continue; }
  const marker = /(\s*)v\.object\(\{ kind: v\.literal\("outpost"\) \}\),/;
  const m = s.match(marker);
  if (!m) { MISSING.push(file); continue; }
  s = s.replace(marker, `${m[0]}${m[1]}v.object({ kind: v.literal("climb") }),`);
  writeFileSync(file, s);
  console.log(`${file} patched`);
}
if (MISSING.length) {
  console.log("  WARNING: could not add the climb literal to: " + MISSING.join(", "));
  console.log("  Add this line next to the outpost literal in each:");
  console.log('    v.object({ kind: v.literal("climb") }),');
}

let r = readFileSync("convex/matchReports.ts", "utf8");
if (!r.includes("Nothing can follow an L1 climb")) {
  const climbGuard = `
    // A robot on the tower is not doing anything else, so a climb must be the
    // last thing in the path and there can only be one.
    const climbs = args.auto.path.steps.filter((s) => s.kind === "climb");
    if (climbs.length > 1) throw new Error("Only one L1 climb per match.");
    if (climbs.length === 1 && args.auto.path.steps.at(-1)?.kind !== "climb") {
      throw new Error("Nothing can follow an L1 climb.");
    }`;
  const marker = /throw new Error\("Only the final step can be exit-only\."\);\n(\s*)\}/g;
  if (marker.test(r)) {
    r = r.replace(marker, (m) => m + climbGuard);
    writeFileSync("convex/matchReports.ts", r);
    console.log("convex/matchReports.ts guards patched");
  } else {
    console.log("  WARNING: exit-only guard not found — climb guard NOT added.");
    console.log("  The schema and UI are still correct; add the guard by hand if you want it.");
  }
}
MJS
bun /tmp/v2.mjs

say "Geometry"
cat > src/components/field-map/geometry.ts <<'EOF'
import type { Lane, StartPosition } from "@/lib/types";

/**
 * Drawn ROTATED from the real field: the scouted alliance at the bottom,
 * looking up. A phone is portrait, and rotating is what makes drivers' left and
 * right run left and right on screen. Only our own half is drawn; the opponent
 * side told a scout nothing and cost half the canvas.
 */
export const VIEW = { width: 360, height: 306 } as const;

export const CARPET = { x: 6, y: 8, w: 348, h: 280 } as const;

export const WALL_Y = 118;
export const START_LINE_Y = 170;
export const BACK_WALL_Y = 264;
export const STATION_Y = 272;

/** x positions along the alliance-zone wall, drivers' left to right. */
export const LANE_X: Record<Lane, number> = {
  "trench-left": 42,
  "bump-left": 114,
  "bump-right": 246,
  "trench-right": 318,
};

export const HUB_X = 180;

export const LANE_ORDER: ReadonlyArray<Lane> = [
  "trench-left", "bump-left", "bump-right", "trench-right",
];

export const LANE_LABEL: Record<Lane, string> = {
  "trench-left": "Trench",
  "bump-left": "Bump",
  "bump-right": "Bump",
  "trench-right": "Trench",
};

export const START_ORDER: ReadonlyArray<StartPosition> = [
  "trench-left", "bump-left", "hub", "bump-right", "trench-right",
];

export function startX(position: StartPosition): number {
  return position === "hub" ? HUB_X : LANE_X[position];
}

export function startLabel(position: StartPosition): string {
  return position === "hub" ? "Hub" : LANE_LABEL[position];
}

/** Back-wall furniture, where it sits on the real field. */
export const DEPOT = { x: 62, y: 232, w: 66, h: 30 } as const;
export const TOWER = { x: 180, y: 232, w: 88, h: 30 } as const;
export const OUTPOST = { x: 298, y: 232, w: 66, h: 30 } as const;
EOF

say "Field map"
cat > src/components/field-map/field-map.tsx <<'EOF'
import type { AutoCycle, Lane, StartPosition } from "@/lib/types";
import {
  BACK_WALL_Y, CARPET, DEPOT, HUB_X, LANE_LABEL, LANE_ORDER, LANE_X, OUTPOST,
  START_LINE_Y, START_ORDER, STATION_Y, TOWER, VIEW, WALL_Y, startX,
} from "./geometry";

type Mode =
  | { kind: "start" }
  | { kind: "outbound" }
  | { kind: "inbound"; outbound: Lane }
  | { kind: "full" };

function Fuel({ x, y, cols, rows, r = 4.5, gap = 15 }: {
  x: number; y: number; cols: number; rows: number; r?: number; gap?: number;
}) {
  const dots = [];
  for (let row = 0; row < rows; row++) {
    for (let col = 0; col < cols; col++) {
      dots.push(
        <circle key={`${row}-${col}`}
          cx={x - ((cols - 1) * gap) / 2 + col * gap}
          cy={y - ((rows - 1) * gap) / 2 + row * gap}
          r={r} className="fill-yellow-400/80" />,
      );
    }
  }
  return <g>{dots}</g>;
}

export function FieldMap({
  alliance,
  start,
  cycles,
  mode,
  climbed,
  canPickPickup,
  onPickStart,
  onPickLane,
  onPickPickup,
  onToggleClimb,
}: {
  alliance: "red" | "blue";
  start: StartPosition | null;
  cycles: AutoCycle[];
  mode: Mode;
  climbed: boolean;
  canPickPickup: boolean;
  onPickStart: (position: StartPosition) => void;
  onPickLane: (lane: Lane) => void;
  onPickPickup: (kind: "depot" | "outpost") => void;
  onToggleClimb: () => void;
}) {
  const ours = alliance === "red" ? "text-red-500" : "text-blue-500";
  const pickingLane = mode.kind === "outbound" || mode.kind === "inbound";

  return (
    <svg
      viewBox={`0 0 ${VIEW.width} ${VIEW.height}`}
      className="bg-background w-full touch-manipulation select-none rounded-lg"
      role="img"
      aria-label="Field map. Tap a lane, the depot, the outpost, the tower, or a start position."
    >
      <rect x={CARPET.x} y={CARPET.y} width={CARPET.w} height={CARPET.h}
        rx="5" className="fill-muted/40 stroke-border" strokeWidth="1.5" />

      <Fuel x={HUB_X} y={62} cols={7} rows={3} />
      <text x={CARPET.x + CARPET.w - 6} y={24} textAnchor="end"
        className="fill-muted-foreground text-[9px]">Neutral zone</text>

      {/* alliance zone */}
      <rect x={CARPET.x} y={WALL_Y} width={CARPET.w} height={CARPET.y + CARPET.h - WALL_Y}
        className={`${ours} fill-current/10`} />

      {/* the wall, drawn as segments so the five openings read as gaps */}
      {(() => {
        const gaps = [...LANE_ORDER.map((l) => LANE_X[l]), HUB_X].sort((a, b) => a - b);
        const stops = [CARPET.x, ...gaps, CARPET.x + CARPET.w];
        const out = [];
        for (let i = 0; i < stops.length - 1; i++) {
          const from = stops[i] ?? 0;
          const to = stops[i + 1] ?? 0;
          const x1 = gaps.includes(from) ? from + 30 : from;
          const x2 = gaps.includes(to) ? to - 30 : to;
          if (x2 > x1) {
            out.push(<line key={i} x1={x1} y1={WALL_Y} x2={x2} y2={WALL_Y}
              className={`${ours} stroke-current`} strokeWidth="4" strokeLinecap="round" />);
          }
        }
        return out;
      })()}

      {/* completed neutral-zone trips */}
      {cycles.map((cycle, i) => {
        const offset = (i - (cycles.length - 1) / 2) * 5;
        const out = LANE_X[cycle.outbound] + offset;
        const inbound = cycle.inbound;
        const exitOnly = inbound === null;
        const back = inbound === null ? out : LANE_X[inbound] + offset;
        const apex = 74;
        return (
          <g key={i} className={`${ours} stroke-current`} opacity={0.7}>
            <path d={`M ${out} ${WALL_Y - 4} L ${out} ${apex}`}
              strokeWidth="2.5" fill="none" strokeLinecap="round" />
            {exitOnly ? (
              <path d={`M ${out - 5} ${apex + 9} L ${out} ${apex} L ${out + 5} ${apex + 9}`}
                strokeWidth="2.5" fill="none" strokeLinecap="round" />
            ) : (
              <>
                <path d={`M ${out} ${apex} L ${back} ${apex}`}
                  strokeWidth="2.5" fill="none" strokeLinecap="round" />
                <path d={`M ${back} ${apex} L ${back} ${WALL_Y - 4}`}
                  strokeWidth="2.5" fill="none" strokeLinecap="round" />
              </>
            )}
            <circle cx={exitOnly ? out : back} cy={apex - 11} r="7.5"
              className="fill-background stroke-current" strokeWidth="1.5" />
            <text x={exitOnly ? out : back} y={apex - 8} textAnchor="middle"
              className="fill-foreground stroke-none text-[9px]">{i + 1}</text>
          </g>
        );
      })}

      <polygon
        points={`${HUB_X},${WALL_Y - 14} ${HUB_X + 12},${WALL_Y - 7} ${HUB_X + 12},${WALL_Y + 7} ${HUB_X},${WALL_Y + 14} ${HUB_X - 12},${WALL_Y + 7} ${HUB_X - 12},${WALL_Y - 7}`}
        className="fill-foreground/80" />
      <text x={HUB_X} y={WALL_Y + 27} textAnchor="middle"
        className="fill-muted-foreground text-[9px]">Hub</text>

      {/* lane tap targets */}
      {LANE_ORDER.map((lane) => {
        const x = LANE_X[lane];
        const armed = mode.kind === "inbound" && mode.outbound === lane;
        return (
          <g key={lane}
            onClick={() => pickingLane && onPickLane(lane)}
            className={pickingLane ? "cursor-pointer" : ""}>
            <rect x={x - 29} y={WALL_Y - 20} width="58" height="40" rx="7"
              className={pickingLane
                ? "fill-primary/15 stroke-primary"
                : "fill-muted stroke-border"}
              strokeWidth={armed ? 2.5 : pickingLane ? 2 : 1} />
            <text x={x} y={WALL_Y + 3} textAnchor="middle"
              className="fill-foreground text-[9px]">{LANE_LABEL[lane]}</text>
          </g>
        );
      })}

      {/* starting line, directly under the openings */}
      <line x1={CARPET.x + 10} y1={START_LINE_Y} x2={CARPET.x + CARPET.w - 10}
        y2={START_LINE_Y} className={`${ours} stroke-current`}
        strokeWidth="2" strokeDasharray="5 4" />
      {START_ORDER.map((position) => {
        const x = startX(position);
        const chosen = start === position;
        return (
          <g key={position} onClick={() => onPickStart(position)} className="cursor-pointer">
            <circle cx={x} cy={START_LINE_Y} r="14"
              className={chosen
                ? "fill-primary stroke-primary"
                : "fill-background stroke-primary/60"}
              strokeWidth="2" />
            {chosen ? (
              <circle cx={x} cy={START_LINE_Y} r="5.5" className="fill-primary-foreground" />
            ) : null}
          </g>
        );
      })}

      {/* back wall furniture */}
      {([["depot", DEPOT], ["outpost", OUTPOST]] as const).map(([kind, box]) => (
        <g key={kind}
          onClick={() => canPickPickup && onPickPickup(kind)}
          className={canPickPickup ? "cursor-pointer" : ""}>
          <rect x={box.x - box.w / 2} y={box.y - box.h / 2}
            width={box.w} height={box.h} rx="4"
            className={canPickPickup
              ? `${ours} fill-current/15 stroke-current`
              : "fill-muted stroke-border"}
            strokeWidth="1.5" />
          <Fuel x={box.x} y={box.y} cols={4} rows={2} r={3} gap={9} />
        </g>
      ))}
      <text x={DEPOT.x} y={DEPOT.y + DEPOT.h / 2 + 11} textAnchor="middle"
        className="fill-muted-foreground text-[9px]">Depot</text>
      <text x={OUTPOST.x} y={OUTPOST.y + OUTPOST.h / 2 + 11} textAnchor="middle"
        className="fill-muted-foreground text-[9px]">Outpost</text>

      {/* the tower is the L1 climb toggle */}
      <g onClick={onToggleClimb} className="cursor-pointer">
        <rect x={TOWER.x - TOWER.w / 2} y={TOWER.y - TOWER.h / 2}
          width={TOWER.w} height={TOWER.h} rx="4"
          className={climbed
            ? "fill-primary stroke-primary"
            : "fill-muted stroke-foreground/50"}
          strokeWidth="1.5" />
        {climbed ? null : (
          <path
            d={`M ${TOWER.x - TOWER.w / 2} ${TOWER.y - TOWER.h / 2} L ${TOWER.x + TOWER.w / 2} ${TOWER.y + TOWER.h / 2}
                M ${TOWER.x + TOWER.w / 2} ${TOWER.y - TOWER.h / 2} L ${TOWER.x - TOWER.w / 2} ${TOWER.y + TOWER.h / 2}`}
            className="stroke-foreground/25" strokeWidth="1.5" fill="none" />
        )}
        <text x={TOWER.x} y={TOWER.y + 3} textAnchor="middle"
          className={climbed
            ? "fill-primary-foreground text-[10px]"
            : "fill-foreground text-[10px]"}>
          {climbed ? "L1 climbed" : "L1 climb"}
        </text>
      </g>

      {/* back wall and driver stations */}
      <line x1={CARPET.x + 4} y1={BACK_WALL_Y} x2={CARPET.x + CARPET.w - 4} y2={BACK_WALL_Y}
        className={`${ours} stroke-current`} strokeWidth="3" strokeLinecap="round" />
      {[44, 142, 240].map((x) => (
        <rect key={x} x={x} y={STATION_Y} width="76" height="14" rx="2"
          className={`${ours} fill-current/25 stroke-current`} strokeWidth="1.5" />
      ))}
      <text x={VIEW.width / 2} y={VIEW.height - 3} textAnchor="middle"
        className="fill-muted-foreground text-[9px]">
        {alliance} drivers · left and right as they see it
      </text>
    </svg>
  );
}
EOF

say "Editor"
cat > /tmp/v3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/components/field-map/auto-path-editor.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("toggleClimb")) { console.log("already patched"); process.exit(0); }

s = s.replace(`function describe(step: AutoStep): string {
  if (step.kind === "depot") return "Depot pickup";
  if (step.kind === "outpost") return "Outpost pickup";`,
`function describe(step: AutoStep): string {
  if (step.kind === "depot") return "Depot pickup";
  if (step.kind === "outpost") return "Outpost pickup";
  if (step.kind === "climb") return "Climbed L1";`);

const oldState = `  const neutralCount = steps.filter((s) => s.kind === "neutral").length;
  const last = steps.at(-1);
  const endedOutside = last?.kind === "neutral" && last.inbound === null;

  const cyclesFull = neutralCount >= MAX_AUTO_CYCLES;
  // Nothing follows an exit-only step: auto ended with the robot still out.
  const closed = endedOutside;`;
if (!s.includes(oldState)) fail("could not find the editor state block");
s = s.replace(oldState, `  const neutralCount = steps.filter((s) => s.kind === "neutral").length;
  const last = steps.at(-1);
  const endedOutside = last?.kind === "neutral" && last.inbound === null;
  const climbed = steps.some((s) => s.kind === "climb");

  // The climb is a step, but it is not a cycle — it never counts toward the cap.
  const cyclesFull = neutralCount >= MAX_AUTO_CYCLES;
  // Nothing follows an exit-only step or a climb: in one case the robot never
  // came back, in the other it is on the tower.
  const closed = endedOutside || climbed;
  // Mid-cycle the robot is in the neutral zone, so it cannot be at the depot,
  // the outpost or the tower.
  const inZone = !closed && pending === null;`);

s = s.replace(`  const addPickup = (kind: "depot" | "outpost") => {
    if (closed || pending !== null) return;
    onStepsChange([...steps, { kind }]);
  };`,
`  const addPickup = (kind: "depot" | "outpost") => {
    if (!inZone) return;
    onStepsChange([...steps, { kind }]);
  };

  const toggleClimb = () => {
    if (climbed) {
      onStepsChange(steps.filter((s) => s.kind !== "climb"));
      return;
    }
    if (!inZone) return;
    onStepsChange([...steps, { kind: "climb" }]);
  };`);

s = s.replace(`        : closed
          ? "Auto ended with the robot still out. Remove the last step to change it."`,
`        : climbed
          ? "Climbed L1 — nothing follows a climb. Tap the tower again to undo."
          : endedOutside
            ? "Auto ended with the robot still out. Remove the last step to change it."`);
s = s.replace(`          : cyclesFull
            ? \`\${MAX_AUTO_CYCLES} neutral-zone cycles — the most auto allows. Depot and outpost pickups can still be added.\`
            : \`Tap a lane, the depot or the outpost, in the order it happened. \${neutralCount} of \${MAX_AUTO_CYCLES} cycles.\`;`,
`            : cyclesFull
              ? \`\${MAX_AUTO_CYCLES} neutral-zone cycles — the most auto allows. Pickups and the climb can still be added.\`
              : \`Tap a lane, the depot, the outpost or the tower, in the order it happened. \${neutralCount} of \${MAX_AUTO_CYCLES} cycles.\`;`);

s = s.replace(`                onPickPickup={addPickup}
                canPickPickup={!closed && pending === null}
              />`,
`                onPickPickup={addPickup}
                onToggleClimb={toggleClimb}
                climbed={climbed}
                canPickPickup={inZone}
              />`);

const oldButtons = `              <div className="grid grid-cols-3 gap-2">
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
              </div>`;
if (!s.includes(oldButtons)) fail("could not find the add-step buttons");
s = s.replace(oldButtons, `              <div className="grid grid-cols-4 gap-2">
                <Button variant="outline" className="h-12" disabled={cyclesFull || closed}
                  onClick={() => onStepsChange([...steps,
                    { kind: "neutral", outbound: "bump-left", inbound: "bump-left" }])}>
                  Cycle
                </Button>
                <Button variant="outline" className="h-12" disabled={!inZone}
                  onClick={() => addPickup("depot")}>
                  Depot
                </Button>
                <Button variant="outline" className="h-12" disabled={!inZone}
                  onClick={() => addPickup("outpost")}>
                  Outpost
                </Button>
                <Button variant={climbed ? "default" : "outline"} className="h-12"
                  disabled={!climbed && !inZone}
                  onClick={toggleClimb}>
                  L1 climb
                </Button>
              </div>`);

s = s.replace(`                ) : (
                  <div key={index}
                    className="flex items-center gap-2 rounded-lg border p-3 text-sm">
                    <span className="font-medium">
                      {index + 1}. {step.kind === "depot" ? "Depot" : "Outpost"} pickup
                    </span>`,
`                ) : (
                  <div key={index}
                    className="flex items-center gap-2 rounded-lg border p-3 text-sm">
                    <span className="font-medium">
                      {index + 1}. {describe(step)}
                    </span>`);

writeFileSync(p, s);
console.log("src/components/field-map/auto-path-editor.tsx patched");
MJS
bun /tmp/v3.mjs

say "Match form: climb comes from the path"
cat > /tmp/v4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/scout/form.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes('kind === "climb"')) { console.log("already patched"); process.exit(0); }

s = s.replace("  const [autoClimb, setAutoClimb] = useState(false);\n", "");
s = s.replace(`          climbL1: autoClimb,`,
`          // Derived from the path so the tower toggle is the only source.
          climbL1: steps.some((step) => step.kind === "climb"),`);

const oldCheck = `              <CapabilityCheck
                id="auto-climb" label="Climbed L1 in auto"
                checked={autoClimb} onChange={setAutoClimb}
              />
`;
if (s.includes(oldCheck)) s = s.replace(oldCheck, "");
else console.log("  (auto-climb checkbox not found — already removed?)");

const oldHydrate = "    setSteps(readSteps(editing.auto.path));";
if (s.includes(oldHydrate)) {
  s = s.replace(oldHydrate, `    {
      // Reports written before the climb was a step carry it as a boolean.
      const loaded = readSteps(editing.auto.path);
      if (editing.auto.climbL1 && !loaded.some((step) => step.kind === "climb")) {
        loaded.push({ kind: "climb" });
      }
      setSteps(loaded);
    }`);
}
s = s.replace("    setAutoClimb(editing.auto.climbL1);\n", "");

if (s.includes("autoClimb")) {
  console.log("  WARNING: autoClimb still referenced in form.tsx — remove the");
  console.log("  'Climbed L1 in auto' checkbox and its state by hand.");
}
writeFileSync(p, s);
console.log("src/routes/scout/form.tsx patched");
MJS
bun /tmp/v4.mjs
rm -f /tmp/v1.mjs /tmp/v2.mjs /tmp/v3.mjs /tmp/v4.mjs

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
