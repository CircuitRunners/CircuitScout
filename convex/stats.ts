import { v } from "convex/values";
import { query } from "./_generated/server";
import type { QueryCtx } from "./_generated/server";
import { activeEvent , currentTeamNumber } from "./lib/guards";
import { reportCountsFor } from "./lib/reportCounts";
import { EMPTY_SUMMARY, derive, type Summary } from "./lib/summarise";
import { isAutoWinnerFor, summariesFor, summaryFor } from "./lib/teamSummaries";
import type { Doc, Id } from "./_generated/dataModel";

/**
 * Every team's summary at the active event, keyed by team id. Reads one
 * stored row per team; this used to read and summarise every report at the
 * event, on every phone with the board or plot open, on every submission.
 */
export const forEvent = query({
  args: {},
  handler: async (ctx): Promise<Record<string, Summary>> => {
    const event = await activeEvent(ctx);
    if (!event) return {};

    const [teams, summaries] = await Promise.all([
      ctx.db.query("teams").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      summariesFor(ctx, event._id),
    ]);

    const out: Record<string, Summary> = {};
    for (const team of teams) {
      out[team._id] = summaries.get(team._id) ?? { ...EMPTY_SUMMARY };
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
    const event = await activeEvent(ctx);
    if (!event) return [];
    const myTeam = await currentTeamNumber(ctx);

    const rows: CompareRow[] = [];
    for (const number of args.teamNumbers) {
      const team = await ctx.db
        .query("teams")
        .withIndex("by_event_number", (q) => q.eq("eventId", event._id).eq("number", number))
        .first();
      if (!team) continue;
      // Pit reports are per scouting team; only your own team's count here.
      const pit = await ctx.db
        .query("pitReports")
        .withIndex("by_event_team", (q) => q.eq("eventId", event._id).eq("teamId", team._id))
        .collect();
      rows.push({
        teamNumber: team.number,
        nickname: team.nickname,
        pitScouted: pit.some((p) => p.scoutingTeamNumber === myTeam),
        stats: (await summaryFor(ctx, event._id, team._id)) ?? { ...EMPTY_SUMMARY },
      });
    }
    return rows;
  },
});

/**
 * A match, with each robot's season averages AND what it actually did in this
 * match if anyone scouted it. The two together answer different questions:
 * averages say what to expect, the actuals say what happened.
 *
 * Reads this match's reports and six stored summaries, not the whole event.
 */
export const forMatch = query({
  args: { matchNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;

    const match = await ctx.db
      .query("matches")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("matchNumber", args.matchNumber))
      .first();
    if (!match) return null;

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_match", (q) => q.eq("matchId", match._id))
      .collect();

    const names = new Map<Id<"users">, string>();
    const scoutName = async (userId: Id<"users">): Promise<string> => {
      const known = names.get(userId);
      if (known !== undefined) return known;
      const profile = await ctx.db
        .query("profiles")
        .withIndex("by_user", (q) => q.eq("userId", userId))
        .first();
      const name = profile?.displayName ?? "Unknown scout";
      names.set(userId, name);
      return name;
    };

    const side = (numbers: number[]) =>
      Promise.all(numbers.map(async (number) => {
        const team = await ctx.db
          .query("teams")
          .withIndex("by_event_number", (q) => q.eq("eventId", event._id).eq("number", number))
          .first();
        if (!team) {
          return {
            teamNumber: number, nickname: "Not at this event",
            stats: { ...EMPTY_SUMMARY }, thisMatch: [],
          };
        }

        const thisMatch = await Promise.all(
          reports
            .filter((r) => r.teamId === team._id)
            .map(async (report) => {
              const d = derive(report, isAutoWinnerFor(report, match, team));
              return {
                scoutName: await scoutName(report.scoutId),
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
            }),
        );

        return {
          teamNumber: team.number,
          nickname: team.nickname,
          stats: (await summaryFor(ctx, event._id, team._id)) ?? { ...EMPTY_SUMMARY },
          thisMatch,
        };
      }));

    return {
      matchNumber: match.matchNumber,
      scheduledTime: match.scheduledTime,
      predictedTime: match.predictedTime ?? null,
      actualTime: match.actualTime ?? null,
      redScore: match.redScore ?? null,
      blueScore: match.blueScore ?? null,
      winningAlliance: match.winningAlliance ?? "",
      importedAt: event.importedAt,
      red: await side(match.redTeamNumbers),
      blue: await side(match.blueTeamNumbers),
    };
  },
});

/**
 * Robot-matches covered, out of robot-matches on the schedule. One robot in
 * one match is one slot: it fills once, however many scouts watched it. That
 * is the whole point — counting reports instead runs past 100% the moment two
 * scouts double up, which is a thing this app encourages.
 *
 * Worked out against the CURRENT schedule, from stored per-match tallies, so
 * a revised schedule is reflected without a rebuild.
 */
function coveredSlots(
  matches: Doc<"matches">[],
  scoutedIn: Map<Id<"matches">, Set<number>>,
) {
  let slots = 0;
  let covered = 0;
  for (const match of matches) {
    const seen = scoutedIn.get(match._id) ?? new Set<number>();
    // The schedule's own alliances, not a hardcoded six: a match short a team
    // should not read as a robot nobody scouted. And only teams actually in
    // the match count, so a report filed against the wrong robot fills
    // nothing rather than covering for the one it displaced.
    const expected = [...match.redTeamNumbers, ...match.blueTeamNumbers];
    slots += expected.length;
    covered += expected.filter((number) => seen.has(number)).length;
  }
  return { slots, covered };
}

/** One small row per scouted match, plus the schedule. */
async function loadTallies(ctx: QueryCtx, eventId: Id<"events">) {
  const [matches, tallies] = await Promise.all([
    ctx.db.query("matches").withIndex("by_event", (q) => q.eq("eventId", eventId)).collect(),
    ctx.db.query("matchTallies").withIndex("by_event", (q) => q.eq("eventId", eventId)).collect(),
  ]);
  const tallyByMatch = new Map(tallies.map((t) => [t.matchId, t]));
  const scoutedIn = new Map(tallies.map((t) => [t.matchId, new Set(t.teamNumbers)]));
  return { matches, tallies, tallyByMatch, scoutedIn };
}

/** Just the fraction, for the dashboard metric. */
export const matchCoverage = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return { slots: 0, covered: 0 };
    const { matches, scoutedIn } = await loadTallies(ctx, event._id);
    return coveredSlots(matches, scoutedIn);
  },
});

