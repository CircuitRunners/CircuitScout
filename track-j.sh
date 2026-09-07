#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# track-j.sh — Track J: match assignments.
#   Admin: per-scout and batch shift assignment
#   Scout: shifts on the dashboard, highlights in match scouting
# SCHEMA CHANGE: matchAssignments table.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/lib/types.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
mkdir -p convex src/components src/routes/admin

say "Types and schema"
cat > /tmp/j1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

let t = readFileSync("convex/lib/types.ts", "utf8");
if (!t.includes("Station")) {
  t += `
export type Station =
  | "red1" | "red2" | "red3"
  | "blue1" | "blue2" | "blue3";

export const STATIONS: ReadonlyArray<Station> = [
  "red1", "red2", "red3", "blue1", "blue2", "blue3",
];

export const STATION_LABELS: Record<Station, string> = {
  red1: "Red 1", red2: "Red 2", red3: "Red 3",
  blue1: "Blue 1", blue2: "Blue 2", blue3: "Blue 3",
};

export function stationAlliance(station: Station): "red" | "blue" {
  return station.startsWith("red") ? "red" : "blue";
}

/** 0-based position within that alliance's three teams. */
export function stationIndex(station: Station): number {
  return Number.parseInt(station.slice(-1), 10) - 1;
}
`;
  writeFileSync("convex/lib/types.ts", t);
  console.log("convex/lib/types.ts patched");
}

let s = readFileSync("convex/schema.ts", "utf8");
if (s.includes("matchAssignments")) { console.log("schema already patched"); process.exit(0); }
const anchor = "  pitReports: defineTable({";
if (!s.includes(anchor)) fail("could not find pitReports");
s = s.replace(anchor, `  /**
   * A shift: watch this driver station for this run of matches. Ranges store
   * match NUMBERS, so re-importing a revised schedule moves shifts with it.
   */
  matchAssignments: defineTable({
    eventId: v.id("events"),
    profileId: v.id("profiles"),
    teamNumber: v.number(),
    fromMatch: v.number(),
    toMatch: v.number(),
    station: v.union(
      v.literal("red1"), v.literal("red2"), v.literal("red3"),
      v.literal("blue1"), v.literal("blue2"), v.literal("blue3"),
    ),
    createdAt: v.number(),
    createdBy: v.id("users"),
  })
    .index("by_event_profile", ["eventId", "profileId"])
    .index("by_event_team", ["eventId", "teamNumber"]),

${anchor}`);
writeFileSync("convex/schema.ts", s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/j1.mjs

say "Convex: assignments"
cat > convex/assignments.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import {
  activeEvent, currentProfile, managesTeam, requireTeamAdmin, requireUser,
} from "./lib/guards";
import { stationIndex, type Station } from "./lib/types";

const station = v.union(
  v.literal("red1"), v.literal("red2"), v.literal("red3"),
  v.literal("blue1"), v.literal("blue2"), v.literal("blue3"),
);

/** Which team number sits in that station for that match. */
function teamAt(
  match: { redTeamNumbers: number[]; blueTeamNumbers: number[] },
  s: Station,
): number | null {
  const list = s.startsWith("red") ? match.redTeamNumbers : match.blueTeamNumbers;
  return list[stationIndex(s)] ?? null;
}

export const forProfile = query({
  args: { profileId: v.id("profiles") },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) return [];

    const target = await ctx.db.get(args.profileId);
    if (!target || !managesTeam(me, target.teamNumber)) return [];

    const rows = await ctx.db
      .query("matchAssignments")
      .withIndex("by_event_profile", (q) =>
        q.eq("eventId", event._id).eq("profileId", args.profileId))
      .collect();
    return rows.sort((a, b) => a.fromMatch - b.fromMatch);
  },
});

/**
 * Creates one shift per selected scout. Overlaps are refused and the message
 * names the shift in the way — "overlaps an existing shift" leaves an admin
 * hunting through a list on a phone.
 */
