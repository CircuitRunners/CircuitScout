import { v } from "convex/values";
import { query } from "./_generated/server";
import { currentTeamNumber, requireUser } from "./lib/guards";
import { summarise, type Summary } from "./lib/summarise";
import type { Doc, Id } from "./_generated/dataModel";

/**
 * Read-only by construction. Every function here takes an explicit event key
 * and none of them can write, so nothing in this file can put scouting data
 * into the wrong competition.
 */

export const events = query({
  args: {},
  handler: async (ctx) => {
    await requireUser(ctx);
    const myTeam = await currentTeamNumber(ctx);

    const all = await ctx.db.query("events").collect();
    const settings = await ctx.db.query("teamSettings").collect();

    const rows = [];
    for (const event of all) {
      if (event.deletedAt) continue;
      const teams = await ctx.db
        .query("teams")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const matches = await ctx.db
        .query("matches")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const reports = await ctx.db
        .query("matchReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();

      const activeForTeams = settings
        .filter((t) => t.activeEventId === event._id)
        .map((t) => t.teamNumber);

      rows.push({
        eventKey: event.tbaEventKey,
        name: event.name,
        season: Number.parseInt(event.tbaEventKey.slice(0, 4), 10),
        teamCount: teams.length,
        matchCount: matches.length,
        reportCount: reports.length,
        activeForTeams,
        isMine: myTeam !== undefined && activeForTeams.includes(myTeam),
      });
    }

    return rows.sort((a, b) =>
      b.season - a.season || a.name.localeCompare(b.name));
  },
});

export const teamTable = query({
  args: { eventKey: v.string() },
  handler: async (ctx, args) => {
    await requireUser(ctx);

    const event = await ctx.db
      .query("events")
      .withIndex("by_key", (q) => q.eq("tbaEventKey", args.eventKey))
      .unique();
    if (!event) return null;

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

    const rows: {
      teamNumber: number;
      nickname: string;
      stats: Summary;
    }[] = teams.map((team) => ({
      teamNumber: team.number,
      nickname: team.nickname,
      stats: summarise(byTeam.get(team._id) ?? []),
    }));

    return {
      eventKey: event.tbaEventKey,
      name: event.name,
      matchCount: matches.length,
      rows: rows.sort((a, b) => a.teamNumber - b.teamNumber),
    };
  },
});
