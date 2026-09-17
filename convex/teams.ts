import { v } from "convex/values";
import { query } from "./_generated/server";
import type { QueryCtx } from "./_generated/server";
import { activeEvent , currentTeamNumber } from "./lib/guards";
import { derive, summarise } from "./lib/summarise";
import type { Doc, Id } from "./_generated/dataModel";

type Tier = "t1" | "t2" | "t3" | "dnp" | "uncategorized";

/**
 * Tier comes from the team primary list. Personal lists are the scout's own
 * working notes; the primary list is the one the team acts on, so that is what
 * belongs next to a team everywhere else in the app.
 */
async function primaryTiers(
  ctx: QueryCtx,
  eventId: Id<"events">,
): Promise<Map<string, Tier>> {
  const primary = await ctx.db
    .query("pickLists")
    .withIndex("by_event_owner", (q) =>
      q.eq("eventId", eventId).eq("ownerId", null))
    .first();
  if (!primary) return new Map();

  const entries = await ctx.db
    .query("pickListEntries")
    .withIndex("by_list", (q) => q.eq("pickListId", primary._id))
    .collect();

  return new Map(entries.map((e) => [e.teamId, e.tier]));
}

export const listWithStatus = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return [];

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();

    const myTeam = await currentTeamNumber(ctx);
    const pit = (
      await ctx.db
        .query("pitReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect()
    ).filter((p) => p.scoutingTeamNumber === myTeam);
    const scouted = new Set(pit.map((p) => p.teamId));

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const counts = new Map<string, number>();
    for (const r of reports) {
      counts.set(r.teamId, (counts.get(r.teamId) ?? 0) + 1);
    }

    const tiers = await primaryTiers(ctx, event._id);

    return teams
      .sort((a, b) => a.number - b.number)
      .map((t) => ({
        ...t,
        pitScouted: scouted.has(t._id),
        reportCount: counts.get(t._id) ?? 0,
        tier: tiers.get(t._id) ?? ("uncategorized" as Tier),
      }));
  },
});

/** Everything the detail modal needs, in one subscription. */
export const detail = query({
  args: { teamNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;

    const team = await ctx.db
      .query("teams")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("number", args.teamNumber))
      .unique();
    if (!team) return null;

    const myTeam = await currentTeamNumber(ctx);
    const pitReport = (
      await ctx.db
        .query("pitReports")
        .withIndex("by_event_team", (q) =>
          q.eq("eventId", event._id).eq("teamId", team._id))
        .collect()
    ).find((p) => p.scoutingTeamNumber === myTeam) ?? null;
    const photoUrl = pitReport?.photoId
      ? await ctx.storage.getUrl(pitReport.photoId)
      : null;

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event_team", (q) =>
        q.eq("eventId", event._id).eq("teamId", team._id))
      .collect();

    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const matchById = new Map(matches.map((m) => [m._id, m]));

    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    const rows = [];
    // Averages come from the shared summariser rather than a second copy of
    // the arithmetic, so the team card and the compare table cannot disagree
    // about what a driver rating is.
    const entries: { report: Doc<"matchReports">; isAutoWinner: boolean | null }[] = [];

    for (const report of reports) {
      const match = matchById.get(report.matchId);
      const onRed = match?.redTeamNumbers.includes(team.number) ?? false;
      const alliance: "red" | "blue" = onRed ? "red" : "blue";
      const isWinner =
        report.autoWinner === null ? null : report.autoWinner === alliance;

      const { counted, dead, total, climb } = derive(report, isWinner);
      entries.push({ report, isAutoWinner: isWinner });

      const edits = await ctx.db
        .query("reportEdits")
        .withIndex("by_report", (q) => q.eq("reportId", report._id))
        .collect();

      rows.push({
        reportId: report._id,
        matchNumber: match?.matchNumber ?? 0,
        alliance,
        scoutName: nameByUser.get(report.scoutId) ?? "Unknown scout",
        autoFuel: report.auto.fuel,
        teleopFuel: counted,
        deadFuel: dead,
        endgameFuel: report.endgame.fuel,
        totalFuel: total,
        climb: report.endgame.climb,
        climbPoints: climb,
        autoClimb: report.auto.climbL1,
        driver: report.ratings.driver,
        defense: report.ratings.defense,
        accuracy: report.ratings.accuracy,
        broke: report.ratings.broke,
        brokeNotes: report.ratings.brokeNotes,
        inconsistent: report.ratings.inconsistent,
        inconsistentNotes: report.ratings.inconsistentNotes,
        shootsOnMove: report.ratings.shootsOnMove,
        finalNotes: report.finalNotes ?? "",
        hubStateSource: report.hubStateSource,
        editCount: edits.length,
        submittedAt: report.submittedAt,
      });
    }

    rows.sort((a, b) => a.matchNumber - b.matchNumber);

    const tiers = await primaryTiers(ctx, event._id);

    return {
      team,
      pitReport,
      photoUrl,
      pitScoutName: pitReport
        ? (nameByUser.get(pitReport.scoutId) ?? "Unknown scout")
        : null,
      tier: tiers.get(team._id) ?? ("uncategorized" as Tier),
      reports: rows,
      stats: summarise(entries),
    };
  },
});
