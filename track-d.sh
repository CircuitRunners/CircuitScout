#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# track-d.sh — Track D: interactive field map for auto pathing.
#
# The map is an INPUT SKIN over the same AutoPath the button version produces.
# Both are kept: the buttons are the fallback when the map is awkward, and a
# per-person preference decides which one opens.
#
# Owns src/components/field-map/*. Patches the Auto tab of the match form and
# adds one preference to the UI store. No schema change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/scout/form.tsx ]] || { echo "ERROR: run track-c.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
mkdir -p src/components/field-map

say "Field geometry"
cat > src/components/field-map/geometry.ts <<'EOF'
import type { Lane, StartPosition } from "@/lib/types";

/**
 * A schematic, not a scale drawing. It only has to be unambiguous at arm's
 * length on a phone during a 20-second auto.
 *
 * Always drawn from the scouted alliance's DRIVER perspective: their zone at
 * the bottom, looking up the field. Screen-left is therefore drivers' left for
 * both alliances, which is what makes the Lane names mean one thing.
 */
export const VIEW = { width: 360, height: 260 } as const;

export const WALL_Y = 150;
export const START_LINE_Y = 222;

/** x positions along the alliance-zone wall, drivers' left to right. */
export const LANE_X: Record<Lane, number> = {
  "trench-left": 40,
  "bump-left": 115,
  "bump-right": 245,
  "trench-right": 320,
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
EOF

say "Field map"
cat > src/components/field-map/field-map.tsx <<'EOF'
import type { AutoCycle, Lane, StartPosition } from "@/lib/types";
import {
  HUB_X, LANE_LABEL, LANE_ORDER, LANE_X, START_LINE_Y, START_ORDER,
  VIEW, WALL_Y, startX,
} from "./geometry";

type Mode =
  | { kind: "start" }
  | { kind: "outbound" }
  | { kind: "inbound"; outbound: Lane };

export function FieldMap({
  alliance,
  start,
  cycles,
  mode,
  onPickStart,
  onPickLane,
}: {
  alliance: "red" | "blue";
  start: StartPosition | null;
  cycles: AutoCycle[];
  mode: Mode;
  onPickStart: (position: StartPosition) => void;
  onPickLane: (lane: Lane) => void;
}) {
  const zoneClass =
    alliance === "red"
      ? "fill-red-500/10 stroke-red-500/40"
      : "fill-blue-500/10 stroke-blue-500/40";
  const accent =
    alliance === "red" ? "stroke-red-500" : "stroke-blue-500";

  const pickingLane = mode.kind !== "start";

  return (
    <svg
      viewBox={`0 0 ${VIEW.width} ${VIEW.height}`}
      className="w-full touch-manipulation select-none"
      role="img"
      aria-label="Field map. Tap a lane or a start position."
    >
      {/* neutral zone */}
      <rect x="4" y="4" width={VIEW.width - 8} height={WALL_Y - 4}
        className="fill-muted/40 stroke-border" strokeWidth="1.5" rx="6" />
      <text x={VIEW.width / 2} y="24" textAnchor="middle"
        className="fill-muted-foreground text-[10px]">
        Neutral zone
      </text>
      {/* the fuel that the hub vents into the neutral zone */}
      {[0, 1, 2, 3].map((row) =>
        [0, 1, 2, 3, 4, 5].map((col) => (
          <circle key={`${row}-${col}`}
            cx={VIEW.width / 2 - 40 + col * 16} cy={54 + row * 14} r="4"
            className="fill-yellow-400/70" />
        )),
      )}

      {/* alliance zone */}
      <rect x="4" y={WALL_Y} width={VIEW.width - 8} height={VIEW.height - WALL_Y - 4}
        className={zoneClass} strokeWidth="1.5" rx="6" />

      {/* the wall, drawn as segments so the openings read as gaps */}
      {(() => {
        const stops = [4, ...LANE_ORDER.map((l) => LANE_X[l]), HUB_X, VIEW.width - 4]
          .sort((a, b) => a - b);
        const gaps = new Set([...LANE_ORDER.map((l) => LANE_X[l]), HUB_X]);
        const segments: { x1: number; x2: number }[] = [];
        for (let i = 0; i < stops.length - 1; i++) {
          const from = stops[i] ?? 0;
          const to = stops[i + 1] ?? 0;
          segments.push({
            x1: gaps.has(from) ? from + 22 : from,
            x2: gaps.has(to) ? to - 22 : to,
          });
        }
        return segments.map((seg, i) =>
          seg.x2 > seg.x1 ? (
            <line key={i} x1={seg.x1} y1={WALL_Y} x2={seg.x2} y2={WALL_Y}
              className="stroke-border" strokeWidth="3" strokeLinecap="round" />
          ) : null,
        );
      })()}

      {/* completed cycles, offset so overlapping ones stay countable */}
      {cycles.map((cycle, i) => {
        const offset = (i - (cycles.length - 1) / 2) * 5;
        const out = LANE_X[cycle.outbound] + offset;
        const back = LANE_X[cycle.inbound] + offset;
        return (
          <g key={i} className={accent} opacity={0.55}>
            <path d={`M ${out} ${WALL_Y + 24} L ${out} ${WALL_Y - 34}`}
              strokeWidth="2" fill="none" strokeLinecap="round" />
            <path d={`M ${out} ${WALL_Y - 34} L ${back} ${WALL_Y - 34}`}
              strokeWidth="2" fill="none" strokeLinecap="round" />
            <path d={`M ${back} ${WALL_Y - 34} L ${back} ${WALL_Y + 24}`}
              strokeWidth="2" fill="none" strokeLinecap="round" />
            <circle cx={back} cy={WALL_Y + 24} r="7" className="fill-background" />
            <text x={back} y={WALL_Y + 27} textAnchor="middle"
              className="fill-foreground stroke-none text-[9px]">
              {i + 1}
            </text>
          </g>
        );
      })}

      {/* hub */}
      <polygon
        points={`${HUB_X},${WALL_Y - 16} ${HUB_X + 14},${WALL_Y - 8} ${HUB_X + 14},${WALL_Y + 8} ${HUB_X},${WALL_Y + 16} ${HUB_X - 14},${WALL_Y + 8} ${HUB_X - 14},${WALL_Y - 8}`}
        className="fill-foreground/80" />
      <text x={HUB_X} y={WALL_Y + 32} textAnchor="middle"
        className="fill-muted-foreground text-[9px]">Hub</text>

      {/* lane tap targets */}
      {LANE_ORDER.map((lane) => {
        const x = LANE_X[lane];
        const isNext = mode.kind === "inbound" && mode.outbound === lane;
        return (
          <g key={lane}
            onClick={() => pickingLane && onPickLane(lane)}
            className={pickingLane ? "cursor-pointer" : ""}>
            <rect x={x - 22} y={WALL_Y - 22} width="44" height="44" rx="8"
              className={[
                pickingLane ? "fill-primary/15 stroke-primary" : "fill-muted stroke-border",
                isNext ? "stroke-2" : "",
              ].join(" ")}
              strokeWidth={pickingLane ? 2 : 1} />
            <text x={x} y={WALL_Y + 3} textAnchor="middle"
              className="fill-foreground text-[9px]">
              {LANE_LABEL[lane]}
            </text>
          </g>
        );
      })}

      {/* robot starting line */}
      <line x1="16" y1={START_LINE_Y} x2={VIEW.width - 16} y2={START_LINE_Y}
        className={accent} strokeWidth="2" strokeDasharray="4 4" />
      <text x={VIEW.width / 2} y={VIEW.height - 10} textAnchor="middle"
        className="fill-muted-foreground text-[10px]">
        Robot starting line · left and right as the {alliance} drivers see it
      </text>

      {/* start position targets */}
      {START_ORDER.map((position) => {
        const x = startX(position);
        const chosen = start === position;
        return (
          <g key={position}
            onClick={() => mode.kind === "start" && onPickStart(position)}
            className={mode.kind === "start" ? "cursor-pointer" : ""}>
            <circle cx={x} cy={START_LINE_Y} r="13"
              className={[
                chosen ? "fill-primary stroke-primary" : "fill-background stroke-border",
                mode.kind === "start" && !chosen ? "stroke-primary" : "",
              ].join(" ")}
              strokeWidth="2" />
            {chosen ? (
              <circle cx={x} cy={START_LINE_Y} r="5"
                className="fill-primary-foreground" />
            ) : null}
          </g>
        );
      })}
    </svg>
  );
}
EOF

say "Auto path editor"
cat > src/components/field-map/auto-path-editor.tsx <<'EOF'
import { Map, Rows3, Trash2, Undo2 } from "lucide-react";
import { useState } from "react";

import { FieldMap } from "./field-map";
import { LANE_LABEL, START_ORDER, startLabel } from "./geometry";
import { SegmentedChoice } from "@/components/scouting/segmented-choice";
import { Stepper } from "@/components/scouting/stepper";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { AutoCycle, Lane, StartPosition } from "@/lib/types";
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

export function AutoPathEditor({
  alliance,
  start,
  onStartChange,
  cycles,
  onCyclesChange,
  depotPickups,
  onDepotChange,
  outpostPickups,
  onOutpostChange,
}: {
  alliance: "red" | "blue";
  start: StartPosition | null;
  onStartChange: (next: StartPosition) => void;
  cycles: AutoCycle[];
  onCyclesChange: (next: AutoCycle[]) => void;
  depotPickups: number;
  onDepotChange: (next: number) => void;
  outpostPickups: number;
  onOutpostChange: (next: number) => void;
}) {
  const inputMode = useUIStore((s) => s.autoInputMode);
  const setInputMode = useUIStore((s) => s.setAutoInputMode);

  // Two taps per cycle: out, then back. Same count as the buttons, but spatial.
  const [pending, setPending] = useState<Lane | null>(null);

  const mode = start === null
    ? ({ kind: "start" } as const)
    : pending === null
      ? ({ kind: "outbound" } as const)
      : ({ kind: "inbound", outbound: pending } as const);

  const pickLane = (lane: Lane) => {
    if (pending === null) { setPending(lane); return; }
    onCyclesChange([...cycles, { outbound: pending, inbound: lane }]);
    setPending(null);
  };

  const prompt =
    start === null
      ? "Tap where the robot lined up."
      : pending === null
        ? `Tap the lane it went out through. ${cycles.length} cycle${cycles.length === 1 ? "" : "s"} so far.`
        : `Out through ${LANE_LABEL[pending]}. Now tap the lane it came back through.`;

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
                cycles={cycles}
                mode={mode}
                onPickStart={onStartChange}
                onPickLane={pickLane}
              />
              <div className="flex items-center gap-2">
                <p className="text-muted-foreground min-w-0 flex-1 text-sm">{prompt}</p>
                {pending !== null ? (
                  <Button variant="ghost" size="sm" onClick={() => setPending(null)}>
                    <Undo2 className="size-3" /> Cancel
                  </Button>
                ) : null}
              </div>
            </>
          ) : (
            <>
              <SegmentedChoice
                label="Lined up in front of"
                hint={DRIVER_HINT}
                options={START_OPTIONS}
                value={start}
                onChange={onStartChange}
              />
              {cycles.map((cycle, index) => (
                <div key={index} className="space-y-3 rounded-lg border p-3">
                  <div className="flex items-center justify-between">
                    <span className="text-sm font-medium">Cycle {index + 1}</span>
                    <Button variant="ghost" size="icon"
                      aria-label={`Remove cycle ${index + 1}`}
                      onClick={() => onCyclesChange(cycles.filter((_, i) => i !== index))}>
                      <Trash2 className="size-4" />
                    </Button>
                  </div>
                  <SegmentedChoice label="Out through" hint={DRIVER_HINT}
                    options={LANE_OPTIONS} value={cycle.outbound}
                    onChange={(lane) => onCyclesChange(
                      cycles.map((c, i) => (i === index ? { ...c, outbound: lane } : c)))} />
                  <SegmentedChoice label="Back through" hint={DRIVER_HINT}
                    options={LANE_OPTIONS} value={cycle.inbound}
                    onChange={(lane) => onCyclesChange(
                      cycles.map((c, i) => (i === index ? { ...c, inbound: lane } : c)))} />
                </div>
              ))}
              <Button variant="outline" className="h-12 w-full"
                onClick={() => onCyclesChange([...cycles,
                  { outbound: "bump-left", inbound: "bump-left" }])}>
                Add cycle
              </Button>
            </>
          )}

          {/* The cycle list is shared by both modes, so the map has a way to
              undo a mistap without switching. */}
          {cycles.length > 0 && inputMode === "map" ? (
            <div className="space-y-1">
              {cycles.map((cycle, index) => (
                <div key={index}
                  className="flex items-center gap-2 rounded-md border px-3 py-2 text-sm">
                  <span className="text-muted-foreground text-xs tabular-nums">
                    {index + 1}
                  </span>
                  <span className="min-w-0 flex-1 truncate">
                    out {LANE_LABEL[cycle.outbound]}
                    {cycle.outbound.endsWith("left") ? " L" : " R"} · back{" "}
                    {LANE_LABEL[cycle.inbound]}
                    {cycle.inbound.endsWith("left") ? " L" : " R"}
                  </span>
                  <Button variant="ghost" size="icon"
                    aria-label={`Remove cycle ${index + 1}`}
                    onClick={() => onCyclesChange(cycles.filter((_, i) => i !== index))}>
                    <Trash2 className="size-4" />
                  </Button>
                </div>
              ))}
            </div>
          ) : null}
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle>In-zone pickups</CardTitle></CardHeader>
        <CardContent className="space-y-6">
          <Stepper label="Depot" value={depotPickups} onChange={onDepotChange} />
          <Stepper label="Outpost" value={outpostPickups} onChange={onOutpostChange} />
        </CardContent>
      </Card>
    </>
  );
}
EOF

