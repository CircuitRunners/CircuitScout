import { ConvexError } from "convex/values";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import { activeEvent, currentProfile } from "./guards";

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

/** Saves a practice submission in place of the real one. */
export async function savePractice(
  ctx: MutationCtx,
  row: { kind: PracticeKind; teamNumber: number; matchNumber: number | null; payload: unknown },
): Promise<null> {
  const profile = await currentProfile(ctx);
  if (!profile) throw new Error("No profile for this user.");
  const event = await activeEvent(ctx);
  if (!event) throw new Error("No active event.");

  const existing = await ctx.db
    .query("practiceSubmissions")
    .withIndex("by_user_target", (q) =>
      q.eq("userId", profile.userId).eq("kind", row.kind).eq("eventId", event._id)
        .eq("teamNumber", row.teamNumber).eq("matchNumber", row.matchNumber))
    .first();
  const fields = { payload: JSON.stringify(row.payload), submittedAt: Date.now() };
  if (existing) {
    await ctx.db.patch(existing._id, fields);
  } else {
    await ctx.db.insert("practiceSubmissions", {
      userId: profile.userId,
      eventId: event._id,
      kind: row.kind,
      teamNumber: row.teamNumber,
      matchNumber: row.matchNumber,
      ...fields,
    });
  }
  return null;
}
