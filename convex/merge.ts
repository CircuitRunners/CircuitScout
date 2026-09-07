import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent, managesTeam, requireTeamAdmin } from "./lib/guards";
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

async function build(ctx: QueryCtx | MutationCtx, actor: { role: string; teamNumber?: number }) {
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
    // A team's merge reads its own scouts' lists and nobody else's.
    if (actor.role !== "admin" && profile?.teamNumber !== actor.teamNumber) continue;
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
    .filter((p) => actor.role === "admin" || p.teamNumber === actor.teamNumber)
    .map((p) => p.displayName)
    .filter((name) => !submittedNames.has(name));

  return { event, rows, submitters, missing, targets };
}

/** Pure computation. Writes nothing. */
export const preview = query({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
    const built = await build(ctx, me);
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
    const me = await requireTeamAdmin(ctx);
    const built = await build(ctx, me);
    if (!built) throw new Error("No active event.");
    if (built.submitters.length === 0) {
      throw new Error("No scout has submitted a list, so there is nothing to merge.");
    }

    const primaries = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", built.event._id).eq("ownerId", null))
      .collect();
    const primary = primaries.find((l) => managesTeam(me, l.teamNumber));
    if (!primary) throw new Error("There is no primary list for your team yet.");

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