export const create = mutation({
  args: {
    profileIds: v.array(v.id("profiles")),
    fromMatch: v.number(),
    toMatch: v.number(),
    station,
  },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const from = Math.min(args.fromMatch, args.toMatch);
    const to = Math.max(args.fromMatch, args.toMatch);
    if (!Number.isInteger(from) || from < 1) throw new Error("Bad match range.");

    for (const profileId of args.profileIds) {
      const target = await ctx.db.get(profileId);
      if (!target) throw new Error("That scout no longer exists.");
      if (!managesTeam(me, target.teamNumber)) {
        throw new Error(`${target.displayName} is not on your team.`);
      }

      const existing = await ctx.db
        .query("matchAssignments")
        .withIndex("by_event_profile", (q) =>
          q.eq("eventId", event._id).eq("profileId", profileId))
        .collect();

      // One scout cannot be in two places, whatever the stations. Switching
      // station mid-event means ending one shift and starting another.
      const clash = existing.find((row) => from <= row.toMatch && to >= row.fromMatch);
      if (clash) {
        throw new Error(
          `${target.displayName} already has quals ${clash.fromMatch}–${clash.toMatch}. End that shift first.`,
        );
      }

      await ctx.db.insert("matchAssignments", {
        eventId: event._id,
        profileId,
        teamNumber: target.teamNumber ?? 0,
        fromMatch: from,
        toMatch: to,
        station: args.station,
        createdAt: Date.now(),
        createdBy: me.userId,
      });
    }

    return { created: args.profileIds.length };
  },
});

export const remove = mutation({
  args: { assignmentId: v.id("matchAssignments") },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const row = await ctx.db.get(args.assignmentId);
    if (!row) return;
    if (!managesTeam(me, row.teamNumber)) {
      throw new Error("That shift is for another team.");
    }
    await ctx.db.delete(args.assignmentId);
  },
});

/** The signed-in scout's own shifts, with progress and what is next. */
export const mine = query({
  args: {},
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);
    const event = await activeEvent(ctx);
    if (!profile || !event) return { shifts: [], upNext: null, assigned: [] };

    const rows = await ctx.db
      .query("matchAssignments")
      .withIndex("by_event_profile", (q) =>
        q.eq("eventId", event._id).eq("profileId", profile._id))
      .collect();

    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const byNumber = new Map(matches.map((m) => [m.matchNumber, m]));

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const teamByNumber = new Map(teams.map((t) => [t.number, t]));

    const myReports = await ctx.db
      .query("matchReports")
      .withIndex("by_scout", (q) => q.eq("scoutId", userId))
      .collect();
    const reportedMatchNumbers = new Set(
      myReports.flatMap((r) => {
        const match = matches.find((m) => m._id === r.matchId);
        return match ? [match.matchNumber] : [];
      }),
    );

    // "Current" is the furthest match anyone has scouted. Distance is measured
    // in matches rather than minutes: scheduled times drift during an event
    // and only refresh on re-import, so a countdown would be confidently wrong.
    const allReports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    let current = 0;
    for (const report of allReports) {
      const match = matches.find((m) => m._id === report.matchId);
      if (match && match.matchNumber > current) current = match.matchNumber;
    }

    const shifts = rows
      .sort((a, b) => a.fromMatch - b.fromMatch)
      .map((row) => {
        let total = 0;
        let done = 0;
        for (let n = row.fromMatch; n <= row.toMatch; n++) {
          if (!byNumber.has(n)) continue;
          total += 1;
          if (reportedMatchNumbers.has(n)) done += 1;
        }
        return {
          assignmentId: row._id,
          fromMatch: row.fromMatch,
          toMatch: row.toMatch,
          station: row.station,
          done,
          total,
        };
      });

    // Every assigned match number, so the scouting list can highlight them.
    const assigned: { matchNumber: number; station: Station; teamNumber: number | null }[] = [];
    for (const row of rows) {
      for (let n = row.fromMatch; n <= row.toMatch; n++) {
        const match = byNumber.get(n);
        if (!match) continue;
        assigned.push({
          matchNumber: n,
          station: row.station,
          teamNumber: teamAt(match, row.station),
        });
      }
    }
    assigned.sort((a, b) => a.matchNumber - b.matchNumber);

    const next = assigned.find(
      (a) => !reportedMatchNumbers.has(a.matchNumber) && a.matchNumber > current,
    ) ?? assigned.find((a) => !reportedMatchNumbers.has(a.matchNumber)) ?? null;

    const upNext = next
      ? {
          matchNumber: next.matchNumber,
          station: next.station,
          teamNumber: next.teamNumber,
          nickname: next.teamNumber
            ? (teamByNumber.get(next.teamNumber)?.nickname ?? null)
            : null,
          matchesAway: Math.max(0, next.matchNumber - current),
        }
      : null;

    return { shifts, upNext, assigned };
  },
});
EOF

