import { useEffect, useState } from "react";
import { MATCH_TIMING, phaseAt, type Phase, type ShiftKey } from "@/lib/scoring";

/**
 * Teleop fuel is banked per shift window so the counted/uncounted split can be
 * recomputed later if the auto winner turns out to be wrong. That needs a time
 * anchor, which is what "Match Start" provides.
 *
 * Transition is active for BOTH alliances, so it is the safe default bucket:
 * banking there can never fabricate dead-hub fuel that did not happen.
 */
export function bucketFor(phase: Phase): ShiftKey {
  switch (phase) {
    case "s1": case "s2": case "s3": case "s4":
      return phase;
    default:
      return "transition";
  }
}

export const PHASE_LABELS: Record<Phase, string> = {
  pre: "Not started",
  auto: "Auto",
  pause: "Auto scoring",
  transition: "Transition",
  s1: "Shift 1", s2: "Shift 2", s3: "Shift 3", s4: "Shift 4",
  endgame: "Endgame",
  over: "Match over",
};

export function useMatchClock(startedAt: number | null) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (startedAt === null) return;
    const id = window.setInterval(() => setNow(Date.now()), 500);
    return () => window.clearInterval(id);
  }, [startedAt]);

  if (startedAt === null) {
    return { phase: "pre" as Phase, elapsed: 0, bucket: "transition" as ShiftKey };
  }

  const elapsed = (now - startedAt) / 1000;
  const phase = phaseAt(elapsed);
  return { phase, elapsed, bucket: bucketFor(phase) };
}

/** Anchor used when the scout never tapped Match Start. */
export function estimatedStart(): number {
  const offset = (MATCH_TIMING.autoSeconds + MATCH_TIMING.autoPauseSeconds) * 1000;
  return Date.now() - offset;
}
