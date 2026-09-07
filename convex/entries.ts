import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { currentProfile, requireUser } from "./lib/guards";

const tier = v.union(
  v.literal("t1"), v.literal("t2"), v.literal("t3"),
  v.literal("dnp"), v.literal("uncategorized"),
);

export const forList = query({
  args: { listId: v.id("pickLists") },
  handler: async (ctx, args) => {
    const entries = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", args.listId))
      .collect();

    const rows = [];
    for (const entry of entries) {
      const team = await ctx.db.get(entry.teamId);
      if (!team) continue;
      rows.push({
        entryId: entry._id,
        teamId: entry.teamId,
        teamNumber: team.number,
        nickname: team.nickname,
        tier: entry.tier,
        order: entry.order,
        note: entry.note ?? "",
      });
    }
    return rows.sort((a, b) => a.order - b.order);
  },
});

/**
 * Moves one entry. `order` is a float chosen by the client as the midpoint
 * between its new neighbours, so a drop is a single write and no other row
 * has to be renumbered.
 */
export const move = mutation({
  args: { entryId: v.id("pickListEntries"), tier, order: v.number() },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);

    const entry = await ctx.db.get(args.entryId);
    if (!entry) throw new Error("That card no longer exists.");
    const list = await ctx.db.get(entry.pickListId);
    if (!list) throw new Error("That list no longer exists.");

    if (list.ownerId === null) {
      if (profile?.role !== "admin") {
        throw new Error("Only an admin can edit the primary list.");
      }
    } else if (list.ownerId !== userId) {
      throw new Error("That is someone else's list.");
    }

    await ctx.db.patch(args.entryId, { tier: args.tier, order: args.order });
  },
});

/**
 * Rewrites a column's order to even spacing. Only needed when repeated
 * midpoint inserts have squeezed the gaps too small to represent.
 */
export const renormalise = mutation({
  args: { listId: v.id("pickLists"), tier },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);
    const list = await ctx.db.get(args.listId);
    if (!list) throw new Error("That list no longer exists.");
    if (list.ownerId === null ? profile?.role !== "admin" : list.ownerId !== userId) {
      throw new Error("You cannot edit that list.");
    }

    const entries = (
      await ctx.db
        .query("pickListEntries")
        .withIndex("by_list_tier", (q) =>
          q.eq("pickListId", args.listId).eq("tier", args.tier))
        .collect()
    ).sort((a, b) => a.order - b.order);

    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      if (entry) await ctx.db.patch(entry._id, { order: (i + 1) * 1000 });
    }
  },
});

/** A note on why this team sits where it does. */
export const setNote = mutation({
  args: { entryId: v.id("pickListEntries"), note: v.string() },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);

    const entry = await ctx.db.get(args.entryId);
    if (!entry) throw new Error("That card no longer exists.");
    const list = await ctx.db.get(entry.pickListId);
    if (!list) throw new Error("That list no longer exists.");

    if (list.ownerId === null) {
      if (profile?.role !== "admin") {
        throw new Error("Only an admin can edit the primary list.");
      }
    } else if (list.ownerId !== userId) {
      throw new Error("That is someone else's list.");
    }

    await ctx.db.patch(args.entryId, { note: args.note });
  },
});
