/**
 * Single source of truth for REBUILT scoring and match timing.
 * Nothing anywhere else may hardcode these numbers.
 */

export const CLIMB_POINTS = {
  /** Any auto climb scores 15. Rules permit L1 only during auto. */
  auto: 15,
  endgame: { none: 0, low: 10, mid: 20, high: 30 },
} as const;

/** Neutral-zone trips possible in a 20-second auto. */
export const MAX_AUTO_CYCLES = 3;

export const SCOUT_WEIGHTS = { lead: 5, trusted: 3, normal: 1 } as const;

export const TIER_BASE = { t1: 100, t2: 70, t3: 40, dnp: -100 } as const;
/** Position inside a column adjusts within this band, never across tiers. */
export const TIER_POSITION_BAND = 25;

/**
 * Match timing, seconds from the start of the match.
 * autoPause is approximate — FMS assesses auto fuel before teleop begins.
 * Tune here if real matches drift.
 */
export const MATCH_TIMING = {
  autoSeconds: 20,
  autoPauseSeconds: 3,
  teleopSeconds: 140,
} as const;

export type ShiftKey = "transition" | "s1" | "s2" | "s3" | "s4";
export type Phase = "pre" | "auto" | "pause" | ShiftKey | "endgame" | "over";

/** Seconds REMAINING in teleop at which each window starts and ends. */
const WINDOWS: ReadonlyArray<{ key: ShiftKey | "endgame"; from: number; to: number }> = [
  { key: "transition", from: 140, to: 130 },
  { key: "s1", from: 130, to: 105 },
  { key: "s2", from: 105, to: 80 },
  { key: "s3", from: 80, to: 55 },
  { key: "s4", from: 55, to: 30 },
  { key: "endgame", from: 30, to: 0 },
];

export function phaseAt(secondsSinceMatchStart: number): Phase {
  const t = secondsSinceMatchStart;
  if (t < 0) return "pre";
  if (t < MATCH_TIMING.autoSeconds) return "auto";
  const teleopStart = MATCH_TIMING.autoSeconds + MATCH_TIMING.autoPauseSeconds;
  if (t < teleopStart) return "pause";

  const remaining = MATCH_TIMING.teleopSeconds - (t - teleopStart);
  if (remaining <= 0) return "over";
  for (const w of WINDOWS) {
    if (remaining <= w.from && remaining > w.to) return w.key;
  }
  return "over";
}

/**
 * The alliance that scores MORE auto fuel goes inactive first, so it is
 * active in shifts 2 and 4. Transition and endgame are active for everyone.
 */
export function activeShifts(isAutoWinner: boolean): ReadonlyArray<ShiftKey> {
  return isAutoWinner ? ["transition", "s2", "s4"] : ["transition", "s1", "s3"];
}

export type ByShift = Record<ShiftKey, number>;

export const EMPTY_BY_SHIFT: ByShift = {
  transition: 0, s1: 0, s2: 0, s3: 0, s4: 0,
};

/** Teleop fuel that actually scored points. */
export function countedTeleopFuel(byShift: ByShift, isAutoWinner: boolean): number {
  return activeShifts(isAutoWinner).reduce((sum, k) => sum + byShift[k], 0);
}

/** Teleop fuel put through a dead hub — worth zero match points. */
export function uncountedTeleopFuel(byShift: ByShift, isAutoWinner: boolean): number {
  const active = new Set<ShiftKey>(activeShifts(isAutoWinner));
  return (Object.keys(byShift) as ShiftKey[])
    .filter((k) => !active.has(k))
    .reduce((sum, k) => sum + byShift[k], 0);
}

export function climbPoints(autoClimbL1: boolean, endgame: keyof typeof CLIMB_POINTS.endgame): number {
  return (autoClimbL1 ? CLIMB_POINTS.auto : 0) + CLIMB_POINTS.endgame[endgame];
}

export const MATCH_DURATION_SECONDS =
  MATCH_TIMING.autoSeconds + MATCH_TIMING.autoPauseSeconds + MATCH_TIMING.teleopSeconds;

/**
 * A report finished before the buzzer cannot have observed the endgame — the
 * climb, the last shift's fuel, whether the robot died at 0:15. Derived rather
 * than stored so it stays correct if the timing constants change.
 * Unknowable without a time anchor, so an untimed report is never flagged.
 */
export function submittedBeforeMatchEnd(
  matchStartedAt: number | null,
  submittedAt: number,
): boolean {
  if (matchStartedAt === null) return false;
  return submittedAt < matchStartedAt + MATCH_DURATION_SECONDS * 1000;
}
