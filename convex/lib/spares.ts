/**
 * Spare parts a team keeps in its pit, from the 2026 pit form. Shared by the
 * form, the team modal and the export.
 */

export type SparePart = "intake" | "indexer" | "shooter" | "swerve" | "other";

export type Spare = { part: SparePart; quantity: number; specify: string };

/** In the order the form lists them. */
export const SPARE_PARTS: ReadonlyArray<{ part: SparePart; label: string }> = [
  { part: "intake", label: "Intake" },
  { part: "indexer", label: "Indexer rollers (if applicable)" },
  { part: "shooter", label: "Shooter parts" },
  { part: "swerve", label: "Swerve modules" },
  { part: "other", label: "Other" },
];

/** Short names for summaries, without the form's "(if applicable)". */
export const SPARE_SHORT: Record<SparePart, string> = {
  intake: "Intake",
  indexer: "Indexer rollers",
  shooter: "Shooter parts",
  swerve: "Swerve modules",
  other: "Other",
};

/** "2× Swerve modules (MK4i corner)". */
export function spareText(spare: Spare): string {
  return `${spare.quantity}× ${SPARE_SHORT[spare.part]} (${spare.specify})`;
}
