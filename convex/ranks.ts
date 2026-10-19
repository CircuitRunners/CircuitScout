import { v } from "convex/values";
import { internalMutation, query } from "./_generated/server";
import { activeEvent } from "./lib/guards";

/**
 * TBA qualification rankings for the caller's active event. Refreshed only by
 * the two-hour cron and the Admin page's refresh button, through
 * tba.refreshRanks, which nothing outside the backend can call.
 */
export const forEvent = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    const rows = await ctx.db
      .query("teamRanks")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    return rows.map((r) => ({ teamNumber: r.teamNumber, rank: r.rank }));
  },
});

/**
 * Replaces the event's rankings with TBA's current list. Only rows whose rank
 * actually changed are written, so a refresh where nothing moved costs no
 * writes and wakes no pages.
 */
export const store = internalMutation({
  args: {
    eventId: v.id("events"),
    rows: v.array(v.object({ teamNumber: v.number(), rank: v.number() })),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("teamRanks")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    const byTeam = new Map(existing.map((r) => [r.teamNumber, r]));
    const incoming = new Set<number>();

    for (const row of args.rows) {
      incoming.add(row.teamNumber);
      const found = byTeam.get(row.teamNumber);
      if (!found) {
        await ctx.db.insert("teamRanks", { eventId: args.eventId, ...row });
      } else if (found.rank !== row.rank) {
        await ctx.db.patch(found._id, { rank: row.rank });
      }
    }
    // A team TBA no longer ranks (dropped from the event) loses its rank.
    for (const row of existing) {
      if (!incoming.has(row.teamNumber)) await ctx.db.delete(row._id);
    }
    return { ranked: args.rows.length };
  },
});
