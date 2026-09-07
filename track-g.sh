#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# track-g.sh — Track G: weighted consensus merge.
# Owns convex/lib/consensus.ts, convex/merge.ts, src/lib/consensus.ts,
# src/routes/admin/merge.tsx. No schema change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/pickLists.ts ]] || { echo "ERROR: run track-f.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
mkdir -p convex/lib src/lib src/routes/admin

say "Consensus maths"
cat > convex/lib/consensus.ts <<'EOF'
import { SCOUT_WEIGHTS, TIER_BASE, TIER_POSITION_BAND } from "./scoring";
import type { Tier, WeightTier } from "./types";

export type Vote = {
  voter: string;
  weightTier: WeightTier;
  tier: Exclude<Tier, "uncategorized">;
  /** 0-based position within its column. */
  index: number;
  columnSize: number;
  note: string;
};

/**
 * A vote's score. Position inside a column moves the score within a band that
 * can never reach the next tier's base, so "bottom of first pick" always beats
 * "top of second pick" — which is what a tiered list means.
 *
 * Do-not-pick is flat: ordering within it carries no information.
 */
export function scoreVote(vote: Pick<Vote, "tier" | "index" | "columnSize">): number {
  const base = TIER_BASE[vote.tier];
  if (vote.tier === "dnp") return base;
  const size = Math.max(1, vote.columnSize);
  return base + (TIER_POSITION_BAND * (size - vote.index)) / size;
}

export type Consensus = {
  score: number;
  voters: number;
  /** Unweighted, deliberately — see below. */
  spread: number;
  dnpCount: number;
  highest: number;
  lowest: number;
};

export function consensus(votes: Vote[]): Consensus {
  if (votes.length === 0) {
    return { score: 0, voters: 0, spread: 0, dnpCount: 0, highest: 0, lowest: 0 };
  }

  const scores = votes.map(scoreVote);
  const weights = votes.map((v) => SCOUT_WEIGHTS[v.weightTier]);
  const totalWeight = weights.reduce((a, b) => a + b, 0);

  const score =
    totalWeight === 0
      ? 0
      : scores.reduce((sum, s, i) => sum + s * (weights[i] ?? 1), 0) / totalWeight;

  // Spread stays UNWEIGHTED. It exists to show whether the room disagrees, and
  // weighting it would let one heavy vote hide exactly the disagreement the
  // number is there to surface.
  const mean = scores.reduce((a, b) => a + b, 0) / scores.length;
  const spread = Math.sqrt(
    scores.reduce((sum, s) => sum + (s - mean) ** 2, 0) / scores.length,
  );

  return {
    score,
    voters: votes.length,
    spread,
    dnpCount: votes.filter((v) => v.tier === "dnp").length,
    highest: Math.max(...scores),
    lowest: Math.min(...scores),
  };
}

/**
 * Turns a ranking into tiers by preserving how many teams the contributing
 * scouts put in each tier on average. Thresholding on raw score would let the
 * merge invent twenty first picks out of lists that each named three.
 */
export function assignTiers(
  ranked: { teamId: string; consensus: Consensus }[],
  targets: { t1: number; t2: number; t3: number },
): Map<string, Tier> {
  const out = new Map<string, Tier>();
  let i = 0;

  // Anyone with a do-not-pick vote and a negative consensus is set aside first,
  // so a veto is never silently averaged into a middling rank.
  const vetoed = ranked.filter((r) => r.consensus.dnpCount > 0 && r.consensus.score < 0);
  for (const row of vetoed) out.set(row.teamId, "dnp");

  const rest = ranked.filter((r) => !out.has(r.teamId));
  for (const [tier, count] of [
    ["t1", targets.t1] as const,
    ["t2", targets.t2] as const,
    ["t3", targets.t3] as const,
  ]) {
    for (let n = 0; n < count && i < rest.length; n++, i++) {
      const row = rest[i];
      if (row) out.set(row.teamId, tier);
    }
  }
  for (; i < rest.length; i++) {
    const row = rest[i];
    if (row) out.set(row.teamId, "uncategorized");
  }
  return out;
}
EOF

