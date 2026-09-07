import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent, currentTeamNumber, requireUser } from "./lib/guards";
import type { Doc, Id } from "./_generated/dataModel";
import type { QueryCtx, MutationCtx } from "./_generated/server";

const scoringInput = v.object({
  turret: v.boolean(),
  drumNonFullWidth: v.boolean(),
  drumFullWidth: v.boolean(),
  fixed: v.boolean(),
  kitbot: v.boolean(),
  other: v.boolean(),
  otherText: v.string(),
});

const climbInput = v.object({
  low: v.boolean(),
  mid: v.boolean(),
  high: v.boolean(),
  duringAuto: v.boolean(),
});

/**
 * One pit report per robot PER SCOUTING TEAM. Two teams at the same
 * competition each keep their own; without this the second team to visit a pit
 * silently overwrote the first.
 */
async function mine(
  ctx: QueryCtx | MutationCtx,
  eventId: Id<"events">,
  teamId: Id<"teams">,
): Promise<Doc<"pitReports"> | null> {
  const scoutingTeamNumber = await currentTeamNumber(ctx);
  if (scoutingTeamNumber === undefined) return null;

  const rows = await ctx.db
    .query("pitReports")
    .withIndex("by_event_team", (q) =>
      q.eq("eventId", eventId).eq("teamId", teamId))
    .collect();
  return rows.find((r) => r.scoutingTeamNumber === scoutingTeamNumber) ?? null;
}

export const get = query({
  args: { teamId: v.id("teams") },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    return await mine(ctx, event._id, args.teamId);
  },
});

/** Resolves a team by number for the /pit/:teamNumber route. */
export const forTeamNumber = query({
  args: { teamNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;

    const team = await ctx.db
      .query("teams")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("number", args.teamNumber))
      .unique();
    if (!team) return null;

    const report = await mine(ctx, event._id, team._id);
    const photoUrl = report?.photoId ? await ctx.storage.getUrl(report.photoId) : null;

    return { team, report, photoUrl };
  },
});

export const generateUploadUrl = mutation({
  args: {},
  handler: async (ctx) => {
    await requireUser(ctx);
    return await ctx.storage.generateUploadUrl();
  },
});

/**
 * A second scout from the same team visiting the same pit updates their team's
 * report rather than creating a duplicate — pits get revisited, and two
 * conflicting reports for one robot is worse than one that changed.
 */
export const upsert = mutation({
  args: {
    teamId: v.id("teams"),
    scoring: scoringInput,
    climb: climbInput,
    drivetrain: v.string(),
    underTrench: v.boolean(),
    overBump: v.boolean(),
    robotNotes: v.string(),
    otherNotes: v.string(),
    photoId: v.union(v.id("_storage"), v.null()),
  },
  handler: async (ctx, args) => {
    const scoutId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const scoutingTeamNumber = await currentTeamNumber(ctx);
    if (scoutingTeamNumber === undefined) {
      throw new Error("Set your team number on your profile first.");
    }

    const team = await ctx.db.get(args.teamId);
    if (!team || team.eventId !== event._id) {
      throw new Error("That team is not part of the active event.");
    }

    const existing = await mine(ctx, event._id, args.teamId);

    const fields = {
      scoring: args.scoring,
      climb: args.climb,
      drivetrain: args.drivetrain,
      underTrench: args.underTrench,
      overBump: args.overBump,
      robotNotes: args.robotNotes,
      otherNotes: args.otherNotes,
      // Keep the old photo when this save did not include a new one.
      photoId: args.photoId ?? existing?.photoId ?? null,
      scoutId,
      scoutingTeamNumber,
      updatedAt: Date.now(),
    };

    if (existing) {
      await ctx.db.patch(existing._id, fields);
      return existing._id;
    }
    return await ctx.db.insert("pitReports", {
      eventId: event._id,
      teamId: args.teamId,
      ...fields,
    });
  },
});
