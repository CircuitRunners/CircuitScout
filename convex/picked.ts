import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import {
  activeEvent, currentProfile, currentTeamNumber, managesTeam, requireUser,
} from "./lib/guards";

/** Teams my scouting team has marked as taken. */
export const forEvent = query({
  args: {},
  handler: async (ctx) => {
    await requireUser(ctx);
    const event = await activeEvent(ctx);
    const teamNumber = await currentTeamNumber(ctx);
    if (!event || teamNumber === undefined) return [];

    const rows = await ctx.db
      .query("pickedTeams")
      .withIndex("by_event_team", (q) =>
        q.eq("eventId", event._id).eq("scoutingTeamNumber", teamNumber))
      .collect();
    return rows.map((r) => r.teamId as string);
  },
});

/**
 * Same permission as editing the primary list: this is a statement about what
 * the team has done in the draft, not a personal note.
 */
export const toggle = mutation({
  args: { teamId: v.id("teams") },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const teamNumber = profile?.teamNumber;
    if (teamNumber === undefined || !managesTeam(profile, teamNumber)) {
      throw new Error("Only your team's admin can mark a team picked.");
    }

    const existing = (
      await ctx.db
        .query("pickedTeams")
        .withIndex("by_event_team", (q) =>
          q.eq("eventId", event._id).eq("scoutingTeamNumber", teamNumber))
        .collect()
    ).find((r) => r.teamId === args.teamId);

    if (existing) {
      await ctx.db.delete(existing._id);
      return { picked: false };
    }
    await ctx.db.insert("pickedTeams", {
      eventId: event._id,
      scoutingTeamNumber: teamNumber,
      teamId: args.teamId,
      pickedAt: Date.now(),
      pickedBy: userId,
    });
    return { picked: true };
  },
});
