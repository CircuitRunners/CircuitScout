import { v } from "convex/values";
import { query } from "./_generated/server";
import type { QueryCtx } from "./_generated/server";
import { activeEvent , currentTeamNumber } from "./lib/guards";
import { submittedBeforeMatchEnd } from "./lib/scoring";
import { EMPTY_SUMMARY, derive, summarise, type Summary } from "./lib/summarise";
import type { Doc, Id } from "./_generated/dataModel";

/** Whether each report's team was on the alliance that won auto. */
function winnerFlags(
  reports: Doc<"matchReports">[],
  matchById: Map<Id<"matches">, Doc<"matches">>,
  teamById: Map<Id<"teams">, Doc<"teams">>,
): Map<Id<"matchReports">, boolean | null> {
  const flags = new Map<Id<"matchReports">, boolean | null>();
  for (const r of reports) {
    const match = matchById.get(r.matchId);
    const team = teamById.get(r.teamId);
    if (r.autoWinner === null || !match || !team) {
      flags.set(r._id, null);
      continue;
    }
    const onRed = match.redTeamNumbers.includes(team.number);
    flags.set(r._id, r.autoWinner === (onRed ? "red" : "blue"));
  }
  return flags;
}

async function loadEvent(ctx: QueryCtx) {
  const event = await activeEvent(ctx);
  if (!event) return null;

  const [reports, matches, teams] = await Promise.all([
    ctx.db.query("matchReports").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
    ctx.db.query("matches").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
    ctx.db.query("teams").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
  ]);

  const matchById = new Map(matches.map((m) => [m._id, m]));
  const teamById = new Map(teams.map((t) => [t._id, t]));
  const teamByNumber = new Map(teams.map((t) => [t.number, t]));

  return {
    event, reports, matches, teams,
    matchById, teamById, teamByNumber,
    flags: winnerFlags(reports, matchById, teamById),
  };
}

export const forEvent = query({
  args: {},
  handler: async (ctx): Promise<Record<string, Summary>> => {
    const loaded = await loadEvent(ctx);
    if (!loaded) return {};

    const byTeam = new Map<Id<"teams">, { report: Doc<"matchReports">; isAutoWinner: boolean | null }[]>();
    for (const report of loaded.reports) {
      const list = byTeam.get(report.teamId) ?? [];
      list.push({ report, isAutoWinner: loaded.flags.get(report._id) ?? null });
      byTeam.set(report.teamId, list);
    }

    const out: Record<string, Summary> = {};
    for (const team of loaded.teams) {
      out[team._id] = summarise(byTeam.get(team._id) ?? []);
    }
    return out;
  },
});

export type CompareRow = {
  teamNumber: number;
  nickname: string;
  pitScouted: boolean;
  stats: Summary;
};

/** Aligned season averages for the teams asked for, in the order asked for. */
export const compare = query({
  args: { teamNumbers: v.array(v.number()) },
  handler: async (ctx, args): Promise<CompareRow[]> => {
    const loaded = await loadEvent(ctx);
    if (!loaded) return [];

    const myTeamForPit = await currentTeamNumber(ctx);
    const pit = (
      await ctx.db
        .query("pitReports")
        .withIndex("by_event", (q) => q.eq("eventId", loaded.event._id))
        .collect()
    ).filter((p) => p.scoutingTeamNumber === myTeamForPit);
    const scouted = new Set(pit.map((p) => p.teamId));

    return args.teamNumbers.flatMap((number) => {
      const team = loaded.teamByNumber.get(number);
      if (!team) return [];
      const entries = loaded.reports
        .filter((r) => r.teamId === team._id)
        .map((report) => ({ report, isAutoWinner: loaded.flags.get(report._id) ?? null }));
      return [{
        teamNumber: team.number,
        nickname: team.nickname,
        pitScouted: scouted.has(team._id),
        stats: entries.length ? summarise(entries) : { ...EMPTY_SUMMARY },
      }];
    });
  },
});

/**
 * A match, with each robot's season averages AND what it actually did in this
 * match if anyone scouted it. The two together answer different questions:
 * averages say what to expect, the actuals say what happened.
 */
