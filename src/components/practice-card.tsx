import { useMutation, useQuery } from "convex/react";
import { ChevronRight, Eye, X } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { api } from "../../convex/_generated/api";
import type { Id } from "../../convex/_generated/dataModel";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import {
  Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { Switch } from "@/components/ui/switch";

type Kind = "match" | "pit" | "pitNote" | "matchNote";
type Row = {
  _id: Id<"practiceSubmissions">;
  kind: Kind;
  teamNumber: number;
  matchNumber: number | null;
  eventName: string;
  payload: string;
  submittedAt: number;
};

// ─── reading a stored payload safely ──────────────────────────────────────
type Obj = Record<string, unknown>;
const obj = (x: unknown): Obj => (x !== null && typeof x === "object" ? (x as Obj) : {});
const numAt = (x: unknown): number | null => (typeof x === "number" ? x : null);
const strAt = (x: unknown): string => (typeof x === "string" ? x.trim() : "");
const yes = (x: unknown) => x === true;

function title(row: Row): string {
  switch (row.kind) {
    case "match": return `Qual ${row.matchNumber ?? "?"} · ${row.teamNumber}`;
    case "pit": return `Pit · ${row.teamNumber}`;
    case "pitNote": return `Pit · ${row.teamNumber}`;
    case "matchNote": return `Qual ${row.matchNumber ?? "?"} · ${row.teamNumber}`;
  }
}

/** The fields a scout would want to check, as label/value pairs. */
function summary(row: Row): Array<[string, string]> {
  let p: Obj;
  try { p = obj(JSON.parse(row.payload)); } catch { return [["Data", "Could not read this submission."]]; }
  const out: Array<[string, string]> = [];
  const add = (label: string, value: string | number | null) => {
    if (value !== null && value !== "") out.push([label, String(value)]);
  };

  if (row.kind === "matchNote") {
    // The match form for seasons without their own forms (or an older plain note).
    add("Auto path", strAt(p.autoPath));
    add("Auto scoring", strAt(p.autoScoring));
    add("Teleop scoring", strAt(p.teleopScoring));
    add("Endgame", strAt(p.endgame));
    add("Driver", numAt(p.driver));
    add("Defense", numAt(p.defense));
    if (yes(p.broke)) add("Broke down", strAt(p.brokeNotes) || "Yes");
    if (yes(p.inconsistent)) add("Inconsistent", strAt(p.inconsistentNotes) || "Yes");
    add("Final notes", strAt(p.notes) || "(empty)");
    return out;
  }
  if (row.kind === "pitNote") {
    // The pit form for seasons without their own forms (or an older plain note).
    add("Scoring", strAt(p.scoringText));
    add("Drivetrain", strAt(p.drivetrain));
    add("Gearing", strAt(p.drivetrainGearing));
    const pounds = numAt(p.robotWeight);
    add("Weight", pounds === null ? null : `${pounds} lbs`);
    const spareRows = Array.isArray(p.spares) ? p.spares.length : 0;
    const batteryRows = Array.isArray(p.batteries) ? p.batteries.length : 0;
    if (spareRows > 0) add("Spares listed", spareRows);
    if (batteryRows > 0) add("Battery rows", batteryRows);
    add("Robot notes", strAt(p.notes));
    add("Other notes", strAt(p.otherNotes));
    if (out.length === 0) add("Notes", "(empty)");
    return out;
  }

  if (row.kind === "match") {
    const auto = obj(p.auto);
    const teleop = obj(p.teleop);
    const endgame = obj(p.endgame);
    const ratings = obj(p.ratings);
    const byShift = Object.values(obj(teleop.byShift)).reduce<number>(
      (sum, n) => sum + (numAt(n) ?? 0), 0);
    add("Auto fuel", numAt(auto.fuel));
    add("Auto fouls", numAt(auto.fouls));
    add("Auto winner", strAt(p.autoWinner));
    add("Teleop fuel", byShift);
    add("Passed", (numAt(teleop.passedNeutral) ?? 0) + (numAt(teleop.passedFullField) ?? 0));
    add("Stole fuel", numAt(teleop.stoleFuel));
    add("Defended", yes(teleop.defended) ? "Yes" : "No");
    add("Climb", strAt(endgame.climb));
    add("Driver", numAt(ratings.driver));
    add("Defense", numAt(ratings.defense));
    const accuracy = numAt(ratings.accuracy);
    add("Accuracy", accuracy === null ? null : `${accuracy}%`);
    add("Avg BPS", numAt(p.avgBps));
    if (yes(ratings.broke)) add("Broke down", strAt(ratings.brokeNotes) || "Yes");
    if (yes(ratings.inconsistent)) add("Inconsistent", strAt(ratings.inconsistentNotes) || "Yes");
    add("Auto notes", strAt(auto.notes));
    add("Teleop notes", strAt(teleop.notes));
    add("Final notes", strAt(p.finalNotes));
    return out;
  }

  // Pit report.
  const scoring = obj(p.scoring);
  const climb = obj(p.climb);
  const hopper = obj(p.hopper);
  const shooters = [
    yes(scoring.turret) ? "Turret" : null,
    yes(scoring.drumFullWidth) ? "Full-width drum" : null,
    yes(scoring.drumNonFullWidth) ? "Drum" : null,
    yes(scoring.fixed) ? "Fixed shooter" : null,
    yes(scoring.kitbot) ? "Kitbot" : null,
    yes(scoring.other) ? (strAt(scoring.otherText) || "Other") : null,
  ].filter((s): s is string => s !== null);
  const climbs = [
    yes(climb.low) ? "L1" : null, yes(climb.mid) ? "L2" : null, yes(climb.high) ? "L3" : null,
    yes(climb.duringAuto) ? "auto" : null,
  ].filter((s): s is string => s !== null);
  add("Scoring", shooters.join(", ") || "None ticked");
  add("Hopper", [strAt(hopper.roof), numAt(hopper.capacity)].filter((s) => s !== "" && s !== null).join(", "));
  add("Climb", climbs.join(", ") || "None ticked");
  add("Drivetrain", strAt(p.drivetrain));
  add("Gearing", strAt(p.drivetrainGearing));
  const weight = numAt(p.robotWeight);
  add("Weight", weight === null ? null : `${weight} lbs`);
  add("Under trench", yes(p.underTrench) ? "Yes" : "No");
  add("Over bump", yes(p.overBump) ? "Yes" : "No");
  const spares = Array.isArray(p.spares) ? p.spares.length : 0;
  const batteries = Array.isArray(p.batteries) ? p.batteries.length : 0;
  if (spares > 0) add("Spares listed", spares);
  if (batteries > 0) add("Battery rows", batteries);
  add("Robot notes", strAt(p.robotNotes));
  add("Other notes", strAt(p.otherNotes));
  return out;
}

export function PracticeCard({ className = "" }: { className?: string }) {
  const status = useQuery(api.practice.status);
  const rows = useQuery(api.practice.mine);
  const setMode = useMutation(api.practice.setMode);
  const remove = useMutation(api.practice.remove);
  const clear = useMutation(api.practice.clear);
  const [viewing, setViewing] = useState<Row | null>(null);
  // Collapsed by default, so a long practice history does not push the page down.
  const [open, setOpen] = useState(false);
  const on = status?.on ?? false;

  return (
    <Card className={className}>
      <CardHeader>
        <CardTitle>Practice mode</CardTitle>
        <CardDescription>
          Scout for practice without touching real data. While it is on,
          match reports, pit reports and notes you submit are saved only for
          you, marked as practice.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <label className="flex cursor-pointer items-center justify-between gap-3 rounded-lg border p-3">
          <span className="text-sm font-medium">{on ? "Practice mode is on" : "Practice mode is off"}</span>
          <Switch checked={on} disabled={status === undefined}
            onCheckedChange={(next: boolean) => {
              void setMode({ on: next })
                .then(() => toast.success(next
                  ? "Practice mode on. Nothing you submit will count."
                  : "Practice mode off. Submissions count again."))
                .catch(() => toast.error("Could not change practice mode"));
            }} />
        </label>

        {rows && rows.length > 0 ? (
          <div className="space-y-2">
            <div className="flex items-center justify-between gap-2">
              <button type="button" aria-expanded={open} aria-controls="practice-submissions"
                onClick={() => setOpen((o) => !o)}
                className="hover:text-foreground flex min-h-8 items-center gap-1.5 text-left text-sm font-medium">
                <ChevronRight className={["size-4 shrink-0 transition-transform", open ? "rotate-90" : ""].join(" ")} />
                Your practice submissions
                <span className="text-muted-foreground font-normal tabular-nums">({rows.length})</span>
              </button>
              <Button size="sm" variant="ghost"
                onClick={() => {
                  void clear({}).then((r) => toast.success(`Cleared ${r.removed} practice submissions`));
                }}>
                Clear all
              </Button>
            </div>
            {open ? (
            <div id="practice-submissions" className="max-h-72 space-y-1 overflow-y-auto">
              {rows.map((row) => (
                <div key={row._id} className="flex items-center gap-2 rounded-lg border p-2">
                  <Badge variant="outline" className="border-destructive/60 text-destructive shrink-0">
                    Practice
                  </Badge>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm">{title(row)}</p>
                    <p className="text-muted-foreground truncate text-xs">
                      {row.eventName} · {new Date(row.submittedAt).toLocaleString()}
                    </p>
                  </div>
                  <Button size="icon" variant="ghost" className="size-8"
                    aria-label={`View ${title(row)}`} onClick={() => setViewing(row)}>
                    <Eye className="size-4" />
                  </Button>
                  <Button size="icon" variant="ghost" className="size-8"
                    aria-label={`Delete ${title(row)}`}
                    onClick={() => void remove({ id: row._id })}>
                    <X className="size-4" />
                  </Button>
                </div>
              ))}
            </div>
            ) : null}
          </div>
        ) : on ? (
          <p className="text-muted-foreground text-sm">
            Nothing submitted in practice yet.
          </p>
        ) : null}
      </CardContent>

      <Dialog open={viewing !== null} onOpenChange={(next) => { if (!next) setViewing(null); }}>
        <DialogContent className="max-w-sm">
          {viewing ? (
            <>
              <DialogHeader>
                <DialogTitle className="flex items-center gap-2">
                  {title(viewing)}
                  <Badge variant="outline" className="border-destructive/60 text-destructive">Practice</Badge>
                </DialogTitle>
                <DialogDescription>
                  {viewing.eventName} · {new Date(viewing.submittedAt).toLocaleString()}.
                  Not part of any real data.
                </DialogDescription>
              </DialogHeader>
              <dl className="grid max-h-[60vh] grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1.5 overflow-y-auto text-sm">
                {summary(viewing).map(([label, value]) => (
                  <div key={label} className="contents">
                    <dt className="text-muted-foreground">{label}</dt>
                    <dd className="break-words">{value}</dd>
                  </div>
                ))}
              </dl>
            </>
          ) : null}
        </DialogContent>
      </Dialog>
    </Card>
  );
}