say "Client: shift picker"
cat > src/components/shift-picker.tsx <<'EOF'
import { useState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Slider } from "@/components/ui/slider";
import { STATIONS, STATION_LABELS, stationAlliance, type Station } from "@/lib/types";

/**
 * Range plus driver station. The slider is the fast path; the two number
 * inputs beneath it are the reliable one — a two-handle slider is fiddly with
 * gloves on, and typing "12" and "34" always works.
 */
export function ShiftPicker({
  maxMatch,
  busy,
  addLabel,
  onAdd,
}: {
  maxMatch: number;
  busy: boolean;
  addLabel: string;
  onAdd: (shift: { fromMatch: number; toMatch: number; station: Station }) => void;
}) {
  const [from, setFrom] = useState(1);
  const [to, setTo] = useState(Math.max(1, maxMatch));
  const [station, setStation] = useState<Station | null>(null);

  const clamp = (n: number) => Math.min(Math.max(1, n), Math.max(1, maxMatch));

  const handleSlider = (next: number | readonly number[]) => {
    if (typeof next === "number") { setFrom(clamp(next)); return; }
    setFrom(clamp(next[0] ?? 1));
    setTo(clamp(next[1] ?? maxMatch));
  };

  return (
    <div className="space-y-4">
      <div>
        <div className="flex items-baseline justify-between">
          <span className="text-sm font-medium">Match range</span>
          <span className="text-sm font-semibold tabular-nums">
            Qual {Math.min(from, to)} – {Math.max(from, to)}
          </span>
        </div>
        <Slider
          className="py-3"
          min={1}
          max={Math.max(1, maxMatch)}
          step={1}
          value={[from, to]}
          onValueChange={handleSlider}
        />
        <div className="text-muted-foreground flex justify-between text-xs tabular-nums">
          <span>1</span>
          <span>{maxMatch}</span>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-2">
        <div className="space-y-1">
          <Label htmlFor="from-match" className="text-xs">From</Label>
          <Input id="from-match" inputMode="numeric" value={String(from)}
            onChange={(e) => setFrom(clamp(Number.parseInt(e.target.value, 10) || 1))} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="to-match" className="text-xs">To</Label>
          <Input id="to-match" inputMode="numeric" value={String(to)}
            onChange={(e) => setTo(clamp(Number.parseInt(e.target.value, 10) || 1))} />
        </div>
      </div>

      <div className="space-y-2">
        <span className="text-sm font-medium">Driver station</span>
        <div className="grid grid-cols-3 gap-2">
          {STATIONS.map((s) => {
            const red = stationAlliance(s) === "red";
            const selected = station === s;
            return (
              <Button key={s} variant={selected ? "default" : "outline"}
                className={[
                  "h-11",
                  selected
                    ? red ? "bg-red-600 hover:bg-red-600" : "bg-blue-600 hover:bg-blue-600"
                    : red ? "text-red-600 dark:text-red-400" : "text-blue-600 dark:text-blue-400",
                ].join(" ")}
                onClick={() => setStation(s)}>
                {STATION_LABELS[s]}
              </Button>
            );
          })}
        </div>
      </div>

      <Button className="w-full" disabled={busy || station === null}
        onClick={() => {
          if (station === null) return;
          onAdd({
            fromMatch: Math.min(from, to),
            toMatch: Math.max(from, to),
            station,
          });
        }}>
        {addLabel}
      </Button>
    </div>
  );
}

