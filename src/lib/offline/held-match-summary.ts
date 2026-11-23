/**
 * A held 2026 match report, as a few readable rows. A match report cannot be
 * changed once it is submitted without a reason on record, so a held one is
 * shown rather than reopened as an editable form.
 *
 * `values` is the payload the form built for matchReports.submit. It is read
 * defensively: this is display only, and a field that is missing or renamed
 * should cost a row, not the page.
 */
export function summarizeMatchReport(values: unknown): Array<[label: string, value: string]> {
  const report = record(values);
  const auto = record(report.auto);
  const path = record(auto.path);
  const teleop = record(report.teleop);
  const endgame = record(report.endgame);
  const ratings = record(report.ratings);

  const steps = Array.isArray(path.steps) ? path.steps.length : 0;
  const teleopFuel = Object.values(record(teleop.byShift)).reduce<number>(
    (sum, n) => sum + (typeof n === "number" ? n : 0),
    0,
  );
  const rows: Array<[string, string]> = [
    ["Auto start", pretty(path.start)],
    ["Auto", `${number(auto.fuel)} fuel, ${steps} step${steps === 1 ? "" : "s"}${auto.climbL1 === true ? ", L1 climb" : ""}`],
    ["Auto winner", pretty(report.autoWinner)],
    ["Teleop fuel", String(teleopFuel)],
    ["Climb", pretty(endgame.climb)],
    ["Driver", String(number(ratings.driver))],
    ["Defense", String(number(ratings.defense))],
    ["Shooting accuracy", `${number(ratings.accuracy)}%`],
    ["Balls per second", String(number(report.avgBps))],
  ];
  if (ratings.broke === true) rows.push(["Broke", text(ratings.brokeNotes) || "Yes"]);
  if (ratings.inconsistent === true) rows.push(["Inconsistent", text(ratings.inconsistentNotes) || "Yes"]);
  rows.push(["Final notes", text(report.finalNotes)]);
  return rows.filter(([, value]) => value !== "");
}

const record = (value: unknown): Record<string, unknown> =>
  value !== null && typeof value === "object" ? (value as Record<string, unknown>) : {};
const number = (value: unknown): number => (typeof value === "number" ? value : 0);
const text = (value: unknown): string =>
  typeof value === "string" ? value : typeof value === "number" ? String(value) : "";
/** "trench-left" -> "Trench left": stored values, made readable. */
const pretty = (value: unknown): string => {
  const raw = text(value).replace(/-/g, " ");
  return raw === "" ? "" : raw.charAt(0).toUpperCase() + raw.slice(1);
};
