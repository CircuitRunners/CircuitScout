/**
 * How complete a pit report is. Shared by the server (team lists, exports,
 * the blank check on save) and the pit form (live "still needed" hint).
 *
 * Complete needs: scoring capability, hopper, drivetrain, robot weight and at
 * least one battery. Not needed: climb, drivetrain gearing, spares, photo,
 * notes. Under trench / over bump are checkboxes where unticked is a real
 * answer, so they never make a report incomplete; ticking one does make it
 * not blank.
 */

export type PitStatus = "none" | "partial" | "complete";

export const PIT_STATUS_LABELS: Record<PitStatus, string> = {
  none: "Not scouted",
  partial: "Partially scouted",
  complete: "Scouted",
};

/** The parts of a pit report the status looks at. A stored report fits. */
export type PitFields = {
  scoring: {
    turret: boolean; drumNonFullWidth: boolean; drumFullWidth: boolean;
    fixed: boolean; kitbot: boolean; other: boolean; otherText: string;
  };
  climb: { low: boolean; mid: boolean; high: boolean; duringAuto: boolean };
  drivetrain: string;
  drivetrainGearing?: string;
  robotWeight?: number | null;
  underTrench: boolean;
  overBump: boolean;
  robotNotes: string;
  otherNotes: string;
  photoId?: string | null;
  hopper?: {
    roof: string | null;
    capacity: number | null;
    expandedCapacity: number | null;
  };
  spares?: ReadonlyArray<unknown>;
  batteries?: ReadonlyArray<unknown>;
};

/** Drivetrains whose detail box ("Which swerve?", "Describe it") is needed. */
const DETAIL_NEEDED = new Set(["Swerve", "Other"]);

/** What a report still needs to count as complete, in form order. */
export function pitMissing(r: PitFields): string[] {
  const missing: string[] = [];

  const s = r.scoring;
  const anyScoring =
    s.turret || s.drumNonFullWidth || s.drumFullWidth || s.fixed || s.kitbot || s.other;
  if (!anyScoring || (s.other && s.otherText.trim() === "")) missing.push("scoring capability");

  const h = r.hopper;
  const expands = h?.roof === "expanding" || h?.roof === "net";
  if (!h || h.roof === null || h.capacity === null || (expands && h.expandedCapacity === null)) {
    missing.push("hopper");
  }

  const [base = "", ...rest] = r.drivetrain.split(" — ");
  const detail = rest.join(" — ").trim();
  if (base.trim() === "" || (DETAIL_NEEDED.has(base.trim()) && detail === "")) {
    missing.push("drivetrain");
  }

  if (r.robotWeight === undefined || r.robotWeight === null) missing.push("robot weight");
  if ((r.batteries ?? []).length === 0) missing.push("batteries");
  return missing;
}

/** True when nothing at all was filled in. */
export function pitIsBlank(r: PitFields): boolean {
  const s = r.scoring;
  const c = r.climb;
  const h = r.hopper;
  const filled =
    s.turret || s.drumNonFullWidth || s.drumFullWidth || s.fixed || s.kitbot || s.other ||
    s.otherText.trim() !== "" ||
    c.low || c.mid || c.high || c.duringAuto ||
    r.drivetrain.trim() !== "" ||
    (r.drivetrainGearing ?? "").trim() !== "" ||
    (r.robotWeight !== undefined && r.robotWeight !== null) ||
    r.underTrench || r.overBump ||
    r.robotNotes.trim() !== "" || r.otherNotes.trim() !== "" ||
    (r.photoId !== undefined && r.photoId !== null) ||
    (h !== undefined && (h.roof !== null || h.capacity !== null || h.expandedCapacity !== null)) ||
    (r.spares ?? []).length > 0 ||
    (r.batteries ?? []).length > 0;
  return !filled;
}

/** No report, or a blank one, is "none". */
export function pitStatus(r: PitFields | null | undefined): PitStatus {
  if (!r || pitIsBlank(r)) return "none";
  return pitMissing(r).length === 0 ? "complete" : "partial";
}
