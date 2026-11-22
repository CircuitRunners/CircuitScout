/**
 * How a match report from the form for seasons without their own forms
 * reads, as label/text pairs for the match and team views. Final notes are
 * shown on their own, so they are not in here. Plain notes from before the
 * form have no sections at all.
 */
export type GenericMatchFields = {
  autoPath?: string;
  autoScoring?: string;
  teleopScoring?: string;
  endgame?: string;
  driver?: number;
  defense?: number;
  broke?: boolean;
  brokeNotes?: string;
  inconsistent?: boolean;
  inconsistentNotes?: string;
};

export function matchSections(n: GenericMatchFields): Array<[string, string]> {
  const out: Array<[string, string]> = [];
  const add = (label: string, value: string | undefined) => {
    if (value !== undefined && value.trim() !== "") out.push([label, value.trim()]);
  };
  add("Auto path", n.autoPath);
  add("Auto scoring", n.autoScoring);
  add("Teleop scoring", n.teleopScoring);
  add("Endgame", n.endgame);
  if (n.driver !== undefined) add("Driver", `${n.driver}/10`);
  if (n.defense !== undefined) add("Defense", `${n.defense}/10`);
  if (n.broke) add("Broke down", n.brokeNotes?.trim() || "Yes");
  if (n.inconsistent) add("Inconsistent", n.inconsistentNotes?.trim() || "Yes");
  return out;
}
