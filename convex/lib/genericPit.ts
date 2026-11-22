/**
 * Completeness of a pit report from the form used for seasons without their
 * own forms. Shared by the server (pit page status, blank check on save) and
 * the form (live "still needed" hint).
 *
 * Complete needs: scoring capability, drivetrain, robot weight and at least
 * one battery. Not needed: drivetrain gearing, spares, photo, notes.
 */

export type GenericPitStatus = "none" | "partial" | "complete";

export const GENERIC_PIT_LABELS: Record<GenericPitStatus, string> = {
  none: "Not scouted",
  partial: "Partially scouted",
  complete: "Scouted",
};

export type GenericPitFields = {
  scoringText?: string;
  drivetrain?: string;
  drivetrainGearing?: string;
  robotWeight?: number | null;
  spares?: ReadonlyArray<unknown>;
  batteries?: ReadonlyArray<unknown>;
  photoId?: string | null;
  notes?: string;
  otherNotes?: string;
};

/** Drivetrains whose detail box is needed. */
const DETAIL_NEEDED = new Set(["Swerve", "Other"]);
const filled = (s: string | undefined) => (s ?? "").trim() !== "";

export function genericPitMissing(r: GenericPitFields): string[] {
  const missing: string[] = [];
  if (!filled(r.scoringText)) missing.push("scoring capability");
  const [base = "", ...rest] = (r.drivetrain ?? "").split(" — ");
  if (base.trim() === "" || (DETAIL_NEEDED.has(base.trim()) && rest.join(" — ").trim() === "")) {
    missing.push("drivetrain");
  }
  if (r.robotWeight === undefined || r.robotWeight === null) missing.push("robot weight");
  if ((r.batteries ?? []).length === 0) missing.push("batteries");
  return missing;
}

export function genericPitIsBlank(r: GenericPitFields): boolean {
  return !(
    filled(r.scoringText) || filled(r.drivetrain) || filled(r.drivetrainGearing) ||
    (r.robotWeight !== undefined && r.robotWeight !== null) ||
    (r.spares ?? []).length > 0 || (r.batteries ?? []).length > 0 ||
    (r.photoId !== undefined && r.photoId !== null) ||
    filled(r.notes) || filled(r.otherNotes)
  );
}

export function genericPitStatus(r: GenericPitFields | null | undefined): GenericPitStatus {
  if (!r || genericPitIsBlank(r)) return "none";
  return genericPitMissing(r).length === 0 ? "complete" : "partial";
}
