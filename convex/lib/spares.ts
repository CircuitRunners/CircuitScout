/**
 * Spare parts and batteries a team keeps in its pit, from the 2026 pit form.
 * Shared by the form, the team modal and the export.
 */

export type SparePart = "intake" | "indexer" | "shooter" | "swerve" | "other";

/** quantity is an estimate and optional; specify is required. */
export type Spare = { part: SparePart; quantity?: number; specify: string };

/** In the order reports list them; Other rows come last. */
export const SPARE_PARTS: ReadonlyArray<{ part: SparePart; label: string }> = [
  { part: "intake", label: "Intake" },
  { part: "indexer", label: "Indexer rollers (if applicable)" },
  { part: "shooter", label: "Shooter parts" },
  { part: "swerve", label: "Swerve modules" },
  { part: "other", label: "Other" },
];

/** The parts the form lists as checkboxes. Other is not one of them: the form
 *  adds Other rows with a plus, and a report can hold several. */
export type FixedSparePart = Exclude<SparePart, "other">;
export const FIXED_SPARE_PARTS = SPARE_PARTS.filter(
  (p): p is { part: FixedSparePart; label: string } => p.part !== "other",
);

/** How many Other spares one report can list. */
export const MAX_OTHER_SPARES = 10;

/** Short names for summaries, without the form's "(if applicable)". */
export const SPARE_SHORT: Record<SparePart, string> = {
  intake: "Intake",
  indexer: "Indexer rollers",
  shooter: "Shooter parts",
  swerve: "Swerve modules",
  other: "Other",
};

/** "~2× Swerve modules (MK4i corner)", or without the count when none was given. */
export function spareText(spare: Spare): string {
  const count = spare.quantity === undefined ? "" : `~${spare.quantity}× `;
  return `${count}${SPARE_SHORT[spare.part]} (${spare.specify})`;
}

// ─── Batteries ─────────────────────────────────────────────────────────────

export type BatteryType = "mk" | "energizer" | "duracell" | "other";

/**
 * One kind of battery. otherType is the typed-in brand, only for "other".
 * quantity is how many of that kind are in good condition, and required
 * (rows saved before that may lack it).
 *
 * condition is legacy: the form had a free-text Condition box until it was
 * replaced by counting only good batteries. Old reports still carry it, so it
 * stays in the type and schema, but nothing writes or shows it any more. On
 * those old reports quantity is the total count, not the good count.
 */
export type Battery = {
  type: BatteryType;
  otherType?: string;
  quantity?: number;
  condition?: string;
};

/** In the order the dropdown lists them. */
export const BATTERY_TYPES: ReadonlyArray<{ type: BatteryType; label: string }> = [
  { type: "mk", label: "MK" },
  { type: "energizer", label: "Energizer" },
  { type: "duracell", label: "Duracell" },
  { type: "other", label: "Other" },
];

export function batteryName(battery: Battery): string {
  if (battery.type === "other") return battery.otherType?.trim() || "Other";
  return BATTERY_TYPES.find((b) => b.type === battery.type)?.label ?? battery.type;
}

/** "3× MK", where 3 is how many are in good condition. */
export function batteryText(battery: Battery): string {
  const count = battery.quantity === undefined ? "" : `${battery.quantity}× `;
  return `${count}${batteryName(battery)}`;
}