export function ShiftRow({
  fromMatch, toMatch, station, trailing, onRemove,
}: {
  fromMatch: number;
  toMatch: number;
  station: Station;
  trailing?: string;
  onRemove?: () => void;
}) {
  const red = stationAlliance(station) === "red";
  return (
    <div className={[
      "flex items-center gap-2 rounded-r-lg border-l-[3px] py-2 pr-2 pl-3 text-sm",
      red ? "border-red-600 bg-red-500/10" : "border-blue-600 bg-blue-500/10",
    ].join(" ")}>
      <span className="flex-1 tabular-nums">Qual {fromMatch} – {toMatch}</span>
      <span className={[
        "text-xs font-medium",
        red ? "text-red-600 dark:text-red-400" : "text-blue-600 dark:text-blue-400",
      ].join(" ")}>
        {STATION_LABELS[station]}
      </span>
      {trailing ? (
        <span className="text-muted-foreground text-xs tabular-nums">{trailing}</span>
      ) : null}
      {onRemove ? (
        <Button size="icon" variant="ghost" aria-label="Remove shift" onClick={onRemove}>
          <span aria-hidden="true">×</span>
        </Button>
      ) : null}
    </div>
  );
}
EOF

say "Client: assignment dialogs"
cat > src/routes/admin/assign-dialog.tsx <<'EOF'
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
EOF

say "Roles table: buttons"
cat > /tmp/j2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/roles-table.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("AssignDialog")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { api } from "../../../convex/_generated/api";',
  'import { api } from "../../../convex/_generated/api";\nimport { AssignDialog, BatchAssignDialog } from "./assign-dialog";');
s = s.replace("  const [targetId, setTargetId] = useState<string | null>(null);",
`  const [targetId, setTargetId] = useState<string | null>(null);
  const [assignId, setAssignId] = useState<Id<"profiles"> | null>(null);
  const [assignName, setAssignName] = useState("");
  const [batchOpen, setBatchOpen] = useState(false);`);

// batch button next to Manage scouts
s = s.replace(`              <Button variant="outline" onClick={() => setManageOpen(true)}>
                <Users className="size-4" /> Manage scouts
              </Button>`,
`              <Button variant="outline" onClick={() => setManageOpen(true)}>
                <Users className="size-4" /> Manage scouts
              </Button>
              <Button variant="outline" onClick={() => setBatchOpen(true)}>
                Batch assign shifts
              </Button>`);

// per-scout button, left of the role controls
// The role controls have two shapes depending on which patches landed.
const assignButton = `                  <Button size="sm" variant="outline"
                    onClick={() => {
                      setAssignId(profile._id);
                      setAssignName(profile.displayName);
                    }}>
                    Assign matches
                  </Button>

`;
const roleAnchors = [
  `                  {canSetRoles ? (\n                    <div className="flex gap-1">`,
  `                <div className="flex gap-1">\n                  {ROLES.map((r) => (`,
];
const roleAnchor = roleAnchors.find((a) => s.includes(a));
if (roleAnchor) {
  s = s.replace(roleAnchor, assignButton + roleAnchor);
} else {
  console.log("  WARNING: could not place the per-scout Assign button.");
  console.log("  Add it by hand in roles-table.tsx, before the role buttons:");
  console.log(assignButton.trim());
}

