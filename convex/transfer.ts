import { ConvexError, v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { profileOf, requireUser } from "./lib/guards";
import { acceptReport, heldReport, receiptFor } from "./lib/transfer";

/** The most ids one receipts call may ask about. */
const MAX_IDS = 200;

/**
 * A relayed report larger than this, as JSON, is refused. The largest real
 * form, with every notes box at its limit, is well under it.
 */
const MAX_RELAY_CHARS = 40_000;

/**
 * A refusal that is about the code as a whole, not one report in it: every
 * other report in the same code would be refused the same way, so the
 * scanner stops at the first.
 */
function refuseCode(message: string): never {
  throw new ConvexError({ scope: "code" as const, message });
}

/**
 * Sends one report that was held on the caller's device. Safe to call again
 * with the same report: the second call answers "received" and writes
 * nothing. One report per call, so a refused report cannot undo a good one.
 */
export const send = mutation({
  args: { report: heldReport },
  handler: async (ctx, args) =>
    await acceptReport(ctx, await requireUser(ctx), args.report, { via: "direct" }),
});

/**
 * Uploads one report from a teammate's QR code (data transfer plan,
 * section 7). The code is not signed. What the server checks is the team
 * boundary: the caller must be signed in and on the same team as the scout
 * the code names. The report is then written for that scout exactly as
 * transfer.send would write it, practice mode included, and the receipt
 * records who relayed it.
 *
 * Safe to call again with the same report: the second call answers
 * "received" and writes nothing, as does the author's own device later.
 */
export const relay = mutation({
  args: { author: v.string(), report: heldReport },
  handler: async (ctx, args) => {
    const relayedBy = await requireUser(ctx);
    const mine = await profileOf(ctx, relayedBy);
    if (mine?.teamNumber === undefined) {
      refuseCode("Set your team number on your profile before uploading for a teammate.");
    }
    const authorId = ctx.db.normalizeId("users", args.author);
    const theirs = authorId ? await profileOf(ctx, authorId) : null;
    if (!authorId || !theirs) {
      refuseCode("This code is from an account that does not exist here.");
    }
    if (theirs.teamNumber !== mine.teamNumber) {
      refuseCode("This code belongs to a scout on another team. Only a teammate can upload it.");
    }
    if (JSON.stringify(args.report).length > MAX_RELAY_CHARS) {
      throw new ConvexError("That report is larger than a form can produce.");
    }
    const arrival = await acceptReport(ctx, authorId, args.report, { via: "relay", relayedBy });
    // The name comes from the server, never from the code.
    return { ...arrival, author: theirs.displayName };
  },
});

/**
 * Which of the caller's held reports the server already has, and by which
 * route each arrived. Called once when a device reconnects with reports
 * waiting, never subscribed to.
 */
export const receipts = query({
  args: { ids: v.array(v.string()) },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    if (args.ids.length > MAX_IDS) throw new ConvexError(`Ask about at most ${MAX_IDS} reports at once.`);
    const found: Array<{ id: string; via: "direct" | "relay" }> = [];
    for (const id of new Set(args.ids)) {
      const receipt = await receiptFor(ctx, userId, id);
      if (receipt) found.push({ id, via: receipt.via });
    }
    return found;
  },
});
