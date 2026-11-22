import type { MutationCtx } from "../_generated/server";
import type { Doc } from "../_generated/dataModel";
import { liveTable, seasonOf, snapshotFor } from "./archiveData";

/**
 * Saves what Past Events shows for this event, replacing any older snapshot
 * of the same key. Called right before an event is deleted.
 */
export async function takeSnapshot(ctx: MutationCtx, event: Doc<"events">) {
  const table = await liveTable(ctx, event);
  await dropSnapshot(ctx, event.tbaEventKey);
  await ctx.db.insert("archiveSnapshots", {
    eventKey: event.tbaEventKey,
    name: event.name,
    season: seasonOf(event.tbaEventKey),
    teamCount: table.teamCount,
    matchCount: table.matchCount,
    reportCount: table.reportCount,
    rows: JSON.stringify(table.rows),
    takenAt: Date.now(),
  });
}

/**
 * Before data is destroyed for good. A live event is snapshotted fresh; a
 * soft-deleted one already has its snapshot from the moment it was deleted
 * (its data cannot change while deleted), unless it was deleted before
 * snapshots existed.
 */
export async function ensureSnapshot(ctx: MutationCtx, event: Doc<"events">) {
  if (!event.deletedAt || !(await snapshotFor(ctx, event.tbaEventKey))) {
    await takeSnapshot(ctx, event);
  }
}

/** On recovery, so Past Events goes back to the live data. */
export async function dropSnapshot(ctx: MutationCtx, eventKey: string) {
  const rows = await ctx.db
    .query("archiveSnapshots")
    .withIndex("by_key", (q) => q.eq("eventKey", eventKey))
    .collect();
  for (const row of rows) await ctx.db.delete(row._id);
}