const dialogs = `      <AssignDialog profileId={assignId} displayName={assignName}
        onClose={() => setAssignId(null)} />

      <BatchAssignDialog open={batchOpen} profiles={sorted}
        onClose={() => setBatchOpen(false)} />
`;
const closeAnchor = `    </>
  );
}`;
if (s.includes(closeAnchor)) {
  s = s.replace(closeAnchor, dialogs + closeAnchor);
} else {
  console.log("  WARNING: could not place the assignment dialogs. Add these");
  console.log("  just before the closing </> of RolesTable:");
  console.log(dialogs.trim());
}

writeFileSync(p, s);
console.log("src/routes/admin/roles-table.tsx patched");
MJS
bun /tmp/j2.mjs

say "Dashboard and match scouting"
cat > /tmp/j3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

// --- dashboard ---
let d = readFileSync("src/routes/dashboard.tsx", "utf8");
if (!d.includes("assignments.mine")) {
  d = d.replace('import { api } from "../../convex/_generated/api";',
    'import { api } from "../../convex/_generated/api";\nimport { ShiftRow } from "@/components/shift-picker";\nimport { STATION_LABELS, type Station } from "@/lib/types";');
  d = d.replace("  const matches = useQuery(api.matches.listForEvent);",
    "  const matches = useQuery(api.matches.listForEvent);\n  const assignments = useQuery(api.assignments.mine);");

  const anchor = `      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">`;
  if (!d.includes(anchor)) fail("could not find the dashboard metrics");
  d = d.replace(anchor, `      {assignments?.upNext ? (
        <Card>
          <CardHeader>
            <CardDescription>Up next</CardDescription>
            <CardTitle className="flex flex-wrap items-baseline gap-3">
              <span className="text-3xl tabular-nums">
                Qual {assignments.upNext.matchNumber}
              </span>
              <span className={[
                "rounded-md px-2 py-1 text-xs font-medium text-white",
                assignments.upNext.station.startsWith("red") ? "bg-red-600" : "bg-blue-600",
              ].join(" ")}>
                {STATION_LABELS[assignments.upNext.station as Station]}
              </span>
            </CardTitle>
          </CardHeader>
          <CardContent className="-mt-4 space-y-3">
            <p className="text-muted-foreground text-sm">
              {assignments.upNext.teamNumber === null ? (
                "That station has no team in the imported schedule."
              ) : (
                <>
                  Team{" "}
                  <span className="text-foreground font-medium tabular-nums">
                    {assignments.upNext.teamNumber}
                  </span>
                  {assignments.upNext.nickname ? \` · \${assignments.upNext.nickname}\` : ""}
                  {" · "}
                  {assignments.upNext.matchesAway === 0
                    ? "now"
                    : \`\${assignments.upNext.matchesAway} match\${assignments.upNext.matchesAway === 1 ? "" : "es"} away\`}
                </>
              )}
            </p>
            {assignments.upNext.teamNumber !== null ? (
              <Button variant="secondary"
                render={<Link to={\`/scout/\${assignments.upNext.matchNumber}/\${assignments.upNext.teamNumber}\`} />}>
                Scout this robot
              </Button>
            ) : null}
          </CardContent>
        </Card>
      ) : null}

      {(assignments?.shifts ?? []).length > 0 ? (
        <Card>
          <CardHeader>
            <CardTitle>Your shifts</CardTitle>
            <CardDescription>
              Progress counts reports you have submitted in each range.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-2">
            {(assignments?.shifts ?? []).map((shift) => (
              <ShiftRow key={shift.assignmentId}
                fromMatch={shift.fromMatch} toMatch={shift.toMatch}
                station={shift.station as Station}
                trailing={\`\${shift.done} of \${shift.total}\`} />
            ))}
          </CardContent>
        </Card>
      ) : null}

${anchor}`);
  writeFileSync("src/routes/dashboard.tsx", d);
  console.log("src/routes/dashboard.tsx patched");
}