export const forMatch = query({
  args: { matchNumber: v.number() },
  handler: async (ctx, args) => {
    const loaded = await loadEvent(ctx);
    if (!loaded) return null;

    const match = loaded.matches.find((m) => m.matchNumber === args.matchNumber);
    if (!match) return null;

    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    const side = (numbers: number[]) =>
      numbers.flatMap((number) => {
        const team = loaded.teamByNumber.get(number);
        if (!team) {
          return [{
            teamNumber: number, nickname: "Not at this event",
            stats: { ...EMPTY_SUMMARY }, thisMatch: [],
          }];
        }

        const season = loaded.reports
          .filter((r) => r.teamId === team._id)
          .map((report) => ({ report, isAutoWinner: loaded.flags.get(report._id) ?? null }));

        const thisMatch = loaded.reports
          .filter((r) => r.teamId === team._id && r.matchId === match._id)
          .map((report) => {
            const d = derive(report, loaded.flags.get(report._id) ?? null);
            return {
              scoutName: nameByUser.get(report.scoutId) ?? "Unknown scout",
              autoFuel: report.auto.fuel,
              teleopFuel: d.counted,
              deadFuel: d.dead,
              endgameFuel: report.endgame.fuel,
              totalFuel: d.total,
              climbPoints: d.climb,
              driver: report.ratings.driver,
              defense: report.ratings.defense,
              accuracy: report.ratings.accuracy,
              broke: report.ratings.broke,
              inconsistent: report.ratings.inconsistent,
              finalNotes: report.finalNotes ?? "",
            };
          });

        return [{
          teamNumber: team.number,
          nickname: team.nickname,
          stats: season.length ? summarise(season) : { ...EMPTY_SUMMARY },
          thisMatch,
        }];
      });

    return {
      matchNumber: match.matchNumber,
      scheduledTime: match.scheduledTime,
      predictedTime: match.predictedTime ?? null,
      actualTime: match.actualTime ?? null,
      redScore: match.redScore ?? null,
      blueScore: match.blueScore ?? null,
      winningAlliance: match.winningAlliance ?? "",
      importedAt: loaded.event.importedAt,
      red: side(match.redTeamNumbers),
      blue: side(match.blueTeamNumbers),
    };
  },
});

/** Is the data trustworthy? The view that decides whether anything else is. */
export const coverage = query({
  args: {},
  handler: async (ctx) => {
    const loaded = await loadEvent(ctx);
    if (!loaded) {
      return { matches: [], teamsNoPit: [], teamsNoMatch: [], byScout: [], totals: null };
    }

    const myTeam = await currentTeamNumber(ctx);
    const pit = (
      await ctx.db
        .query("pitReports")
        .withIndex("by_event", (q) => q.eq("eventId", loaded.event._id))
        .collect()
    ).filter((p) => p.scoutingTeamNumber === myTeam);
    const pitScouted = new Set(pit.map((p) => p.teamId));

    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    const reportsByMatch = new Map<Id<"matches">, Doc<"matchReports">[]>();
    for (const r of loaded.reports) {
      const list = reportsByMatch.get(r.matchId) ?? [];
      list.push(r);
      reportsByMatch.set(r.matchId, list);
    }

    const matches = loaded.matches
      .map((match) => {
        const rows = reportsByMatch.get(match._id) ?? [];
        const covered = new Set(
          rows.flatMap((r) => {
            const team = loaded.teamById.get(r.teamId);
            return team ? [team.number] : [];
          }),
        );
        const expected = [...match.redTeamNumbers, ...match.blueTeamNumbers];
        return {
          matchNumber: match.matchNumber,
          reportCount: rows.length,
          missing: expected.filter((n) => !covered.has(n)),
        };
      })
      .filter((m) => m.missing.length > 0)
      .sort((a, b) => a.matchNumber - b.matchNumber);

    const reportCountByTeam = new Map<Id<"teams">, number>();
    for (const r of loaded.reports) {
      reportCountByTeam.set(r.teamId, (reportCountByTeam.get(r.teamId) ?? 0) + 1);
    }

    const byScoutMap = new Map<string, { name: string; count: number; noSplit: number; early: number }>();
    for (const r of loaded.reports) {
      const key = r.scoutId;
      const row = byScoutMap.get(key) ?? {
        name: nameByUser.get(r.scoutId) ?? "Unknown scout",
        count: 0, noSplit: 0, early: 0,
      };
      row.count += 1;
      if (r.hubStateSource === "none") row.noSplit += 1;
      if (submittedBeforeMatchEnd(r.matchStartedAt, r.submittedAt)) row.early += 1;
      byScoutMap.set(key, row);
    }

    return {
      matches,
      teamsNoPit: loaded.teams
        .filter((t) => !pitScouted.has(t._id))
        .map((t) => t.number)
        .sort((a, b) => a - b),
      teamsNoMatch: loaded.teams
        .filter((t) => (reportCountByTeam.get(t._id) ?? 0) === 0)
        .map((t) => t.number)
        .sort((a, b) => a - b),
      byScout: [...byScoutMap.values()].sort((a, b) => b.count - a.count),
      totals: {
        teams: loaded.teams.length,
        matches: loaded.matches.length,
        reports: loaded.reports.length,
        possible: loaded.matches.length * 6,
      },
    };
  },
});
