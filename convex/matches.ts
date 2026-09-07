import { v } from "convex/values";
import { query } from "./_generated/server";
import { activeEvent } from "./lib/guards";

export const listForEvent = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    return matches.sort((a, b) => a.matchNumber - b.matchNumber);
  },
});

/** The six robots in a match, red then blue. Track C. */
export const teamsInMatch = query({
  args: { matchNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    const match = await ctx.db
      .query("matches")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("matchNumber", args.matchNumber))
      .unique();
    if (!match) return null;

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const byNumber = new Map(teams.map((t) => [t.number, t]));

    return {
      match,
      red: match.redTeamNumbers.map((n) => byNumber.get(n) ?? null),
      blue: match.blueTeamNumbers.map((n) => byNumber.get(n) ?? null),
    };
  },
});