cat > src/lib/consensus.ts <<'EOF'
export * from "../../convex/lib/consensus";
EOF

say "Convex: merge"
cat > convex/merge.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent, requireAdmin } from "./lib/guards";
import { assignTiers, consensus, type Vote } from "./lib/consensus";
import type { Tier } from "./lib/types";
import type { QueryCtx, MutationCtx } from "./_generated/server";

type Row = {
  teamId: string;
  teamNumber: number;
  nickname: string;
  score: number;
  voters: number;
  spread: number;
  dnpCount: number;
  proposedTier: Tier;
  notes: { voter: string; note: string }[];
};

async function build(ctx: QueryCtx | MutationCtx) {
  const event = await activeEvent(ctx);
  if (!event) return null;

  const lists = await ctx.db
    .query("pickLists")
    .withIndex("by_event_submitted", (q) =>
      q.eq("eventId", event._id).eq("isSubmitted", true))
    .collect();

  const profiles = await ctx.db.query("profiles").collect();
  const byUser = new Map(profiles.map((p) => [p.userId, p]));

  const teams = await ctx.db
    .query("teams")
    .withIndex("by_event", (q) => q.eq("eventId", event._id))
    .collect();
  const teamById = new Map(teams.map((t) => [t._id, t]));

  const votesByTeam = new Map<string, Vote[]>();
  const submitters: { name: string; weightTier: string; ranked: number }[] = [];
  const columnTotals = { t1: 0, t2: 0, t3: 0 };

  for (const list of lists) {
    if (list.ownerId === null) continue;
    const profile = byUser.get(list.ownerId);
    const voter = profile?.displayName ?? "Unknown scout";
    const weightTier = profile?.weightTier ?? "normal";

    const entries = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", list._id))
      .collect();

    const columns = new Map<string, typeof entries>();
    for (const entry of entries) {
      if (entry.tier === "uncategorized") continue;
      const col = columns.get(entry.tier) ?? [];
      col.push(entry);
      columns.set(entry.tier, col);
    }

    let ranked = 0;
    for (const [tier, col] of columns) {
      col.sort((a, b) => a.order - b.order);
      if (tier === "t1" || tier === "t2" || tier === "t3") {
        columnTotals[tier] += col.length;
      }
      for (let index = 0; index < col.length; index++) {
        const entry = col[index];
        if (!entry) continue;
        ranked += 1;
        const votes = votesByTeam.get(entry.teamId) ?? [];
        votes.push({
          voter,
          weightTier,
          tier: tier as Vote["tier"],
          index,
          columnSize: col.length,
          note: entry.note ?? "",
        });
        votesByTeam.set(entry.teamId, votes);
      }
    }
    submitters.push({ name: voter, weightTier, ranked });
  }

  const contributing = Math.max(1, submitters.length);
  const targets = {
    t1: Math.round(columnTotals.t1 / contributing),
    t2: Math.round(columnTotals.t2 / contributing),
    t3: Math.round(columnTotals.t3 / contributing),
  };

  const scored = [...votesByTeam.entries()].map(([teamId, votes]) => ({
    teamId,
    votes,
    consensus: consensus(votes),
  }));
  scored.sort((a, b) => b.consensus.score - a.consensus.score);

  const tiers = assignTiers(scored, targets);

  const rows: Row[] = scored.flatMap((row) => {
    const team = teamById.get(row.teamId as typeof teams[number]["_id"]);
    if (!team) return [];
    return [{
      teamId: row.teamId,
      teamNumber: team.number,
      nickname: team.nickname,
      score: row.consensus.score,
      voters: row.consensus.voters,
      spread: row.consensus.spread,
      dnpCount: row.consensus.dnpCount,
      proposedTier: tiers.get(row.teamId) ?? "uncategorized",
      notes: row.votes
        .filter((v) => v.note.trim() !== "")
        .map((v) => ({ voter: v.voter, note: v.note.trim() })),
    }];
  });

  // Everyone who could have submitted but did not. A missing strategy lead is
  // worth seeing before anyone trusts the output.
  const submittedNames = new Set(submitters.map((s) => s.name));
  const missing = profiles
    .map((p) => p.displayName)
    .filter((name) => !submittedNames.has(name));

  return { event, rows, submitters, missing, targets };
}