// --- match scouting list ---
let s = readFileSync("src/routes/scout/index.tsx", "utf8");
if (s.includes("assignments.mine")) { console.log("scout list already patched"); process.exit(0); }

s = s.replace('import { PageShell } from "@/routes/page-shell";',
  'import { PageShell } from "@/routes/page-shell";\nimport { STATION_LABELS, type Station } from "@/lib/types";');

s = s.replace("function MatchRobots({\n  matchNumber,\n  highlight,\n}: {\n  matchNumber: number;\n  highlight: number | null;\n}) {",
`function MatchRobots({
  matchNumber,
  highlight,
  assignedTeam,
}: {
  matchNumber: number;
  highlight: number | null;
  assignedTeam: number | null;
}) {`);

const oldClass = `                className={[
                  "flex min-h-14 w-full items-center gap-2 rounded-md border p-3 text-left transition-colors",
                  team.number === highlight
                    ? "border-primary bg-primary/10"
                    : "hover:bg-accent/50",
                ].join(" ")}`;
if (!s.includes(oldClass)) fail("could not find the robot button class");
s = s.replace(oldClass, `                className={[
                  "flex min-h-14 w-full items-center gap-2 rounded-md border p-3 text-left transition-colors",
                  team.number === assignedTeam
                    ? "border-2 border-green-500 bg-green-500/10"
                    : team.number === highlight
                      ? "border-primary bg-primary/10"
                      : "hover:bg-accent/50",
                ].join(" ")}`);

s = s.replace(`                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {team.nickname}
                </span>`,
`                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {team.number === assignedTeam ? "yours" : team.nickname}
                </span>`);

s = s.replace("  const [matchSearch, setMatchSearch] = useState(\"\");",
`  const [matchSearch, setMatchSearch] = useState("");
  const assignments = useQuery(api.assignments.mine);
  const assignedByMatch = new Map(
    (assignments?.assigned ?? []).map((a) => [a.matchNumber, a]),
  );`);

s = s.replace(`              <button
                onClick={() =>
                  setOpen(expanded === match.matchNumber ? null : match.matchNumber)
                }
                className="hover:bg-accent/50 flex min-h-14 w-full items-center gap-3 p-3 text-left transition-colors"
              >
                <span className="font-medium">Qual {match.matchNumber}</span>`,
`              <button
                onClick={() =>
                  setOpen(expanded === match.matchNumber ? null : match.matchNumber)
                }
                className="hover:bg-accent/50 flex min-h-14 w-full items-center gap-3 p-3 text-left transition-colors"
              >
                <span className="font-medium">Qual {match.matchNumber}</span>
                {assignedByMatch.has(match.matchNumber) ? (
                  <span className={[
                    "shrink-0 rounded px-1.5 py-0.5 text-[11px] font-medium text-white",
                    assignedByMatch.get(match.matchNumber)!.station.startsWith("red")
                      ? "bg-red-600" : "bg-blue-600",
                  ].join(" ")}>
                    {STATION_LABELS[assignedByMatch.get(match.matchNumber)!.station as Station]} · yours
                  </span>
                ) : null}`);

s = s.replace(`            <div key={match._id} className="rounded-lg border">`,
`            <div key={match._id} className={[
              "rounded-lg border",
              assignedByMatch.has(match.matchNumber)
                ? "border-2 border-green-500 bg-green-500/5"
                : "",
            ].join(" ")}>`);

s = s.replace(`                <MatchRobots matchNumber={match.matchNumber} highlight={highlight} />`,
`                <MatchRobots matchNumber={match.matchNumber} highlight={highlight}
                  assignedTeam={assignedByMatch.get(match.matchNumber)?.teamNumber ?? null} />`);

writeFileSync("src/routes/scout/index.tsx", s);
console.log("src/routes/scout/index.tsx patched");
MJS
bun /tmp/j3.mjs
rm -f /tmp/j1.mjs /tmp/j2.mjs /tmp/j3.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
