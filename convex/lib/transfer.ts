import { ConvexError, v, type Infer } from "convex/values";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import type { Id } from "../_generated/dataModel";
import { activeEventOf } from "./guards";
import { submitArgs, writeMatchReport } from "../matchReports";
import { upsertArgs, writePitReport } from "../pit";
import {
  saveMatchReportArgs, savePitReportArgs, writeGenericMatch, writeGenericPit,
} from "../notes";

/**
 * Reports that were saved with no connection and sent later.
 *
 * A held report carries an id made on the device when the form was saved and
 * the event it was saved for. acceptReport writes it through the same
 * functions an online save uses, and stores a receipt for the id in the same
 * mutation. A report whose id already has a receipt is not written again, so
 * a retry, a second tab or a second route cannot duplicate it.
 */

const envelope = { id: v.string(), eventId: v.id("events") };

/** One held report: which form it came from, and that form's save arguments. */
export const heldReport = v.union(
  v.object({ ...envelope, kind: v.literal("match"), args: v.object(submitArgs) }),
  v.object({ ...envelope, kind: v.literal("pit"), args: v.object(upsertArgs) }),
  v.object({ ...envelope, kind: v.literal("noteMatch"), args: v.object(saveMatchReportArgs) }),
  v.object({ ...envelope, kind: v.literal("notePit"), args: v.object(savePitReportArgs) }),
);
export type HeldReport = Infer<typeof heldReport>;

/** How a report reached the server. */
export type Route =
  | { via: "direct" }
  | { via: "relay"; relayedBy: Id<"users"> };

/**
 * accepted: written now. received: the server already had it, and nothing was
 * written; via says which route brought it the first time.
 */
export type Arrival = { status: "accepted" | "received"; via: "direct" | "relay" };

/** Ids are made by the device. Anything of a sensible shape is accepted. */
const REPORT_ID = /^[A-Za-z0-9-]{16,64}$/;

/** The receipt for one of an author's reports, if the server has it. */
export async function receiptFor(
  ctx: QueryCtx | MutationCtx,
  authorId: Id<"users">,
  reportId: string,
) {
  return await ctx.db
    .query("transferReceipts")
    .withIndex("by_author_report", (q) => q.eq("authorId", authorId).eq("reportId", reportId))
    .first();
}

/**
 * Writes a held report for its author, once. A report that cannot be accepted
 * is refused with a ConvexError, so the reason reaches the device and nothing
 * of it is written, the receipt included.
 */
export async function acceptReport(
  ctx: MutationCtx,
  authorId: Id<"users">,
  report: HeldReport,
  route: Route,
): Promise<Arrival> {
  if (!REPORT_ID.test(report.id)) throw new ConvexError("That report has no valid id.");

  const receipt = await receiptFor(ctx, authorId, report.id);
  if (receipt) return { status: "received", via: receipt.via };

  // The writers use the author's team's active event. A report held for a
  // different one must not land in it.
  const event = await activeEventOf(ctx, authorId);
  if (!event) throw new ConvexError("No active event.");
  if (event._id !== report.eventId) {
    throw new ConvexError("This was saved for a different event, so it was not sent.");
  }

  try {
    switch (report.kind) {
      case "match": {
        const [match, team] = await Promise.all([
          ctx.db.get(report.args.matchId), ctx.db.get(report.args.teamId),
        ]);
        if (!match || !team || match.eventId !== event._id || team.eventId !== event._id) {
          throw new ConvexError("That match or team is not at the active event.");
        }
        await writeMatchReport(ctx, authorId, report.args);
        break;
      }
      case "pit":
        // A held report never carries a photo: photos need a connection.
        if (report.args.photoId !== null) throw new ConvexError("A held report cannot carry a photo.");
        await writePitReport(ctx, authorId, report.args, true);
        break;
      case "noteMatch":
        await writeGenericMatch(ctx, authorId, report.args, true);
        break;
      case "notePit":
        if (report.args.photoId !== null) throw new ConvexError("A held report cannot carry a photo.");
        await writeGenericPit(ctx, authorId, report.args, true);
        break;
    }
  } catch (error) {
    // The writers throw plain errors, which production hides from the client.
    // The device needs the reason to show beside the report it could not send.
    if (error instanceof ConvexError) throw error;
    throw new ConvexError(error instanceof Error ? error.message : "The report could not be saved.");
  }

  await ctx.db.insert("transferReceipts", {
    authorId,
    reportId: report.id,
    kind: report.kind,
    eventId: event._id,
    via: route.via,
    ...(route.via === "relay" ? { relayedBy: route.relayedBy } : {}),
    receivedAt: Date.now(),
  });
  return { status: "accepted", via: route.via };
}
