import { useCachedQuery } from "@/lib/offline/use-cached-query";
import { LoadingText } from "@/components/loading-text";
import { useOnlineMutation } from "@/lib/offline/use-online-mutation";
import { ArrowLeft } from "lucide-react";
import { useMemo, useState } from "react";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { ShiftPicker, ShiftRow } from "@/components/shift-picker";
import { Button } from "@/components/ui/button";
import {
  Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { STATION_LABELS, type Station } from "@/lib/types";

type Shift = { fromMatch: number; toMatch: number; station: Station };
/** Staged, not written. The key is the range, which is unique by construction. */
type Staged = Shift & { key: string };
type Report = {
  created: number;
  attempted: number;
  skipped: (Shift & { displayName: string; reason: string })[];
};

function useMaxMatch() {
  const matches = useCachedQuery(api.matches.listForEvent);
  return (matches ?? []).reduce((max, m) => Math.max(max, m.matchNumber), 0);
}

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;

/** One scout: add shifts and see what they already have. */
export function AssignDialog({
  profileId, displayName, onClose,
}: {
  profileId: Id<"profiles"> | null;
  displayName: string;
  onClose: () => void;
}) {
  const shifts = useCachedQuery(
    api.assignments.forProfile,
    profileId ? { profileId } : "skip",
  );
  const create = useOnlineMutation(api.assignments.create);
  const remove = useOnlineMutation(api.assignments.remove);
  const maxMatch = useMaxMatch();
  const [busy, setBusy] = useState(false);

  const add = (shift: Shift) => {
    if (!profileId) return;
    setBusy(true);
    void create({ profileIds: [profileId], ...shift })
      .then(() => toast.success("Shift added"))
      .catch((error: unknown) =>
        toast.error("Could not add it", {
          description: error instanceof Error ? error.message : String(error),
        }))
      .finally(() => setBusy(false));
  };

  return (
    <Dialog open={profileId !== null} onOpenChange={(o) => { if (!o) onClose(); }}>
      <DialogContent className="max-h-[85vh] max-w-md overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Assign matches</DialogTitle>
          <DialogDescription>{displayName}</DialogDescription>
        </DialogHeader>

        {maxMatch === 0 ? (
          <p className="text-muted-foreground text-sm">
            No schedule imported yet, so there is nothing to assign.
          </p>
        ) : (
          <>
            <ShiftPicker maxMatch={maxMatch} busy={busy} addLabel="Add shift" onAdd={add} />

            <div className="space-y-2 border-t pt-4">
              <h3 className="text-sm font-medium">{displayName}'s shifts</h3>
              {shifts === undefined ? (
                <p className="text-muted-foreground text-sm"><LoadingText /></p>
              ) : shifts.length === 0 ? (
                <p className="text-muted-foreground text-sm">No shifts yet.</p>
              ) : (
                shifts.map((shift) => (
                  <ShiftRow key={shift._id}
                    fromMatch={shift.fromMatch} toMatch={shift.toMatch}
                    station={shift.station as Station}
                    onRemove={() => {
                      void remove({ assignmentId: shift._id })
                        .catch((error: unknown) =>
                          toast.error("Could not remove", {
                            description:
                              error instanceof Error ? error.message : String(error),
                          }));
                    }} />
                ))
              )}
            </div>
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}

/**
 * Several scouts at once: pick people, stage as many shifts as you like, then
 * write them all in one go. Nothing reaches the database until Assign, so the
 * trash here removes a plan — unlike the per-scout dialog, where it deletes a
 * shift someone already has.
 */
export function BatchAssignDialog({
  open, profiles, onClose,
}: {
  open: boolean;
  profiles: { _id: Id<"profiles">; displayName: string; teamNumber?: number }[];
  onClose: () => void;
}) {
  const createMany = useOnlineMutation(api.assignments.createMany);
  const maxMatch = useMaxMatch();
  const [selected, setSelected] = useState<Id<"profiles">[]>([]);
  const [search, setSearch] = useState("");
  const [staged, setStaged] = useState<Staged[]>([]);
  const [report, setReport] = useState<Report | null>(null);
  const [step, setStep] = useState<"pick" | "shift" | "report">("pick");
  const [busy, setBusy] = useState(false);

  const shown = useMemo(() => {
    const needle = search.trim().toLowerCase();
    return needle === ""
      ? profiles
      : profiles.filter((p) => p.displayName.toLowerCase().includes(needle));
  }, [profiles, search]);

  const close = () => {
    setSelected([]); setSearch(""); setStaged([]); setReport(null); setStep("pick");
    onClose();
  };

  // Every selected scout gets every staged shift, so two that overlap each
  // other are wrong for everyone. Caught here rather than at the server.
  const stage = (shift: Shift) => {
    const clash = staged.find(
      (s) => shift.fromMatch <= s.toMatch && shift.toMatch >= s.fromMatch);
    if (clash) {
      toast.error("That overlaps a staged shift", {
        description:
          `Quals ${clash.fromMatch}–${clash.toMatch} (${STATION_LABELS[clash.station]}) is already in the list.`,
      });
      return false;
    }
    setStaged((rows) => [
      ...rows,
      { ...shift, key: `${shift.fromMatch}-${shift.toMatch}` },
    ].sort((a, b) => a.fromMatch - b.fromMatch));
    return true;
  };

  const assign = () => {
    if (staged.length === 0 || selected.length === 0) return;
    setBusy(true);
    void createMany({
      profileIds: selected,
      shifts: staged.map(({ fromMatch, toMatch, station }) =>
        ({ fromMatch, toMatch, station })),
    })
      .then((result) => {
        if (result.skipped.length === 0) {
          toast.success(`${plural(result.created, "shift")} assigned`);
          close();
          return;
        }
        // Part of it landed, so the skips need somewhere that stays put — a
        // toast is gone before eight names can be read.
        setReport(result);
        setStep("report");
      })
      .catch((error: unknown) =>
        toast.error("Nobody was assigned", {
          description: error instanceof Error ? error.message : String(error),
        }))
      .finally(() => setBusy(false));
  };

  const total = staged.length * selected.length;
  const chosen = profiles.filter((p) => selected.includes(p._id));

  const title = step === "pick"
    ? "Batch assign shifts"
    : step === "shift" ? "Shifts for everyone selected" : "Assigned with skips";

  const description = step === "pick"
    ? "Pick the scouts, then stage as many shifts as you need."
    : step === "shift"
      ? chosen.map((p) => p.displayName).join(", ")
      : report === null ? "" : `${report.created} of ${report.attempted} shifts written.`;

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) close(); }}>
      <DialogContent className="max-h-[85vh] max-w-md overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription>{description}</DialogDescription>
        </DialogHeader>

        {step === "pick" ? (
          <>
            <Input placeholder="Find a scout" value={search}
              onChange={(e) => setSearch(e.target.value)} />
            <div className="max-h-72 space-y-1 overflow-y-auto">
              {shown.map((profile) => {
                const on = selected.includes(profile._id);
                return (
                  <Button key={profile._id}
                    variant={on ? "secondary" : "ghost"}
                    className="w-full justify-start"
                    onClick={() =>
                      setSelected(on
                        ? selected.filter((id) => id !== profile._id)
                        : [...selected, profile._id])}>
                    {profile.displayName}
                    {profile.teamNumber !== undefined ? (
                      <span className="text-muted-foreground ml-1 text-xs">
                        ({profile.teamNumber})
                      </span>
                    ) : null}
                  </Button>
                );
              })}
            </div>
            <Button variant="secondary" disabled={selected.length === 0}
              onClick={() => setStep("shift")}>
              Assign {plural(selected.length, "scout")}
            </Button>
          </>
        ) : step === "report" && report !== null ? (
          <>
            <div className="space-y-3">
              {staged.map((shift) => {
                const skips = report.skipped.filter((s) =>
                  s.fromMatch === shift.fromMatch
                  && s.toMatch === shift.toMatch
                  && s.station === shift.station);
                return (
                  <div key={shift.key} className="space-y-1">
                    <ShiftRow fromMatch={shift.fromMatch} toMatch={shift.toMatch}
                      station={shift.station}
                      trailing={`${selected.length - skips.length} of ${selected.length}`} />
                    {skips.map((s) => (
                      <p key={s.displayName} className="text-muted-foreground pl-3 text-xs">
                        {s.displayName} — {s.reason}
                      </p>
                    ))}
                  </div>
                );
              })}
            </div>
            <p className="text-muted-foreground text-xs">
              Skipped shifts were not written. Fix the clash on that scout, then
              assign again — the ones that landed will be skipped next time.
            </p>
            <Button className="w-full" onClick={close}>Done</Button>
          </>
        ) : maxMatch === 0 ? (
          <p className="text-muted-foreground text-sm">No schedule imported yet.</p>
        ) : (
          <>
            <ShiftPicker maxMatch={maxMatch} busy={busy} advanceOnAdd
              addLabel="Add shift" onAdd={stage} />

            <div className="space-y-2 border-t pt-4">
              <div className="flex items-baseline justify-between">
                <h3 className="text-sm font-medium">Shifts to assign</h3>
                <span className="text-muted-foreground text-xs tabular-nums">
                  {staged.length} staged
                </span>
              </div>
              {staged.length === 0 ? (
                <p className="text-muted-foreground text-sm">
                  Nothing staged yet. Nothing is written until you assign.
                </p>
              ) : (
                staged.map((shift) => (
                  <ShiftRow key={shift.key}
                    fromMatch={shift.fromMatch} toMatch={shift.toMatch}
                    station={shift.station}
                    onRemove={() =>
                      setStaged((rows) => rows.filter((r) => r.key !== shift.key))} />
                ))
              )}
            </div>

            <div className="space-y-1 border-t pt-4">
              <Button className="w-full" disabled={busy || staged.length === 0}
                onClick={assign}>
                Assign {plural(total, "shift")}
              </Button>
              <p className="text-muted-foreground text-center text-xs">
                {plural(staged.length, "shift")} × {plural(selected.length, "scout")}
              </p>
            </div>

            <Button variant="ghost" onClick={() => setStep("pick")}>
              <ArrowLeft className="size-3" /> Back to scouts
            </Button>
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}
