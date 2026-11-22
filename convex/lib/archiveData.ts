import type { QueryCtx } from "../_generated/server";
import type { Doc, Id } from "../_generated/dataModel";
import { summarise, type Summary } from "./summarise";

/**
 * What Past Events shows for one event, worked out from its live data. Read
 * only. Shared by the archive queries and by the snapshot taken on delete, so
 * a snapshot is exactly what the page showed a moment before.
 */

export type ArchiveRow = { teamNumber: number; nickname: string; stats: Summary };

export type ArchiveTable = {
  teamCount: number;
  matchCount: number;
  reportCount: number;
  rows: ArchiveRow[];
};

type Reader = { db: QueryCtx["db"] };

export const seasonOf = (eventKey: string) => Number.parseInt(eventKey.slice(0, 4), 10);

/** Just the counts, for the event list. */
export async function liveCounts(ctx: Reader, eventId: Id<"events">) {
  const [teams, matches, reports] = await Promise.all([
    ctx.db.query("teams").withIndex("by_event", (q) => q.eq("eventId", eventId)).collect(),
    ctx.db.query("matches").withIndex("by_event", (q) => q.eq("eventId", eventId)).collect(),
    ctx.db.query("matchReports").withIndex("by_event", (q) => q.eq("eventId", eventId)).collect(),
  ]);
  return { teamCount: teams.length, matchCount: matches.length, reportCount: reports.length };
}

/** The per-team table, from the event's match reports. */
export async function liveTable(ctx: Reader, event: Doc<"events">): Promise<ArchiveTable> {
  const [teams, matches, reports] = await Promise.all([
    ctx.db.query("teams").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
    ctx.db.query("matches").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
    ctx.db.query("matchReports").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
  ]);

  const matchById = new Map(matches.map((m) => [m._id, m]));
  const teamById = new Map(teams.map((t) => [t._id, t]));

  const byTeam = new Map<
    Id<"teams">,
    { report: Doc<"matchReports">; isAutoWinner: boolean | null }[]
  >();
  for (const report of reports) {
    const match = matchById.get(report.matchId);
    const team = teamById.get(report.teamId);
    let isAutoWinner: boolean | null = null;
    if (report.autoWinner !== null && match && team) {
      const onRed = match.redTeamNumbers.includes(team.number);
      isAutoWinner = report.autoWinner === (onRed ? "red" : "blue");
    }
    const list = byTeam.get(report.teamId) ?? [];
    list.push({ report, isAutoWinner });
    byTeam.set(report.teamId, list);
  }

  const rows: ArchiveRow[] = teams.map((team) => ({
    teamNumber: team.number,
    nickname: team.nickname,
    stats: summarise(byTeam.get(team._id) ?? []),
  }));

  return {
    teamCount: teams.length,
    matchCount: matches.length,
    reportCount: reports.length,
    rows: rows.sort((a, b) => a.teamNumber - b.teamNumber),
  };
}

export async function snapshotFor(ctx: Reader, eventKey: string) {
  return await ctx.db
    .query("archiveSnapshots")
    .withIndex("by_key", (q) => q.eq("eventKey", eventKey))
    .first();
}
