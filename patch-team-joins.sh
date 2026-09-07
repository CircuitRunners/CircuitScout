#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-team-joins.sh — notify admins when someone joins or switches teams.
#
# A pending scout sorts to the top of the Scouts list with a red exclamation.
# Clicking it offers: accept onto this team, or send them back where they came
# from.
#
# SCHEMA CHANGE: teamJoins table.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/profiles.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema"
cat > /tmp/j1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("teamJoins")) { console.log("already patched"); process.exit(0); }
const anchor = "  events: defineTable({";
if (!s.includes(anchor)) fail("could not find the events table");
s = s.replace(anchor, `  /**
   * Someone claiming a team number. Recorded rather than applied silently:
   * a scout typing 1002 is asserting membership, and the team gets to decide.
   */
  teamJoins: defineTable({
    profileId: v.id("profiles"),
    userId: v.id("users"),
    displayName: v.string(),
    teamNumber: v.number(),
    previousTeamNumber: v.union(v.number(), v.null()),
    at: v.number(),
    status: v.union(v.literal("pending"), v.literal("accepted"), v.literal("rejected")),
  })
    .index("by_profile", ["profileId"])
    .index("by_team_status", ["teamNumber", "status"]),

${anchor}`);
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/j1.mjs

say "Profiles: record and resolve joins"
cat > /tmp/j2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/profiles.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("resolveJoin")) { console.log("already patched"); process.exit(0); }

// ensure(): log a join whenever the team number appears or changes
const oldExisting = `    if (existing) {
      await ctx.db.patch(existing._id, fields);
      return existing._id;
    }`;
if (!s.includes(oldExisting)) fail("could not find profiles.ensure");
s = s.replace(oldExisting, `    if (existing) {
      const changedTeam = existing.teamNumber !== fields.teamNumber;
      await ctx.db.patch(existing._id, fields);
      if (changedTeam) {
        await recordJoin(ctx, existing._id, userId, fields.displayName,
          fields.teamNumber, existing.teamNumber ?? null);
      }
      return existing._id;
    }`);

const oldInsert = `    const anyProfile = await ctx.db.query("profiles").first();
    return await ctx.db.insert("profiles", {
      userId,
      ...fields,
      role: anyProfile === null ? "admin" : "scout",
      weightTier: "normal",
      createdAt: Date.now(),
    });`;
if (!s.includes(oldInsert)) fail("could not find the profile insert");
s = s.replace(oldInsert, `    const anyProfile = await ctx.db.query("profiles").first();
    const profileId = await ctx.db.insert("profiles", {
      userId,
      ...fields,
      role: anyProfile === null ? "admin" : "scout",
      weightTier: "normal",
      createdAt: Date.now(),
    });
    // The very first account has nobody to approve it, so it is not pending.
    if (anyProfile !== null) {
      await recordJoin(ctx, profileId, userId, fields.displayName, fields.teamNumber, null);
    }
    return profileId;`);

s = s.replace("function validate(args: {", `/**
 * One pending row per profile. A scout who mistypes their number twice should
 * leave one thing to decide, not a queue.
 */
async function recordJoin(
  ctx: MutationCtx,
  profileId: Id<"profiles">,
  userId: Id<"users">,
  displayName: string,
  teamNumber: number,
  previousTeamNumber: number | null,
) {
  const prior = await ctx.db
    .query("teamJoins")
    .withIndex("by_profile", (q) => q.eq("profileId", profileId))
    .collect();
  for (const row of prior) {
    if (row.status === "pending") await ctx.db.delete(row._id);
  }
  await ctx.db.insert("teamJoins", {
    profileId, userId, displayName, teamNumber, previousTeamNumber,
    at: Date.now(),
    status: "pending",
  });
}

function validate(args: {`);

// list() carries the pending join so the UI can sort and flag
s = s.replace(`    const me = await requireTeamAdmin(ctx);
    const all = await ctx.db.query("profiles").collect();
    if (me.role === "admin") return all;
    // A team admin sees only their own scouts.
    return all.filter((p) => p.teamNumber === me.teamNumber);`,
`    const me = await requireTeamAdmin(ctx);
    const all = await ctx.db.query("profiles").collect();
    const scoped = me.role === "admin"
      ? all
      : all.filter((p) => p.teamNumber === me.teamNumber);

    return await Promise.all(scoped.map(async (profile) => {
      const pending = (
        await ctx.db
          .query("teamJoins")
          .withIndex("by_profile", (q) => q.eq("profileId", profile._id))
          .collect()
      ).find((row) => row.status === "pending");
      return {
        ...profile,
        pendingJoin: pending
          ? {
              joinId: pending._id,
              teamNumber: pending.teamNumber,
              previousTeamNumber: pending.previousTeamNumber,
              at: pending.at,
            }
          : null,
      };
    }));`);

s += `
/**
 * Accept the scout onto this team, or send them back where they came from.
 * Sending back with no previous team clears their team number, which drops
 * them at the profile screen to enter one again — no account is destroyed.
 */
export const resolveJoin = mutation({
  args: {
    joinId: v.id("teamJoins"),
    action: v.union(v.literal("accept"), v.literal("sendBack")),
  },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const join = await ctx.db.get(args.joinId);
    if (!join) throw new Error("That request no longer exists.");
    if (!managesTeam(me, join.teamNumber)) {
      throw new Error("That request is for another team.");
    }

    if (args.action === "accept") {
      await ctx.db.patch(args.joinId, { status: "accepted" });
      return { accepted: true };
    }

    await ctx.db.patch(join.profileId, {
      teamNumber: join.previousTeamNumber ?? undefined,
    });
    await ctx.db.patch(args.joinId, { status: "rejected" });
    return { accepted: false, sentBackTo: join.previousTeamNumber };
  },
});
`;

if (!s.includes("import type { MutationCtx }") && !s.includes("MutationCtx }")) {
  s = s.replace('import { internalQuery, mutation, query } from "./_generated/server";',
    'import { internalQuery, mutation, query } from "./_generated/server";\nimport type { MutationCtx } from "./_generated/server";\nimport type { Id } from "./_generated/dataModel";');
}

writeFileSync(p, s);
console.log("convex/profiles.ts patched");
MJS
bun /tmp/j2.mjs

say "Roles table (full rewrite)"
cat > src/routes/admin/roles-table.tsx <<'EOF'
import { useMutation, useQuery } from "convex/react";
import { TriangleAlert } from "lucide-react";
import { useMemo, useState } from "react";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
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

  const [open, setOpen] = useState<PendingJoin | null>(null);
  const [openName, setOpenName] = useState("");
  const [busy, setBusy] = useState(false);

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
          {profiles === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : (
            sorted.map((profile) => {
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
    </>
  );
}
EOF

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
