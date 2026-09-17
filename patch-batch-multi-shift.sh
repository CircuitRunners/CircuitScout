#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-batch-multi-shift.sh
#   Batch assign takes SEVERAL shifts at once.
#
#   "Add shift" no longer writes and closes — it stages a shift in a list with
#   a remove control, the same add-then-delete cycle the per-scout dialog uses.
#   The footer button writes every staged shift for every selected scout.
#
#   Conflicts are skip-and-report, not all-or-nothing: a shift that clashes
#   with one scout's existing shift is skipped for that scout only, and the
#   dialog switches to a report naming who was skipped and why. One stray
#   shift on one person no longer blocks the other seven.
#
#   Overlaps *inside* the staged list are still refused outright — every
#   selected scout gets all of them, so a clash there is wrong for everyone.
#
# No schema change. `assignments.create` is untouched, so the per-scout
# "Assign matches" dialog keeps its abort-on-clash behaviour.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/admin/assign-dialog.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
runjs() { if command -v bun >/dev/null 2>&1; then bun "$1"; else node "$1"; fi; }

# --- 1. Convex: createMany --------------------------------------------------
say "Convex: assignments.createMany"
if grep -q "export const createMany" convex/assignments.ts; then
  echo "already patched"
else
  cat >> convex/assignments.ts <<'TS'

/**
 * Several shifts for several scouts in one pass.
 *
 * Unlike `create`, a clash does not abort the batch. The shift is skipped for
 * that one scout and reported back, because one person holding a stray shift
 * should not stop the other seven from being assigned. The caller is expected
 * to show the skips somewhere that stays on screen.
 *
 * Overlaps within `shifts` are a different matter — every scout gets all of
 * them, so a clash there is wrong for everyone and is refused outright.
 */
export const createMany = mutation({
  args: {
    profileIds: v.array(v.id("profiles")),
    shifts: v.array(v.object({
      fromMatch: v.number(),
      toMatch: v.number(),
      station,
    })),
  },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");
    if (args.profileIds.length === 0) throw new Error("Pick at least one scout.");
    if (args.shifts.length === 0) throw new Error("Add at least one shift.");

    const wanted = args.shifts
      .map((s) => ({
        fromMatch: Math.min(s.fromMatch, s.toMatch),
        toMatch: Math.max(s.fromMatch, s.toMatch),
        station: s.station,
      }))
      .sort((a, b) => a.fromMatch - b.fromMatch);

    for (const s of wanted) {
      if (!Number.isInteger(s.fromMatch) || s.fromMatch < 1) {
        throw new Error("Bad match range.");
      }
    }

    // Sorted, so each shift only has to clear the one before it.
    let previous: { fromMatch: number; toMatch: number } | null = null;
    for (const s of wanted) {
      if (previous && s.fromMatch <= previous.toMatch) {
        throw new Error(
          `Quals ${previous.fromMatch}–${previous.toMatch} and ${s.fromMatch}–${s.toMatch} overlap each other.`,
        );
      }
      previous = s;
    }

    const skipped: {
      displayName: string;
      fromMatch: number;
      toMatch: number;
      station: Station;
      reason: string;
    }[] = [];
    let created = 0;

    for (const profileId of args.profileIds) {
      const target = await ctx.db.get(profileId);
      if (!target) {
        for (const s of wanted) {
          skipped.push({ displayName: "A removed scout", ...s, reason: "no longer exists" });
        }
        continue;
      }
      if (!managesTeam(me, target.teamNumber)) {
        for (const s of wanted) {
          skipped.push({ displayName: target.displayName, ...s, reason: "is not on your team" });
        }
        continue;
      }

      const existing = await ctx.db
        .query("matchAssignments")
        .withIndex("by_event_profile", (q) =>
          q.eq("eventId", event._id).eq("profileId", profileId))
        .collect();

      // Grows as we insert, so two staged shifts cannot both land on the same
      // gap in one run.
      const held = existing.map((row) => ({
        fromMatch: row.fromMatch,
        toMatch: row.toMatch,
      }));

      for (const s of wanted) {
        const clash = held.find(
          (row) => s.fromMatch <= row.toMatch && s.toMatch >= row.fromMatch);
        if (clash) {
          skipped.push({
            displayName: target.displayName,
            ...s,
            reason: `already has quals ${clash.fromMatch}–${clash.toMatch}`,
          });
          continue;
        }

        await ctx.db.insert("matchAssignments", {
          eventId: event._id,
          profileId,
          teamNumber: target.teamNumber ?? 0,
          fromMatch: s.fromMatch,
          toMatch: s.toMatch,
          station: s.station,
          createdAt: Date.now(),
          createdBy: me.userId,
        });
        held.push({ fromMatch: s.fromMatch, toMatch: s.toMatch });
        created += 1;
      }
    }

    return {
      created,
      attempted: args.profileIds.length * wanted.length,
      skipped,
    };
  },
});
TS
  echo "convex/assignments.ts patched"