/** Is the data trustworthy? The view that decides whether anything else is. */
export const coverage = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) {
      return { matches: [], teamsNoPit: [], teamsNoMatch: [], byScout: [], totals: null };
    }

    const myTeam = await currentTeamNumber(ctx);
    const [{ matches, tallies, tallyByMatch, scoutedIn }, teams, pit, counts, scouts] =
      await Promise.all([
        loadTallies(ctx, event._id),
        ctx.db.query("teams").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
        // Your own team's pit reports only.
        ctx.db
          .query("pitReports")
          .withIndex("by_event_scouting_team", (q) =>
            q.eq("eventId", event._id).eq("scoutingTeamNumber", myTeam))
          .collect(),
        reportCountsFor(ctx, event._id),
        ctx.db.query("scoutTallies").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ]);
    const pitScouted = new Set(pit.map((p) => p.teamId));

    const matchRows = matches
      .map((match) => {
        const covered = scoutedIn.get(match._id) ?? new Set<number>();
        const expected = [...match.redTeamNumbers, ...match.blueTeamNumbers];
        return {
          matchNumber: match.matchNumber,
          reportCount: tallyByMatch.get(match._id)?.reportCount ?? 0,
          missing: expected.filter((n) => !covered.has(n)),
        };
      })
      .filter((m) => m.missing.length > 0)
      .sort((a, b) => a.matchNumber - b.matchNumber);

    // A few dozen scouts, looked up once each.
    const byScout = await Promise.all(scouts.map(async (row) => {
      const profile = await ctx.db
        .query("profiles")
        .withIndex("by_user", (q) => q.eq("userId", row.scoutId))
        .first();
      return {
        name: profile?.displayName ?? "Unknown scout",
        count: row.count,
        noSplit: row.noSplit,
        early: row.early,
      };
    }));

    return {
      matches: matchRows,
      teamsNoPit: teams
        .filter((t) => !pitScouted.has(t._id))
        .map((t) => t.number)
        .sort((a, b) => a - b),
      teamsNoMatch: teams
        .filter((t) => (counts.get(t._id) ?? 0) === 0)
        .map((t) => t.number)
        .sort((a, b) => a - b),
      // Busiest first; equal counts by name, so the order is stable.
      byScout: byScout.sort((a, b) => b.count - a.count || a.name.localeCompare(b.name)),
      totals: {
        teams: teams.length,
        matches: matches.length,
        reports: tallies.reduce((n, t) => n + t.reportCount, 0),
        possible: matches.length * 6,
        ...coveredSlots(matches, scoutedIn),
      },
    };
  },
});
