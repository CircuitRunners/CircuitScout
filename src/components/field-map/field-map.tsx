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