say "UI store: input mode preference"
cat > /tmp/d1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/stores/ui-store.ts";
let s = readFileSync(p, "utf8");
if (s.includes("autoInputMode")) { console.log("already patched"); process.exit(0); }
s = s.replace('  matchFormPeriod: "auto" | "teleop" | "endgame" | "conclusion";',
  '  matchFormPeriod: "auto" | "teleop" | "endgame" | "conclusion";\n  /** Which auto-path input the scout prefers. Buttons are the fallback. */\n  autoInputMode: "map" | "buttons";');
s = s.replace("  setMatchFormPeriod: (period: UIState[\"matchFormPeriod\"]) => void;",
  "  setMatchFormPeriod: (period: UIState[\"matchFormPeriod\"]) => void;\n  setAutoInputMode: (mode: UIState[\"autoInputMode\"]) => void;");
s = s.replace('  matchFormPeriod: "auto",', '  matchFormPeriod: "auto",\n  autoInputMode: "map",');
s = s.replace("  setMatchFormPeriod: (matchFormPeriod) => set({ matchFormPeriod }),",
  "  setMatchFormPeriod: (matchFormPeriod) => set({ matchFormPeriod }),\n  setAutoInputMode: (autoInputMode) => set({ autoInputMode }),");
writeFileSync(p, s);
console.log("src/stores/ui-store.ts patched");
MJS
bun /tmp/d1.mjs