/** Pure computation. Writes nothing. */
export const preview = query({
  args: {},
  handler: async (ctx) => {
    await requireAdmin(ctx);
    const built = await build(ctx);
    if (!built) return { rows: [], submitters: [], missing: [], targets: null };
    return {
      rows: built.rows,
      submitters: built.submitters,
      missing: built.missing,
      targets: built.targets,
    };
  },
});

/**
 * Writes the previewed ranking into the primary list. Replaces every tier and
 * order on that list — an admin has to ask for this, and the UI makes them
 * confirm, because an unexplained reshuffle mid-selection is worse than no
 * merge at all.
 */
export const apply = mutation({
  args: { includeNotes: v.boolean() },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const built = await build(ctx);
    if (!built) throw new Error("No active event.");
    if (built.submitters.length === 0) {
      throw new Error("No scout has submitted a list, so there is nothing to merge.");
    }

    const primary = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", built.event._id).eq("ownerId", null))
      .first();
    if (!primary) throw new Error("There is no primary list yet.");

    const existing = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", primary._id))
      .collect();
    const byTeam = new Map(existing.map((e) => [e.teamId, e]));

    let order = 0;
    for (const row of built.rows) {
      order += 1000;
      const note = args.includeNotes
        ? row.notes.map((n) => `${n.voter}: ${n.note}`).join("\n")
        : "";
      const teamId = row.teamId as typeof existing[number]["teamId"];
      const entry = byTeam.get(teamId);
      if (entry) {
        await ctx.db.patch(entry._id, {
          tier: row.proposedTier,
          order,
          note: note || entry.note || "",
        });
      } else {
        await ctx.db.insert("pickListEntries", {
          pickListId: primary._id,
          teamId,
          tier: row.proposedTier,
          order,
          note,
        });
      }
    }

    return { teams: built.rows.length, from: built.submitters.length };
  },
});
EOF

say "Client: merge UI"
cat > src/routes/admin/merge.tsx <<'EOF'
import { useMutation, useQuery } from "convex/react";
import { AlertTriangle, ArrowLeft, Users } from "lucide-react";
import { useState } from "react";
import { Link } from "react-router";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { SCOUT_WEIGHTS } from "@/lib/scoring";
import { TIER_LABELS, type Tier } from "@/lib/types";

const TIER_ORDER: ReadonlyArray<Tier> = ["t1", "t2", "t3", "dnp", "uncategorized"];

