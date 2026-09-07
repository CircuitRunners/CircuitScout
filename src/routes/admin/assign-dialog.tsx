import { useMutation, useQuery } from "convex/react";
import { Trash2 } from "lucide-react";
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
import type { Station } from "@/lib/types";

function useMaxMatch() {
  const matches = useQuery(api.matches.listForEvent);
  return (matches ?? []).reduce((max, m) => Math.max(max, m.matchNumber), 0);
}

/** One scout: add shifts and see what they already have. */
export function AssignDialog({
  profileId, displayName, onClose,
}: {
  profileId: Id<"profiles"> | null;
  displayName: string;
  onClose: () => void;
}) {
  const shifts = useQuery(
    api.assignments.forProfile,
    profileId ? { profileId } : "skip",
  );
  const create = useMutation(api.assignments.create);
  const remove = useMutation(api.assignments.remove);
  const maxMatch = useMaxMatch();
  const [busy, setBusy] = useState(false);

  const add = (shift: { fromMatch: number; toMatch: number; station: Station }) => {
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
                <p className="text-muted-foreground text-sm">Loading…</p>
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

/** Several scouts at once: pick people, then pick one shift for all of them. */
export function BatchAssignDialog({
  open, profiles, onClose,
}: {
  open: boolean;
  profiles: { _id: Id<"profiles">; displayName: string; teamNumber?: number }[];
  onClose: () => void;
}) {
  const create = useMutation(api.assignments.create);
  const maxMatch = useMaxMatch();
  const [selected, setSelected] = useState<Id<"profiles">[]>([]);
  const [search, setSearch] = useState("");
  const [step, setStep] = useState<"pick" | "shift">("pick");
  const [busy, setBusy] = useState(false);

  const shown = useMemo(() => {
    const needle = search.trim().toLowerCase();
    return needle === ""
      ? profiles
      : profiles.filter((p) => p.displayName.toLowerCase().includes(needle));
  }, [profiles, search]);

  const reset = () => { setSelected([]); setSearch(""); setStep("pick"); };

  const add = (shift: { fromMatch: number; toMatch: number; station: Station }) => {
    setBusy(true);
    void create({ profileIds: selected, ...shift })
      .then((r) => {
        toast.success(`Shift added for ${r.created} scouts`);
        reset();
        onClose();
      })
      .catch((error: unknown) =>
        // One scout's clash aborts the whole batch, so nobody ends up half
        // assigned and the message names who to fix.
        toast.error("Nobody was assigned", {
          description: error instanceof Error ? error.message : String(error),
        }))
      .finally(() => setBusy(false));
  };

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) { reset(); onClose(); } }}>
      <DialogContent className="max-h-[85vh] max-w-md overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {step === "pick" ? "Batch assign shifts" : "Shift for everyone selected"}
          </DialogTitle>
          <DialogDescription>
            {step === "pick"
              ? "Pick the scouts, then set one shift for all of them."
              : profiles.filter((p) => selected.includes(p._id))
                  .map((p) => p.displayName).join(", ")}
          </DialogDescription>
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
              Assign {selected.length} scout{selected.length === 1 ? "" : "s"}
            </Button>
          </>
        ) : maxMatch === 0 ? (
          <p className="text-muted-foreground text-sm">No schedule imported yet.</p>
        ) : (
          <>
            <ShiftPicker maxMatch={maxMatch} busy={busy}
              addLabel={`Add shift for ${selected.length}`} onAdd={add} />
            <Button variant="ghost" onClick={() => setStep("pick")}>
              <Trash2 className="size-3" /> Back to scouts
            </Button>
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}