say "Match form: swap in the editor"
cat > /tmp/d2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/scout/form.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("AutoPathEditor")) { console.log("already patched"); process.exit(0); }

const from = s.indexOf('          <Card>\n            <CardHeader><CardTitle>Start position</CardTitle></CardHeader>');
const to = s.indexOf('          <Card>\n            <CardHeader><CardTitle>Auto scoring</CardTitle></CardHeader>');
if (from === -1 || to === -1 || to < from) fail("could not find the Auto tab cards");

s = s.slice(0, from) + `          <AutoPathEditor
            alliance={data.alliance === "red" ? "red" : "blue"}
            start={start}
            onStartChange={setStart}
            cycles={cycles}
            onCyclesChange={setCycles}
            depotPickups={depotPickups}
            onDepotChange={setDepot}
            outpostPickups={outpostPickups}
            onOutpostChange={setOutpost}
          />

` + s.slice(to);

s = s.replace('import { PageShell } from "@/routes/page-shell";',
              'import { PageShell } from "@/routes/page-shell";\nimport { AutoPathEditor } from "@/components/field-map/auto-path-editor";');

// Constants and imports that only the old Auto cards used.
for (const block of [
  /const LANE_OPTIONS[\s\S]*?\];\n\n/,
  /const START_OPTIONS[\s\S]*?\];\n\n/,
  /\/\*\*\n \* Even numbers at the extremes[\s\S]*?\] as const;\n\n/,
]) {
  // BPS_VALUES must survive; only remove the two lane lists.
  if (block.source.includes("Even numbers")) continue;
  s = s.replace(block, "");
}
s = s.replace('const DRIVER_HINT = "left / right as that alliance\'s drivers see it";\n\n', "");

// Lane is no longer referenced directly in the form.
s = s.replace('import type { AutoCycle, ClimbLevel, Lane, StartPosition } from "@/lib/types";',
              'import type { AutoCycle, ClimbLevel, StartPosition } from "@/lib/types";');

if (s.includes("LANE_OPTIONS") || s.includes("DRIVER_HINT")) {
  fail("stale lane constants still referenced — check the Auto tab replacement");
}

writeFileSync(p, s);
console.log("src/routes/scout/form.tsx patched");
MJS
bun /tmp/d2.mjs
rm -f /tmp/d1.mjs /tmp/d2.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Track D written. Open a match form: the Auto tab now opens on the map,
  with a Buttons toggle in the card header.

DONE