export default function AdminMergePage() {
  const data = useQuery(api.merge.preview);
  const apply = useMutation(api.merge.apply);

  const [includeNotes, setIncludeNotes] = useState(true);
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);

  const run = async () => {
    setBusy(true);
    try {
      const result = await apply({ includeNotes });
      toast.success(`Primary list rebuilt`, {
        description: `${result.teams} teams from ${result.from} submitted lists.`,
      });
      setConfirm("");
    } catch (error) {
      toast.error("Merge failed", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  const rows = data?.rows ?? [];
  const disagreements = rows.filter((r) => r.spread > 20).length;

  return (
    <PageShell
      title="Merge pick lists"
      description="Weighted consensus across every submitted list. Nothing is written until you apply it."
      actions={
        <Button variant="outline" render={<Link to="/admin" />}>
          <ArrowLeft className="size-4" /> Admin
        </Button>
      }
    >
      <Card>
        <CardHeader>
          <CardTitle>Who submitted</CardTitle>
          <CardDescription>
            A strategy lead counts {SCOUT_WEIGHTS.lead}×, a trusted scout{" "}
            {SCOUT_WEIGHTS.trusted}×, everyone else {SCOUT_WEIGHTS.normal}×.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {data === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : data.submitters.length === 0 ? (
            <p className="text-muted-foreground text-sm">
              Nobody has marked a list for submission yet.
            </p>
          ) : (
            <>
              <div className="flex flex-wrap gap-2">
                {data.submitters.map((s) => (
                  <Badge key={s.name} variant="secondary">
                    <Users className="size-3" />
                    {s.name} · {s.ranked} ranked · {SCOUT_WEIGHTS[s.weightTier as keyof typeof SCOUT_WEIGHTS]}×
                  </Badge>
                ))}
              </div>
              {data.missing.length > 0 ? (
                <p className="text-muted-foreground text-xs">
                  Not submitted: {data.missing.join(", ")}. A missing strategy
                  lead is worth chasing before you trust this ranking.
                </p>
              ) : null}
              {data.targets ? (
                <p className="text-muted-foreground text-xs">
                  Tier sizes come from what the contributing lists averaged:{" "}
                  {data.targets.t1} first, {data.targets.t2} second,{" "}
                  {data.targets.t3} third.
                </p>
              ) : null}
            </>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Proposed ranking</CardTitle>
          <CardDescription>
            Spread is unweighted on purpose — it shows whether the room
            disagreed, which a weighted number would hide. Anything above 20 is
            worth a look before alliance selection.
            {disagreements > 0 ? ` ${disagreements} teams are flagged.` : ""}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-1">
          {rows.length === 0 ? (
            <p className="text-muted-foreground text-sm">
              Nothing to rank yet.
            </p>
          ) : (
            rows.map((row, i) => (
              <div key={row.teamId}
                className="flex flex-wrap items-center gap-2 rounded-lg border p-2 text-sm">
                <span className="text-muted-foreground w-6 text-xs tabular-nums">
                  {i + 1}
                </span>
                <span className="font-semibold tabular-nums">{row.teamNumber}</span>
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {row.nickname}
                </span>
                <Badge variant={row.proposedTier === "uncategorized" ? "outline" : "default"}>
                  {TIER_LABELS[row.proposedTier]}
                </Badge>
                <span className="text-muted-foreground text-xs tabular-nums">
                  {row.score.toFixed(0)}
                </span>
                <span className="text-muted-foreground text-xs tabular-nums">
                  {row.voters} vote{row.voters === 1 ? "" : "s"}
                </span>
                {row.spread > 20 ? (
                  <Badge variant="outline" className="text-xs">
                    <AlertTriangle className="size-3" />
                    spread {row.spread.toFixed(0)}
                  </Badge>
                ) : null}
                {row.dnpCount > 0 ? (
                  <Badge variant="destructive" className="text-xs">
                    {row.dnpCount} do-not-pick
                  </Badge>
                ) : null}
              </div>
            ))
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Apply to the primary list</CardTitle>
          <CardDescription>
            This replaces every tier and order on the primary list. Anything
            ranked there by hand is overwritten.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <label htmlFor="notes" className="flex items-center gap-2 text-sm">
            <Checkbox id="notes" checked={includeNotes}
              onCheckedChange={(next: boolean) => setIncludeNotes(Boolean(next))} />
            Carry pick notes across, attributed to whoever wrote them
          </label>
          <div className="space-y-2">
            <Label htmlFor="confirm">Type MERGE to confirm</Label>
            <Input id="confirm" className="max-w-40" value={confirm}
              autoCapitalize="characters"
              onChange={(e) => setConfirm(e.target.value)} />
          </div>
          <Button variant="destructive" disabled={busy || confirm.trim() !== "MERGE" || rows.length === 0}
            onClick={() => void run()}>
            Rebuild the primary list
          </Button>
        </CardContent>
      </Card>
    </PageShell>
  );
}
EOF

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Track G written. /admin/merge — preview first, then apply.

DONE
