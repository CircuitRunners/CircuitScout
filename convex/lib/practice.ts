import { ConvexError } from "convex/values";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import type { Id } from "../_generated/dataModel";
import { activeEvent, activeEventOf, currentProfile, profileOf } from "./guards";

export type PracticeKind = "match" | "pit" | "pitNote" | "matchNote";

/** Whether the signed-in scout has practice mode on. */
export async function isPracticing(ctx: QueryCtx | MutationCtx): Promise<boolean> {
  return (await currentProfile(ctx))?.practiceMode === true;
}

/**
 * For actions that would change real data and have no practice version.
 * A ConvexError so the message reaches the scout in production.
 */
export async function refuseInPractice(ctx: QueryCtx | MutationCtx, message: string) {
  if (await isPracticing(ctx)) throw new ConvexError(message);
}

/** Whether a given scout has practice mode on. */
export async function isPracticingAs(
  ctx: QueryCtx | MutationCtx,
  userId: Id<"users">,
): Promise<boolean> {
  return (await profileOf(ctx, userId))?.practiceMode === true;
}

type PracticeRow = {
  kind: PracticeKind; teamNumber: number; matchNumber: number | null; payload: unknown;
};

/** Saves a practice submission in place of the real one. */
export async function savePractice(ctx: MutationCtx, row: PracticeRow): Promise<null> {
  const profile = await currentProfile(ctx);
  if (!profile) throw new Error("No profile for this user.");
  const event = await activeEvent(ctx);
  if (!event) throw new Error("No active event.");
  return await storePractice(ctx, profile.userId, event._id, row);
}

/** The same, for a given scout: practice is decided by who wrote the report. */
export async function savePracticeAs(
  ctx: MutationCtx,
  userId: Id<"users">,
  row: PracticeRow,
): Promise<null> {
  const event = await activeEventOf(ctx, userId);
  if (!event) throw new Error("No active event.");
  return await storePractice(ctx, userId, event._id, row);
}

async function storePractice(
  ctx: MutationCtx,
  userId: Id<"users">,
  eventId: Id<"events">,
  row: PracticeRow,
): Promise<null> {

  const existing = await ctx.db
    .query("practiceSubmissions")
    .withIndex("by_user_target", (q) =>
      q.eq("userId", userId).eq("kind", row.kind).eq("eventId", eventId)
        .eq("teamNumber", row.teamNumber).eq("matchNumber", row.matchNumber))
    .first();
  const fields = { payload: JSON.stringify(row.payload), submittedAt: Date.now() };
  if (existing) {
    await ctx.db.patch(existing._id, fields);
  } else {
    await ctx.db.insert("practiceSubmissions", {
      userId,
      eventId,
      kind: row.kind,
      teamNumber: row.teamNumber,
      matchNumber: row.matchNumber,
      ...fields,
    });
  }
  return null;
}
