import { useMutation, useQuery } from "convex/react";
import { ChevronDown, TriangleAlert, Trash2, UserMinus, Users, X } from "lucide-react";
import { useMemo, useState } from "react";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import { AssignDialog, BatchAssignDialog } from "./assign-dialog";
import type { Id } from "../../../convex/_generated/dataModel";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import {
  Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { SCOUT_WEIGHTS } from "@/lib/scoring";
import type { Role, WeightTier } from "@/lib/types";

const ROLES: ReadonlyArray<{ value: Role; label: string }> = [
  { value: "scout", label: "Scout" },
  { value: "teamAdmin", label: "Team admin" },
  { value: "admin", label: "Admin" },
];

const TIERS: ReadonlyArray<{ value: WeightTier; label: string }> = [
  { value: "normal", label: "Normal" },
  { value: "trusted", label: "Trusted" },
  { value: "lead", label: "Strat lead" },
];

type PendingJoin = {
  joinId: string;
  teamNumber: number;
  previousTeamNumber: number | null;
  at: number;
};

export function RolesTable() {
  const profiles = useQuery(api.profiles.list);
  const me = useQuery(api.profiles.me);
  const setRole = useMutation(api.profiles.setRole);
  const setWeightTier = useMutation(api.profiles.setWeightTier);
  const resolveJoin = useMutation(api.profiles.resolveJoin);
  const departures = useQuery(api.profiles.departures);
  const dismissDeparture = useMutation(api.profiles.dismissDeparture);
  const deleteScout = useMutation(api.account.deleteScout);

  const [open, setOpen] = useState<PendingJoin | null>(null);
  const [openName, setOpenName] = useState("");
  const [busy, setBusy] = useState(false);

  const [teamFilter, setTeamFilter] = useState<number | "all">("all");
  const [pickerOpen, setPickerOpen] = useState(false);
  const [teamSearch, setTeamSearch] = useState("");

  const [manageOpen, setManageOpen] = useState(false);
  const [manageSearch, setManageSearch] = useState("");
  const [confirmName, setConfirmName] = useState("");
  const [targetId, setTargetId] = useState<string | null>(null);
  const [assignId, setAssignId] = useState<Id<"profiles"> | null>(null);
  const [assignName, setAssignName] = useState("");
  const [batchOpen, setBatchOpen] = useState(false);

  const adminCount = profiles?.filter((p) => p.role === "admin").length ?? 0;
  // Only a full admin grants roles. A team admin sets trust levels for their
  // own scouts and nothing else.
  const canSetRoles = me?.role === "admin";

  // Anyone waiting on a decision goes to the top — a request buried halfway
  // down an alphabetical list is a request nobody answers.
  const sorted = useMemo(() => {
    const rows = [...(profiles ?? [])];
    rows.sort((a, b) => {
      const ap = a.pendingJoin ? 0 : 1;
      const bp = b.pendingJoin ? 0 : 1;
      if (ap !== bp) return ap - bp;
      return a.displayName.localeCompare(b.displayName);
    });
    return rows;
  }, [profiles]);

  // Teams come from the scouts present, not from TBA — the filter should only
  // offer options that would actually show something.
  const teamCounts = useMemo(() => {
    const counts = new Map<number, number>();
    for (const profile of profiles ?? []) {
      if (profile.teamNumber === undefined) continue;
      counts.set(profile.teamNumber, (counts.get(profile.teamNumber) ?? 0) + 1);
    }
    return [...counts.entries()].sort((a, b) => a[0] - b[0]);
  }, [profiles]);

  const visible = useMemo(
    () => (teamFilter === "all"
      ? sorted
      : sorted.filter((p) => p.teamNumber === teamFilter)),
    [sorted, teamFilter],
  );

  const noTeamCount = (profiles ?? []).filter((p) => p.teamNumber === undefined).length;
  const pendingCount = sorted.filter((p) => p.pendingJoin).length;

  const changeRole = async (profileId: Id<"profiles">, role: Role, isSelf: boolean) => {
    if (role !== "admin" && adminCount <= 1) {
      const target = profiles?.find((p) => p._id === profileId);
      if (target?.role === "admin") {
        toast.error("That is the only admin", {
          description: "Promote someone else before stepping down.",
        });
        return;
      }
    }
    await setRole({ profileId, role });
    if (isSelf && role !== "admin") toast.warning("You are no longer an admin.");
  };

  const decide = async (action: "accept" | "sendBack") => {
    if (!open) return;
    setBusy(true);
    try {
      await resolveJoin({ joinId: open.joinId as Id<"teamJoins">, action });
      toast.success(
        action === "accept"
          ? `${openName} is on team ${open.teamNumber}`
          : open.previousTeamNumber === null
            ? `${openName} was removed from the team`
            : `${openName} was sent back to team ${open.previousTeamNumber}`,
      );
      setOpen(null);
    } catch (error) {
      toast.error("Could not do that", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <Card>
        <CardHeader>
          <CardTitle>
            Scouts
            {pendingCount > 0 ? (
              <Badge variant="destructive" className="ml-2">
                {pendingCount} waiting
              </Badge>
            ) : null}
          </CardTitle>
          <CardDescription>
            Trust level is yours to set for your own scouts. Roles are granted
            by a full admin. Weighting applies to the pick list merge: strat
            lead counts {SCOUT_WEIGHTS.lead}×, trusted {SCOUT_WEIGHTS.trusted}×,
            normal {SCOUT_WEIGHTS.normal}×.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {/* Assigning shifts is a team admin's job. Filtering across teams and
              deleting accounts are not, so those stay above. */}
          <div className="flex gap-2">
            <Button variant="outline" onClick={() => setBatchOpen(true)}>
              Batch assign shifts
            </Button>
          </div>

          {canSetRoles && teamCounts.length > 0 ? (
            <div className="space-y-2">
              <div className="flex gap-2">
              <Button variant="outline" className="flex-1 justify-between"
                onClick={() => setPickerOpen(!pickerOpen)}>
                {teamFilter === "all" ? "All teams" : `Team ${teamFilter}`}
                <ChevronDown className={`size-4 transition-transform ${pickerOpen ? "rotate-180" : ""}`} />
              </Button>
              <Button variant="outline" onClick={() => setManageOpen(true)}>
                <Users className="size-4" /> Manage scouts
              </Button>
              </div>

              {pickerOpen ? (
                <div className="space-y-1 rounded-lg border p-2">
                  <Input autoFocus placeholder="Find a team number"
                    inputMode="numeric" value={teamSearch}
                    onChange={(e) => setTeamSearch(e.target.value)} />
                  <div className="max-h-56 space-y-1 overflow-y-auto">
                    <Button variant={teamFilter === "all" ? "default" : "ghost"}
                      className="w-full justify-between"
                      onClick={() => {
                        setTeamFilter("all");
                        setPickerOpen(false);
                        setTeamSearch("");
                      }}>
                      All
                      <span className="text-muted-foreground text-xs tabular-nums">
                        {(profiles ?? []).length}
                      </span>
                    </Button>
                    {teamCounts
                      .filter(([number]) =>
                        teamSearch.trim() === "" ||
                        String(number).includes(teamSearch.trim()))
                      .map(([number, count]) => (
                        <Button key={number}
                          variant={teamFilter === number ? "default" : "ghost"}
                          className="w-full justify-between"
                          onClick={() => {
                            setTeamFilter(number);
                            setPickerOpen(false);
                            setTeamSearch("");
                          }}>
                          {number}
                          <span className="text-muted-foreground text-xs tabular-nums">
                            {count}
                          </span>
                        </Button>
                      ))}
                  </div>
                  {noTeamCount > 0 ? (
                    <p className="text-muted-foreground px-2 pt-1 text-xs">
                      {noTeamCount} scout{noTeamCount === 1 ? "" : "s"} have no team
                      number and only appear under All.
                    </p>
                  ) : null}
                </div>
              ) : null}
            </div>
          ) : null}

          {(departures ?? []).map((row) => (
            <div key={row._id}
              className="bg-muted/50 flex flex-wrap items-center gap-2 rounded-lg border p-3 text-sm">
              <UserMinus className="text-muted-foreground size-4 shrink-0" />
              <span className="min-w-0 flex-1">
                <span className="font-medium">{row.displayName}</span> left for
                team {row.toTeamNumber}. Anything they scouted for you stays.
              </span>
              <Button size="icon" variant="ghost" aria-label="Dismiss"
                onClick={() => void dismissDeparture({ departureId: row._id })}>
                <X className="size-4" />
              </Button>
            </div>
          ))}

          {profiles === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : (
            visible.map((profile) => {
              const isSelf = me?._id === profile._id;
              const pending = profile.pendingJoin as PendingJoin | null;
              return (
                <div key={profile._id}
                  className={[
                    "flex flex-wrap items-center gap-3 rounded-lg border p-3",
                    pending ? "border-destructive" : "",
                  ].join(" ")}>
                  {pending ? (
                    <Button size="icon" variant="ghost"
                      aria-label={`Review ${profile.displayName}'s team request`}
                      onClick={() => { setOpen(pending); setOpenName(profile.displayName); }}>
                      <TriangleAlert className="text-destructive size-4" />
                    </Button>
                  ) : null}

                  <span className="min-w-0 flex-1 truncate text-sm font-medium">
                    {profile.displayName}
                    {isSelf ? (
                      <span className="text-muted-foreground font-normal"> (you)</span>
                    ) : null}
                  </span>

                  <Button size="sm" variant="outline"
                    onClick={() => {
                      setAssignId(profile._id);
                      setAssignName(profile.displayName);
                    }}>
                    Assign matches
                  </Button>

                  {canSetRoles ? (
                    <div className="flex gap-1">
                      {ROLES.map((r) => (
                        <Button key={r.value} size="sm"
                          variant={profile.role === r.value ? "default" : "outline"}
                          onClick={() => void changeRole(profile._id, r.value, isSelf)}>
                          {r.label}
                        </Button>
                      ))}
                    </div>
                  ) : (
                    <Badge variant="secondary">
                      {ROLES.find((r) => r.value === profile.role)?.label ?? "Scout"}
                    </Badge>
                  )}

                  <div className="flex gap-1">
                    {TIERS.map((t) => (
                      <Button key={t.value} size="sm"
                        variant={profile.weightTier === t.value ? "secondary" : "ghost"}
                        onClick={() =>
                          void setWeightTier({ profileId: profile._id, weightTier: t.value })}>
                        {t.label}
                      </Button>
                    ))}
                  </div>
                </div>
              );
            })
          )}
        </CardContent>
      </Card>

      <Dialog open={open !== null} onOpenChange={(next) => { if (!next) setOpen(null); }}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{openName} wants to join team {open?.teamNumber}</DialogTitle>
            <DialogDescription>
              {open?.previousTeamNumber === null
                ? "This is a new account claiming your team number."
                : `They were on team ${open?.previousTeamNumber}.`}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <p className="text-muted-foreground text-sm">
              Accepting lets them scout under your team and their lists count in
              your merge. Sending them back does not delete anything they have
              already written.
            </p>
            <div className="flex flex-wrap gap-2">
              <Button disabled={busy} onClick={() => void decide("accept")}>
                Accept onto team {open?.teamNumber}
              </Button>
              <Button variant="outline" disabled={busy}
                onClick={() => void decide("sendBack")}>
                {open?.previousTeamNumber === null
                  ? "Remove from team"
                  : `Send back to ${open?.previousTeamNumber}`}
              </Button>
            </div>
          </div>
        </DialogContent>
      </Dialog>
      <Dialog open={manageOpen} onOpenChange={(next) => {
        if (!next) { setManageOpen(false); setTargetId(null); setConfirmName(""); }
      }}>
        <DialogContent className="max-h-[80vh] max-w-lg overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Manage scouts</DialogTitle>
            <DialogDescription>
              Deleting a scout removes their sign-in. Everything they scouted
              stays, attributed to a name that no longer resolves.
            </DialogDescription>
          </DialogHeader>

          <Input placeholder="Find a scout" value={manageSearch}
            onChange={(e) => setManageSearch(e.target.value)} />

          <div className="space-y-2">
            {(profiles ?? [])
              .filter((profile) =>
                manageSearch.trim() === "" ||
                profile.displayName.toLowerCase().includes(manageSearch.trim().toLowerCase()))
              .map((profile) => (
                <div key={profile._id} className="space-y-2 rounded-lg border p-3">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="min-w-0 flex-1 truncate text-sm font-medium">
                      {profile.displayName}
                    </span>
                    {profile.role === "admin" ? (
                      <Badge variant="secondary">Admin</Badge>
                    ) : (
                      <Button size="sm" variant="destructive"
                        onClick={() => {
                          setTargetId(targetId === profile._id ? null : profile._id);
                          setConfirmName("");
                        }}>
                        <Trash2 className="size-3" /> Delete
                      </Button>
                    )}
                  </div>

                  {targetId === profile._id ? (
                    <div className="space-y-2 rounded-md border border-dashed p-3">
                      <p className="text-destructive text-xs">
                        This removes their account permanently.
                      </p>
                      <Input placeholder={`Type ${profile.displayName} to confirm`}
                        value={confirmName}
                        onChange={(e) => setConfirmName(e.target.value)} />
                      <Button size="sm" variant="destructive"
                        disabled={busy || confirmName.trim() !== profile.displayName}
                        onClick={() => {
                          setBusy(true);
                          void deleteScout({ profileId: profile._id })
                            .then((r) => {
                              toast.success(`${r.displayName} deleted`);
                              setTargetId(null);
                              setConfirmName("");
                            })
                            .catch((error: unknown) =>
                              toast.error("Could not delete", {
                                description:
                                  error instanceof Error ? error.message : String(error),
                              }))
                            .finally(() => setBusy(false));
                        }}>
                        Delete permanently
                      </Button>
                    </div>
                  ) : null}
                </div>
              ))}
          </div>
        </DialogContent>
      </Dialog>
      <AssignDialog profileId={assignId} displayName={assignName}
        onClose={() => setAssignId(null)} />

      <BatchAssignDialog open={batchOpen} profiles={sorted}
        onClose={() => setBatchOpen(false)} />
    </>
  );
}

