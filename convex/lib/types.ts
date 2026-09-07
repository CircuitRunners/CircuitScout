/** Domain types shared by the Convex backend and the client. */

/**
 * Lanes through the alliance-zone wall.
 * Left and right are ALWAYS from that alliance's drivers looking out at the
 * field — never the scout's viewpoint, never red-relative. The UI must label
 * this permanently; a mirrored entry is silently wrong.
 */
export type Lane = "trench-left" | "bump-left" | "bump-right" | "trench-right";

export const LANES: ReadonlyArray<Lane> = [
  "trench-left", "bump-left", "bump-right", "trench-right",
];

export type StartPosition = Lane | "hub";

export const START_POSITIONS: ReadonlyArray<StartPosition> = [
  "trench-left", "bump-left", "hub", "bump-right", "trench-right",
];

/**
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
  | { kind: "outpost" }
  | { kind: "climb" };

export type AutoPath = {
  start: StartPosition | null;
  steps?: AutoStep[];
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
  climb: "L1 climb",
} as const;

export const EMPTY_AUTO_PATH: AutoPath = { start: null, steps: [] };

export type ClimbLevel = "none" | "low" | "mid" | "high";
export type Tier = "t1" | "t2" | "t3" | "dnp" | "uncategorized";
export type WeightTier = "lead" | "trusted" | "normal";
export type Role = "admin" | "teamAdmin" | "scout";
export type AllianceColor = "red" | "blue";
export type HubStateSource = "timed" | "estimated" | "none";

export const TIERS: ReadonlyArray<Tier> = ["t1", "t2", "t3", "dnp", "uncategorized"];

// Keys stay t1/t2/t3 — renaming them would be a schema migration for no gain.
export const TIER_LABELS: Record<Tier, string> = {
  t1: "First pick", t2: "Second pick", t3: "Third pick",
  dnp: "Do not pick", uncategorized: "Uncategorized",
};

export type TeamStats = {
  reportCount: number;
  avgAutoFuel: number;
  avgTeleopFuel: number;      // counted only
  avgUncountedFuel: number;
  avgEndgameFuel: number;
  avgTotalFuel: number;       // counted only
  avgClimbPoints: number;
  avgDriver: number;
  avgDefense: number;
  avgAccuracy: number;
  minTotalFuel: number;
  maxTotalFuel: number;
};

export const EMPTY_STATS: TeamStats = {
  reportCount: 0, avgAutoFuel: 0, avgTeleopFuel: 0, avgUncountedFuel: 0,
  avgEndgameFuel: 0, avgTotalFuel: 0, avgClimbPoints: 0, avgDriver: 0,
  avgDefense: 0, avgAccuracy: 0, minTotalFuel: 0, maxTotalFuel: 0,
};

export type Station =
  | "red1" | "red2" | "red3"
  | "blue1" | "blue2" | "blue3";

export const STATIONS: ReadonlyArray<Station> = [
  "red1", "red2", "red3", "blue1", "blue2", "blue3",
];

export const STATION_LABELS: Record<Station, string> = {
  red1: "Red 1", red2: "Red 2", red3: "Red 3",
  blue1: "Blue 1", blue2: "Blue 2", blue3: "Blue 3",
};

export function stationAlliance(station: Station): "red" | "blue" {
  return station.startsWith("red") ? "red" : "blue";
}

/** 0-based position within that alliance's three teams. */
export function stationIndex(station: Station): number {
  return Number.parseInt(station.slice(-1), 10) - 1;
}
