#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-field-art.sh — redraw the field map to resemble the real field.
# Adds tower, depot, outpost, driver stations, opponent side and centre line.
# Themed with semantic tokens so it follows light and dark mode. Same props,
# so auto-path-editor.tsx does not change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/components/field-map/field-map.tsx ]] || { echo "ERROR: run track-d.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Geometry"
cat > src/components/field-map/geometry.ts <<'EOF'
import type { Lane, StartPosition } from "@/lib/types";

/**
 * The real field is landscape with the alliances at either end, so each drive
 * team looks along its long axis. This is drawn ROTATED — scouted alliance at
 * the bottom, looking up the field — for two reasons: a phone is portrait, and
 * rotating is what makes drivers' left and right run left and right on screen.
 * Draw it landscape and the Lane names invert into up and down.
 */
export const VIEW = { width: 360, height: 320 } as const;

export const OPP_STATION_Y = 14;
export const OPP_WALL_Y = 46;
export const CENTER_Y = 112;
export const WALL_Y = 178;
export const START_LINE_Y = 252;
export const STATION_Y = 292;

/** x positions along the alliance-zone wall, drivers' left to right. */
export const LANE_X: Record<Lane, number> = {
  "trench-left": 44,
  "bump-left": 118,
  "bump-right": 242,
  "trench-right": 316,
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

/** Alliance-zone furniture. Schematic positions, not surveyed. */
export const TOWER = { x: 180, y: 212, w: 74, h: 26 } as const;
export const DEPOT = { x: 58, y: 226, w: 46, h: 24 } as const;
export const OUTPOST = { x: 302, y: 226, w: 46, h: 24 } as const;
EOF

say "Field map"
cat > src/components/field-map/field-map.tsx <<'EOF'
import type { AutoCycle, Lane, StartPosition } from "@/lib/types";
import {
  CENTER_Y, DEPOT, HUB_X, LANE_LABEL, LANE_ORDER, LANE_X, OPP_STATION_Y,
  OPP_WALL_Y, OUTPOST, START_LINE_Y, START_ORDER, STATION_Y, TOWER, VIEW,
  WALL_Y, startX,
} from "./geometry";

type Mode =
  | { kind: "start" }
  | { kind: "outbound" }
  | { kind: "inbound"; outbound: Lane }
  | { kind: "full" };

/** Fuel scattered in the neutral zone, vented there by the hubs. */
function FuelField() {
  const dots = [];
  for (let row = 0; row < 5; row++) {
    for (let col = 0; col < 9; col++) {
      dots.push(
        <circle key={`${row}-${col}`}
          cx={VIEW.width / 2 - 64 + col * 16}
          cy={CENTER_Y - 30 + row * 15}
          r="4.5"
          className="fill-yellow-400/80" />,
      );
    }
  }
  return <g>{dots}</g>;
}

function FuelBox({ x, y, w, h }: { x: number; y: number; w: number; h: number }) {
  const dots = [];
  for (let row = 0; row < 2; row++) {
    for (let col = 0; col < 4; col++) {
      dots.push(
        <circle key={`${row}-${col}`}
          cx={x - w / 2 + 9 + col * 9.5}
          cy={y - h / 2 + 8 + row * 9}
          r="3.2" className="fill-yellow-400/80" />,
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
  onPickStart,
  onPickLane,
  onPickPickup,
  canPickPickup,
}: {
  alliance: "red" | "blue";
  start: StartPosition | null;
  cycles: AutoCycle[];
  mode: Mode;
  onPickStart: (position: StartPosition) => void;
  onPickLane: (lane: Lane) => void;
  onPickPickup: (kind: "depot" | "outpost") => void;
  canPickPickup: boolean;
}) {
  const ours = alliance === "red" ? "text-red-500" : "text-blue-500";
  const theirs = alliance === "red" ? "text-blue-500" : "text-red-500";

  const pickingLane = mode.kind === "outbound" || mode.kind === "inbound";
  const pickingStart = true;

  return (
    <svg
      viewBox={`0 0 ${VIEW.width} ${VIEW.height}`}
      className="bg-background w-full touch-manipulation select-none rounded-lg"
      role="img"
      aria-label="Field map. Tap a lane, the depot, the outpost, or a start position."
    >
      {/* carpet */}
      <rect x="8" y="24" width={VIEW.width - 16} height={STATION_Y - 36}
        className="fill-muted/40 stroke-border" strokeWidth="2" rx="4" />

      {/* opponent driver stations */}
      {[0, 1, 2].map((i) => (
        <rect key={i} x={64 + i * 82} y={OPP_STATION_Y - 8} width="70" height="14"
          rx="2" className={`${theirs} fill-current/15 stroke-current/50`} strokeWidth="1" />
      ))}

      {/* opponent wall and hub, drawn faintly — context, not a target */}
      <line x1="8" y1={OPP_WALL_Y} x2={VIEW.width - 8} y2={OPP_WALL_Y}
        className={`${theirs} stroke-current/40`} strokeWidth="3" />
      <polygon
        points={`${HUB_X},${OPP_WALL_Y - 12} ${HUB_X + 11},${OPP_WALL_Y - 6} ${HUB_X + 11},${OPP_WALL_Y + 6} ${HUB_X},${OPP_WALL_Y + 12} ${HUB_X - 11},${OPP_WALL_Y + 6} ${HUB_X - 11},${OPP_WALL_Y - 6}`}
        className="fill-foreground/30" />

      {/* neutral zone */}
      <line x1="8" y1={CENTER_Y} x2={VIEW.width - 8} y2={CENTER_Y}
        className="stroke-border" strokeWidth="1" strokeDasharray="3 5" />
      <FuelField />
      <text x={VIEW.width - 14} y={CENTER_Y - 44} textAnchor="end"
        className="fill-muted-foreground text-[9px]">Neutral zone</text>

      {/* our alliance zone */}
      <rect x="8" y={WALL_Y} width={VIEW.width - 16} height={STATION_Y - WALL_Y - 12}
        className={`${ours} fill-current/10 stroke-current/40`} strokeWidth="1.5" />

      {/* our wall, drawn as segments so the five openings read as gaps */}
      {(() => {
        const gaps = [...LANE_ORDER.map((l) => LANE_X[l]), HUB_X].sort((a, b) => a - b);
        const stops = [8, ...gaps, VIEW.width - 8];
        const segments = [];
        for (let i = 0; i < stops.length - 1; i++) {
          const from = stops[i] ?? 0;
          const to = stops[i + 1] ?? 0;
          segments.push({
            x1: gaps.includes(from) ? from + 24 : from,
            x2: gaps.includes(to) ? to - 24 : to,
          });
        }
        return segments.map((seg, i) =>
          seg.x2 > seg.x1 ? (
            <line key={i} x1={seg.x1} y1={WALL_Y} x2={seg.x2} y2={WALL_Y}
              className={`${ours} stroke-current`} strokeWidth="4" strokeLinecap="round" />
          ) : null,
        );
      })()}

      {/* completed steps, offset so overlapping ones stay countable */}
      {cycles.map((cycle, i) => {
        const offset = (i - (cycles.length - 1) / 2) * 5;
        const out = LANE_X[cycle.outbound] + offset;
        const inbound = cycle.inbound;
        const exitOnly = inbound === null;
        const back = inbound === null ? out : LANE_X[inbound] + offset;
        const apex = CENTER_Y + 14;
        return (
          <g key={i} className={`${ours} stroke-current`} opacity={0.7}>
            <path d={`M ${out} ${WALL_Y + 18} L ${out} ${apex}`}
              strokeWidth="2.5" fill="none" strokeLinecap="round" />
            {exitOnly ? (
              <path d={`M ${out - 5} ${apex + 9} L ${out} ${apex} L ${out + 5} ${apex + 9}`}
                strokeWidth="2.5" fill="none" strokeLinecap="round" />
            ) : (
              <>
                <path d={`M ${out} ${apex} L ${back} ${apex}`}
                  strokeWidth="2.5" fill="none" strokeLinecap="round" />
                <path d={`M ${back} ${apex} L ${back} ${WALL_Y + 18}`}
                  strokeWidth="2.5" fill="none" strokeLinecap="round" />
              </>
            )}
            <circle cx={exitOnly ? out : back} cy={exitOnly ? apex - 12 : WALL_Y + 18}
              r="7.5" className="fill-background stroke-current" strokeWidth="1.5" />
            <text x={exitOnly ? out : back} y={(exitOnly ? apex - 12 : WALL_Y + 18) + 3}
              textAnchor="middle" className="fill-foreground stroke-none text-[9px]">
              {i + 1}
            </text>
          </g>
        );
      })}

      {/* our hub, sitting in the wall */}
      <polygon
        points={`${HUB_X},${WALL_Y - 15} ${HUB_X + 13},${WALL_Y - 7} ${HUB_X + 13},${WALL_Y + 7} ${HUB_X},${WALL_Y + 15} ${HUB_X - 13},${WALL_Y + 7} ${HUB_X - 13},${WALL_Y - 7}`}
        className="fill-foreground/80" />
      <text x={HUB_X} y={WALL_Y + 29} textAnchor="middle"
        className="fill-muted-foreground text-[9px]">Hub</text>

      {/* lane tap targets */}
      {LANE_ORDER.map((lane) => {
        const x = LANE_X[lane];
        const armed = mode.kind === "inbound" && mode.outbound === lane;
        return (
          <g key={lane}
            onClick={() => pickingLane && onPickLane(lane)}
            className={pickingLane ? "cursor-pointer" : ""}>
            <rect x={x - 24} y={WALL_Y - 20} width="48" height="40" rx="7"
              className={
                pickingLane
                  ? "fill-primary/15 stroke-primary"
                  : "fill-muted stroke-border"
              }
              strokeWidth={armed ? 2.5 : pickingLane ? 2 : 1} />
            <text x={x} y={WALL_Y + 3} textAnchor="middle"
              className="fill-foreground text-[9px]">{LANE_LABEL[lane]}</text>
          </g>
        );
      })}

      {/* tower */}
      <g>
        <rect x={TOWER.x - TOWER.w / 2} y={TOWER.y - TOWER.h / 2}
          width={TOWER.w} height={TOWER.h} rx="3"
          className="fill-foreground/10 stroke-foreground/60" strokeWidth="1.5" />
        <path
          d={`M ${TOWER.x - TOWER.w / 2} ${TOWER.y - TOWER.h / 2} L ${TOWER.x + TOWER.w / 2} ${TOWER.y + TOWER.h / 2}
              M ${TOWER.x + TOWER.w / 2} ${TOWER.y - TOWER.h / 2} L ${TOWER.x - TOWER.w / 2} ${TOWER.y + TOWER.h / 2}`}
          className="stroke-foreground/40" strokeWidth="1.5" fill="none" />
        <text x={TOWER.x} y={TOWER.y + TOWER.h / 2 + 11} textAnchor="middle"
          className="fill-muted-foreground text-[9px]">Tower</text>
      </g>

      {/* depot and outpost — both tap targets */}
      {([["depot", DEPOT], ["outpost", OUTPOST]] as const).map(([kind, box]) => (
        <g key={kind}
          onClick={() => canPickPickup && onPickPickup(kind)}
          className={canPickPickup ? "cursor-pointer" : ""}>
          <rect x={box.x - box.w / 2} y={box.y - box.h / 2}
            width={box.w} height={box.h} rx="3"
            className={
              canPickPickup
                ? `${ours} fill-current/15 stroke-current`
                : "fill-muted stroke-border"
            }
            strokeWidth="1.5" />
          <FuelBox x={box.x} y={box.y} w={box.w} h={box.h} />
          <text x={box.x} y={box.y + box.h / 2 + 11} textAnchor="middle"
            className="fill-muted-foreground text-[9px] capitalize">{kind}</text>
        </g>
      ))}

      {/* robot starting line */}
      <line x1="16" y1={START_LINE_Y} x2={VIEW.width - 16} y2={START_LINE_Y}
        className={`${ours} stroke-current`} strokeWidth="2" strokeDasharray="5 4" />

      {/* start position targets */}
      {START_ORDER.map((position) => {
        const x = startX(position);
        const chosen = start === position;
        return (
          <g key={position}
            onClick={() => pickingStart && onPickStart(position)}
            className="cursor-pointer">
            <circle cx={x} cy={START_LINE_Y} r="13"
              className={
                chosen
                  ? "fill-primary stroke-primary"
                  : "fill-background stroke-primary/60"
              }
              strokeWidth="2" />
            {chosen ? (
              <circle cx={x} cy={START_LINE_Y} r="5"
                className="fill-primary-foreground" />
            ) : null}
          </g>
        );
      })}

      {/* our driver stations */}
      {[0, 1, 2].map((i) => (
        <rect key={i} x={64 + i * 82} y={STATION_Y - 6} width="70" height="16"
          rx="2" className={`${ours} fill-current/25 stroke-current`} strokeWidth="1.5" />
      ))}
      <text x={VIEW.width / 2} y={VIEW.height - 4} textAnchor="middle"
        className="fill-muted-foreground text-[9px]">
        {alliance} drivers · left and right as they see it
      </text>
    </svg>
  );
}
EOF

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
