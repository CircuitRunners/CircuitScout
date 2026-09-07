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
