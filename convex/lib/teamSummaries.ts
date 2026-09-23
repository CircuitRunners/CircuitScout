import type { MutationCtx, QueryCtx } from "../_generated/server";
import type { Doc, Id } from "../_generated/dataModel";
import { summarise, type Summary } from "./summarise";

/**
 * Whether a report's team was on the alliance the scout says won auto. Null
 * when the scout gave no answer or the match or team is gone. The single
 * copy of the rule, so stored summaries and per-match actuals cannot differ.
 */
export function isAutoWinnerFor(
  report: Doc<"matchReports">,
  match: Doc<"matches"> | null,
  team: Doc<"teams"> | null,
): boolean | null {
  if (report.autoWinner === null || !match || !team) return null;
  const onRed = match.redTeamNumbers.includes(team.number);
  return report.autoWinner === (onRed ? "red" : "blue");
}

/**
 * Rewrite one team's stored summary from its own reports at the event. Call
 * after anything that inserts, edits or deletes one of that team's match
 * reports. Reads a few dozen reports at most, never the whole event.
 */
export async function refreshTeamSummary(
  ctx: MutationCtx,
  eventId: Id<"events">,
  teamId: Id<"teams">,
): Promise<void> {
  const [team, reports, existing] = await Promise.all([
    ctx.db.get(teamId),
    ctx.db
      .query("matchReports")
      .withIndex("by_event_team", (q) => q.eq("eventId", eventId).eq("teamId", teamId))
      .collect(),
    ctx.db
      .query("teamSummaries")
      .withIndex("by_event_team", (q) => q.eq("eventId", eventId).eq("teamId", teamId))
      .first(),
  ]);

  if (!team || reports.length === 0) {
    if (existing) await ctx.db.delete(existing._id);
    return;
  }

  const matches = new Map<Id<"matches">, Doc<"matches"> | null>();
  const entries = [];
  for (const report of reports) {
    if (!matches.has(report.matchId)) {
      matches.set(report.matchId, await ctx.db.get(report.matchId));
    }
    const match = matches.get(report.matchId) ?? null;
    entries.push({ report, isAutoWinner: isAutoWinnerFor(report, match, team) });
  }

  const summary = summarise(entries);
  if (existing) {
    await ctx.db.patch(existing._id, { summary, updatedAt: Date.now() });
  } else {
    await ctx.db.insert("teamSummaries", { eventId, teamId, summary, updatedAt: Date.now() });
  }
}

/** Every stored summary at an event, by team. Teams with no reports are absent. */
export async function summariesFor(
  ctx: QueryCtx,
  eventId: Id<"events">,
): Promise<Map<Id<"teams">, Summary>> {
  const rows = await ctx.db
    .query("teamSummaries")
    .withIndex("by_event", (q) => q.eq("eventId", eventId))
    .collect();
  return new Map(rows.map((r) => [r.teamId, r.summary]));
}

/** One team's stored summary, or null when it has no reports. */
export async function summaryFor(
  ctx: QueryCtx,
  eventId: Id<"events">,
  teamId: Id<"teams">,
): Promise<Summary | null> {
  const row = await ctx.db
    .query("teamSummaries")
    .withIndex("by_event_team", (q) => q.eq("eventId", eventId).eq("teamId", teamId))
    .first();
  return row?.summary ?? null;
}
