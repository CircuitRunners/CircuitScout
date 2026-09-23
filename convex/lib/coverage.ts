import type { MutationCtx } from "../_generated/server";
import type { Id } from "../_generated/dataModel";
import { submittedBeforeMatchEnd } from "./scoring";

/**
 * Rewrite one match's tally from that match's reports — a dozen at most.
 * Call after any report in the match is inserted or deleted.
 */
export async function refreshMatchTally(
  ctx: MutationCtx,
  eventId: Id<"events">,
  matchId: Id<"matches">,
): Promise<void> {
  const [reports, existing] = await Promise.all([
    ctx.db
      .query("matchReports")
      .withIndex("by_match", (q) => q.eq("matchId", matchId))
      .collect(),
    ctx.db
      .query("matchTallies")
      .withIndex("by_match", (q) => q.eq("matchId", matchId))
      .first(),
  ]);

  if (reports.length === 0) {
    if (existing) await ctx.db.delete(existing._id);
    return;
  }

  // A report whose team row is gone still counts as a report, but covers no
  // robot — the same as when coverage read the reports directly.
  const numbers = new Set<number>();
  const seen = new Set<Id<"teams">>();
  for (const report of reports) {
    if (seen.has(report.teamId)) continue;
    seen.add(report.teamId);
    const team = await ctx.db.get(report.teamId);
    if (team) numbers.add(team.number);
  }

  const fields = {
    reportCount: reports.length,
    teamNumbers: [...numbers].sort((a, b) => a - b),
  };
  if (existing) {
    await ctx.db.patch(existing._id, fields);
  } else {
    await ctx.db.insert("matchTallies", { eventId, matchId, ...fields });
  }
}

/**
 * Rewrite one scout's tally at one event from their own reports there. Call
 * after any of their reports is inserted, deleted, or has its timing edited.
 */
export async function refreshScoutTally(
  ctx: MutationCtx,
  eventId: Id<"events">,
  scoutId: Id<"users">,
): Promise<void> {
  const [reports, existing] = await Promise.all([
    ctx.db
      .query("matchReports")
      .withIndex("by_scout_event", (q) => q.eq("scoutId", scoutId).eq("eventId", eventId))
      .collect(),
    ctx.db
      .query("scoutTallies")
      .withIndex("by_event_scout", (q) => q.eq("eventId", eventId).eq("scoutId", scoutId))
      .first(),
  ]);

  if (reports.length === 0) {
    if (existing) await ctx.db.delete(existing._id);
    return;
  }

  const fields = {
    count: reports.length,
    noSplit: reports.filter((r) => r.hubStateSource === "none").length,
    early: reports.filter((r) => submittedBeforeMatchEnd(r.matchStartedAt, r.submittedAt)).length,
  };
  if (existing) {
    await ctx.db.patch(existing._id, fields);
  } else {
    await ctx.db.insert("scoutTallies", { eventId, scoutId, ...fields });
  }
}
