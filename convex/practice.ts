import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { currentProfile, requireUser } from "./lib/guards";

/** Whether the signed-in scout is in practice mode. False when signed out. */
export const status = query({
  args: {},
  handler: async (ctx) => {
    const profile = await currentProfile(ctx);
    return { on: profile?.practiceMode === true };
  },
});

export const setMode = mutation({
  args: { on: v.boolean() },
  handler: async (ctx, args) => {
    await requireUser(ctx);
    const profile = await currentProfile(ctx);
    if (!profile) throw new Error("Set up your profile first.");
    await ctx.db.patch(profile._id, { practiceMode: args.on });
  },
});

/** Your own practice submissions, newest first. Nobody else can read them. */
export const mine = query({
  args: {},
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const rows = await ctx.db
      .query("practiceSubmissions")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .collect();
    const eventNames = new Map<string, string>();
    for (const row of rows) {
      if (eventNames.has(row.eventId)) continue;
      const event = await ctx.db.get(row.eventId);
      eventNames.set(row.eventId, event?.name ?? "Deleted event");
    }
    return rows
      .sort((a, b) => b.submittedAt - a.submittedAt)
      .map((row) => ({
        _id: row._id,
        kind: row.kind,
        teamNumber: row.teamNumber,
        matchNumber: row.matchNumber,
        eventName: eventNames.get(row.eventId) ?? "",
        payload: row.payload,
        submittedAt: row.submittedAt,
      }));
  },
});

export const remove = mutation({
  args: { id: v.id("practiceSubmissions") },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const row = await ctx.db.get(args.id);
    if (!row || row.userId !== userId) return;
    await ctx.db.delete(args.id);
  },
});

export const clear = mutation({
  args: {},
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const rows = await ctx.db
      .query("practiceSubmissions")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .collect();
    for (const row of rows) await ctx.db.delete(row._id);
    return { removed: rows.length };
  },
});
