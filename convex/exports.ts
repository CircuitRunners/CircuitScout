import { v } from "convex/values";
import { query } from "./_generated/server";
import { activeEvent, requireUser , currentTeamNumber } from "./lib/guards";
import { derive } from "./lib/summarise";

/** RFC 4180 quoting: wrap in quotes and double any quote inside. */
function cell(value: string | number | boolean | null | undefined): string {
  const text = value === null || value === undefined ? "" : String(value);
  return `"${text.replace(/"/g, '""')}"`;
}

const toCsv = (header: string[], rows: (string | number | boolean | null)[][]) =>
  [header.map(cell).join(","), ...rows.map((r) => r.map(cell).join(","))].join("\n");

/**
 * The escape hatch. Strategy leads want the data in a spreadsheet, and an
 * export is what you fall back on when the app is unreachable — which is
 * exactly when venue wifi fails.
 */
export const csv = query({
  args: {
    kind: v.union(
      v.literal("teams"),
      v.literal("matchReports"),
      v.literal("pitReports"),
    ),
  },
  handler: async (ctx, args): Promise<string> => {
    await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) return "";

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const teamById = new Map(teams.map((t) => [t._id, t]));

    if (args.kind === "teams") {
      return toCsv(
        ["number", "nickname", "city", "stateProv", "country", "tbaTeamKey"],
        teams
          .sort((a, b) => a.number - b.number)
          .map((t) => [t.number, t.nickname, t.city, t.stateProv, t.country, t.tbaTeamKey]),
      );
    }

    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    if (args.kind === "pitReports") {
      const myTeam = await currentTeamNumber(ctx);
      const pit = (
        await ctx.db
          .query("pitReports")
          .withIndex("by_event", (q) => q.eq("eventId", event._id))
          .collect()
      ).filter((p) => p.scoutingTeamNumber === myTeam);
      return toCsv(
        ["team", "nickname", "scout", "drivetrain", "turret", "drumFullWidth",
         "drumNarrow", "fixedShooter", "kitbot", "otherScoring", "climbLow",
         "climbMid", "climbHigh", "climbAuto", "underTrench", "overBump",
         "robotNotes", "otherNotes"],
        pit.flatMap((p) => {
          const team = teamById.get(p.teamId);
          if (!team) return [];
          return [[
            team.number, team.nickname, nameByUser.get(p.scoutId) ?? "",
            p.drivetrain, p.scoring.turret, p.scoring.drumFullWidth,
            p.scoring.drumNonFullWidth, p.scoring.fixed, p.scoring.kitbot,
            p.scoring.other ? p.scoring.otherText : "",
            p.climb.low, p.climb.mid, p.climb.high, p.climb.duringAuto,
            p.underTrench, p.overBump, p.robotNotes, p.otherNotes,
          ]];
        }),
      );
    }

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const matchById = new Map(matches.map((m) => [m._id, m]));

    return toCsv(
      ["match", "team", "nickname", "alliance", "scout", "autoFuel",
       "autoClimbL1", "autoFouls", "teleopCounted", "teleopDead",
       "transition", "s1", "s2", "s3", "s4", "endgameFuel", "endgameClimb",
       "totalFuel", "climbPoints", "driver", "defense", "accuracy", "avgBps", "adjustedBps",
       "shootsOnMove", "broke", "inconsistent", "autoWinner",
       "hubStateSource", "finalNotes"],
      reports.flatMap((r) => {
        const team = teamById.get(r.teamId);
        const match = matchById.get(r.matchId);
        if (!team) return [];
        const onRed = match?.redTeamNumbers.includes(team.number) ?? false;
        const alliance = onRed ? "red" : "blue";
        const isWinner = r.autoWinner === null ? null : r.autoWinner === alliance;
        const d = derive(r, isWinner);
        return [[
          match?.matchNumber ?? "", team.number, team.nickname, alliance,
          nameByUser.get(r.scoutId) ?? "",
          r.auto.fuel, r.auto.climbL1, r.auto.fouls,
          d.counted, d.dead,
          r.teleop.byShift.transition, r.teleop.byShift.s1, r.teleop.byShift.s2,
          r.teleop.byShift.s3, r.teleop.byShift.s4,
          r.endgame.fuel, r.endgame.climb,
          d.total, d.climb,
          r.ratings.driver, r.ratings.defense, r.ratings.accuracy,
          r.avgBps ?? "",
          r.avgBps === undefined
            ? ""
            : (r.avgBps * (r.ratings.accuracy / 100)).toFixed(2),
          r.ratings.shootsOnMove, r.ratings.broke, r.ratings.inconsistent,
          r.autoWinner ?? "", r.hubStateSource, r.finalNotes ?? "",
        ]];
      }),
    );
  },
});
