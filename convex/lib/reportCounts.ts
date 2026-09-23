import type { MutationCtx, QueryCtx } from "../_generated/server";
import type { Id } from "../_generated/dataModel";

/**
 * Adjust one team's report count at one event. Call on every insert (+1) and
 * delete (-1) of a match report. Floors at zero so a missed increment cannot
 * push a count negative; rebuildReportCounts corrects any drift.
 */
export async function bumpReportCount(
  ctx: MutationCtx,
  eventId: Id<"events">,
  teamId: Id<"teams">,
  delta: number,
): Promise<void> {
  const row = await ctx.db
    .query("reportCounts")
    .withIndex("by_event_team", (q) => q.eq("eventId", eventId).eq("teamId", teamId))
    .first();
  if (row) {
    await ctx.db.patch(row._id, { count: Math.max(0, row.count + delta) });
  } else if (delta > 0) {
    await ctx.db.insert("reportCounts", { eventId, teamId, count: delta });
  }
}

/** Report count per team at one event. Teams with none are simply absent. */
export async function reportCountsFor(
  ctx: QueryCtx,
  eventId: Id<"events">,
): Promise<Map<Id<"teams">, number>> {
  const rows = await ctx.db
    .query("reportCounts")
    .withIndex("by_event", (q) => q.eq("eventId", eventId))
    .collect();
  return new Map(rows.map((r) => [r.teamId, r.count]));
}