fi

# --- 2. Shift picker: keep the picker alive between adds --------------------
say "Shift picker: advanceOnAdd"
cat > /tmp/cs-shift-picker.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/components/shift-picker.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
if (s.includes("advanceOnAdd")) { console.log("already patched"); process.exit(0); }

const params = `export function ShiftPicker({
  maxMatch,
  busy,
  addLabel,
  onAdd,
}: {`;
if (!s.includes(params)) fail("could not find the ShiftPicker parameters");

const onAddType = `  onAdd: (shift: { fromMatch: number; toMatch: number; station: Station }) => void;
}) {`;
if (!s.includes(onAddType)) fail("could not find the onAdd prop type");

const click = `        onClick={() => {
          if (station === null) return;
          onAdd({
            fromMatch: Math.min(from, to),
            toMatch: Math.max(from, to),
            station,
          });
        }}>`;
if (!s.includes(click)) fail("could not find the add button handler");

s = s.replace(params, `export function ShiftPicker({
  maxMatch,
  busy,
  addLabel,
  onAdd,
  advanceOnAdd = false,
}: {`);

s = s.replace(onAddType, `  /** Returning false means it was refused, so the range stays put. */
  onAdd: (shift: { fromMatch: number; toMatch: number; station: Station }) => boolean | void;
  /** Staging several in a row: start the next where this one ended. */
  advanceOnAdd?: boolean;
}) {`);

s = s.replace(click, `        onClick={() => {
          if (station === null) return;
          const accepted = onAdd({
            fromMatch: Math.min(from, to),
            toMatch: Math.max(from, to),
            station,
          });
          if (advanceOnAdd && accepted !== false) {
            setFrom(clamp(Math.max(from, to) + 1));
            setTo(Math.max(1, maxMatch));
          }
        }}>`);

writeFileSync(p, s);
console.log("src/components/shift-picker.tsx patched");
MJS
runjs /tmp/cs-shift-picker.mjs
rm -f /tmp/cs-shift-picker.mjs

# --- 3. Assign dialogs: whole-file rewrite ----------------------------------
# Rewritten rather than patched: the batch dialog gains a staging list and a
# third step, which is most of the component.
say "Assign dialog: staged shifts and a skip report"
cat > src/routes/admin/assign-dialog.tsx <<'TSX'
import { useMutation, useQuery } from "convex/react";
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
  const matches = useQuery(api.matches.listForEvent);
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
  const shifts = useQuery(
    api.assignments.forProfile,
    profileId ? { profileId } : "skip",
  );
  const create = useMutation(api.assignments.create);
  const remove = useMutation(api.assignments.remove);
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
  const createMany = useMutation(api.assignments.createMany);
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
TSX
echo "src/routes/admin/assign-dialog.tsx rewritten"

say "Typecheck"
if command -v bun >/dev/null 2>&1; then
  bun run typecheck || echo "Typecheck reported issues — see above."
else
  npx tsc -b --noEmit || echo "Typecheck reported issues — see above."
fi
