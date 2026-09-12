import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import type { MutationCtx, QueryCtx } from "./_generated/server";
import { activeEventForTeam, currentProfile, requireTeamAdmin } from "./lib/guards";
import { derive, summarise } from "./lib/summarise";
import type { Doc, Id } from "./_generated/dataModel";

/** Twelve hours, for team admins only. */
const COOLDOWN_MS = 12 * 60 * 60 * 1000;

/**
 * When this person may export the active event again, as a timestamp, or null
 * for no wait.
 *
 * Keyed on profile AND event. Two team admins on one team each get their own
 * window, and each event keeps its own — swapping the active event away and
 * back does not clear a running timer, it just reveals whichever timer belongs
 * to the event now in front of you.
 */
async function cooldownUntil(
  ctx: QueryCtx | MutationCtx,
  profile: Doc<"profiles">,
): Promise<number | null> {
  if (profile.role !== "teamAdmin") return null;
  if (profile.teamNumber === undefined) return null;

  const event = await activeEventForTeam(ctx, profile.teamNumber);
  if (!event) return null;

  const last = await ctx.db
    .query("exportLog")
    .withIndex("by_profile_event", (q) =>
      q.eq("profileId", profile._id).eq("eventId", event._id))
    .unique();

  if (!last) return null;
  const until = last.at + COOLDOWN_MS;
  return until > Date.now() ? until : null;
}

/**
 * The client ticks its own countdown from this, so it returns a fixed
 * timestamp rather than a remaining duration — a duration would be stale the
 * moment the subscription stopped re-firing.
 */
export const cooldown = query({
  args: {},
  handler: async (ctx): Promise<{ until: number | null }> => {
    const profile = await currentProfile(ctx);
    if (!profile) return { until: null };
    return { until: await cooldownUntil(ctx, profile) };
  },
});

/**
 * Recorded after the file is actually produced, not before, so a failed build
 * does not cost someone twelve hours. The gate that matters is in forTeam:
 * the data cannot be fetched while the wait is running.
 */
export const recordExport = mutation({
  args: {},
  handler: async (ctx) => {
    const profile = await currentProfile(ctx);
    if (!profile || profile.role !== "teamAdmin") return;
    if (profile.teamNumber === undefined) return;
    const event = await activeEventForTeam(ctx, profile.teamNumber);
    if (!event) return;

    const existing = await ctx.db
      .query("exportLog")
      .withIndex("by_profile_event", (q) =>
        q.eq("profileId", profile._id).eq("eventId", event._id))
      .unique();

    if (existing) await ctx.db.patch(existing._id, { at: Date.now() });
    else {
      await ctx.db.insert("exportLog", {
        profileId: profile._id,
        eventId: event._id,
        at: Date.now(),
      });
    }
  },
});

/**
 * Teams a full admin may export for: at least one person on the app AND an
 * active event. A team missing either has nothing to export, and offering it
 * would only produce an empty workbook.
 *
 * Returns [] for everyone else, which is what hides the chooser — the dialog
 * renders the dropdown only when this is non-empty.
 */
export const eligibleTeams = query({
  args: {},
  handler: async (ctx) => {
    const me = await currentProfile(ctx);
    if (me?.role !== "admin") return [];

    const profiles = await ctx.db.query("profiles").collect();
    const members = new Map<number, number>();
    for (const p of profiles) {
      if (p.teamNumber === undefined) continue;
      members.set(p.teamNumber, (members.get(p.teamNumber) ?? 0) + 1);
    }

    const out = [];
    for (const [teamNumber, count] of [...members.entries()].sort((a, b) => a[0] - b[0])) {
      const event = await activeEventForTeam(ctx, teamNumber);
      if (!event) continue;
      out.push({
        teamNumber,
        members: count,
        eventName: event.name,
        eventKey: event.tbaEventKey,
      });
    }
    return out;
  },
});

/**
 * Everything the workbook needs, as plain rows. The browser turns these into
 * sheets — building the file server-side would mean shipping a spreadsheet
 * library into Convex for no gain.
 */
export const forTeam = query({
  args: { teamNumber: v.optional(v.number()) },
  handler: async (ctx, args) => {
    // Scouts have no use for this and the button is hidden from them, but the
    // refusal belongs here rather than only in the UI.
    const me = await requireTeamAdmin(ctx);

    // Your own team's event is yours to export. Someone else's is a cross-team
    // read, so that is full admin only.
    if (
      args.teamNumber !== undefined &&
      args.teamNumber !== me.teamNumber &&
      me.role !== "admin"
    ) {
      throw new Error("Admins only.");
    }

    const teamNumber = args.teamNumber ?? me.teamNumber;
    if (teamNumber === undefined) throw new Error("You are not on a team yet.");

    const until = await cooldownUntil(ctx, me);
    if (until !== null) {
      const mins = Math.ceil((until - Date.now()) / 60000);
      throw new Error(
        `You can export this event again in ${Math.floor(mins / 60)}h ${mins % 60}m.`,
      );
    }

    const event = await activeEventForTeam(ctx, teamNumber);
    if (!event) return null;

    const [reports, matches, teams, pit, epaRows, profiles] = await Promise.all([
      ctx.db.query("matchReports").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ctx.db.query("matches").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ctx.db.query("teams").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ctx.db.query("pitReports").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ctx.db.query("teamEpa").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ctx.db.query("profiles").collect(),
    ]);

    const teamById = new Map(teams.map((t) => [t._id, t]));
    const matchById = new Map(matches.map((m) => [m._id, m]));
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));
    const epaByNumber = new Map(epaRows.map((r) => [r.teamNumber, r]));

    const allianceOf = (report: Doc<"matchReports">) => {
      const team = teamById.get(report.teamId);
      const match = matchById.get(report.matchId);
      if (!team || !match) return "";
      return match.redTeamNumbers.includes(team.number) ? "red" : "blue";
    };
    const winnerFlag = (report: Doc<"matchReports">) => {
      if (report.autoWinner === null) return null;
      const side = allianceOf(report);
      return side === "" ? null : report.autoWinner === side;
    };

    // --- Pit scouting -------------------------------------------------------
    // Scoped to the chosen team. Pit reports are per scouting team by design;
    // match reports pool. Keeping that split here means the workbook says the
    // same thing the app does.
    const pitRows = pit
      .filter((p) => p.scoutingTeamNumber === teamNumber)
      .flatMap((p) => {
        const team = teamById.get(p.teamId);
        if (!team) return [];
        return [{
          team: team.number,
          nickname: team.nickname,
          scout: nameByUser.get(p.scoutId) ?? "",
          drivetrain: p.drivetrain,
          turret: p.scoring.turret,
          drumFullWidth: p.scoring.drumFullWidth,
          drumNarrow: p.scoring.drumNonFullWidth,
          fixedShooter: p.scoring.fixed,
          kitbot: p.scoring.kitbot,
          otherScoring: p.scoring.other ? p.scoring.otherText : "",
          climbLow: p.climb.low,
          climbMid: p.climb.mid,
          climbHigh: p.climb.high,
          climbAuto: p.climb.duringAuto,
          underTrench: p.underTrench,
          overBump: p.overBump,
          robotNotes: p.robotNotes,
          otherNotes: p.otherNotes,
        }];
      })
      .sort((a, b) => a.team - b.team);

    // --- Match scouting -----------------------------------------------------
    const reportRows = reports
      .flatMap((r) => {
        const team = teamById.get(r.teamId);
        const match = matchById.get(r.matchId);
        if (!team) return [];
        const d = derive(r, winnerFlag(r));
        return [{
          match: match?.matchNumber ?? "",
          team: team.number,
          nickname: team.nickname,
          alliance: allianceOf(r),
          scout: nameByUser.get(r.scoutId) ?? "",
          autoFuel: r.auto.fuel,
          autoClimbL1: r.auto.climbL1,
          autoFouls: r.auto.fouls,
          teleopCounted: d.counted,
          teleopDead: d.dead,
          transition: r.teleop.byShift.transition,
          s1: r.teleop.byShift.s1,
          s2: r.teleop.byShift.s2,
          s3: r.teleop.byShift.s3,
          s4: r.teleop.byShift.s4,
          endgameFuel: r.endgame.fuel,
          endgameClimb: r.endgame.climb,
          totalFuel: d.total,
          climbPoints: d.climb,
          driver: r.ratings.driver,
          defense: r.ratings.defense,
          accuracy: r.ratings.accuracy,
          avgBps: r.avgBps ?? "",
          adjustedBps: r.avgBps === undefined
            ? ""
            : Number((r.avgBps * (r.ratings.accuracy / 100)).toFixed(2)),
          shootsOnMove: r.ratings.shootsOnMove,
          broke: r.ratings.broke,
          inconsistent: r.ratings.inconsistent,
          autoWinner: r.autoWinner ?? "",
          hubStateSource: r.hubStateSource,
          finalNotes: r.finalNotes ?? "",
        }];
      })
      .sort((a, b) => Number(a.match) - Number(b.match) || a.team - b.team);

    // --- Teams with stats ---------------------------------------------------
    const byTeam = new Map<Id<"teams">, { report: Doc<"matchReports">; isAutoWinner: boolean | null }[]>();
    for (const r of reports) {
      const list = byTeam.get(r.teamId) ?? [];
      list.push({ report: r, isAutoWinner: winnerFlag(r) });
      byTeam.set(r.teamId, list);
    }
    const pitScouted = new Set(
      pit.filter((p) => p.scoutingTeamNumber === teamNumber).map((p) => p.teamId),
    );

    const summaryByNumber = new Map<number, ReturnType<typeof summarise>>();
    const teamRows = teams
      .sort((a, b) => a.number - b.number)
      .map((t) => {
        const s = summarise(byTeam.get(t._id) ?? []);
        summaryByNumber.set(t.number, s);
        const epa = epaByNumber.get(t.number);
        return {
          number: t.number,
          nickname: t.nickname,
          city: t.city,
          stateProv: t.stateProv,
          country: t.country,
          tbaTeamKey: t.tbaTeamKey,
          pitScouted: pitScouted.has(t._id),
          reportCount: s.reportCount,
          avgAutoFuel: s.avgAutoFuel,
          avgTeleopFuel: s.avgTeleopFuel,
          avgUncountedFuel: s.avgUncountedFuel,
          avgEndgameFuel: s.avgEndgameFuel,
          avgTotalFuel: s.avgTotalFuel,
          avgClimbPoints: s.avgClimbPoints,
          avgDriver: s.avgDriver,
          avgDefense: s.avgDefense,
          avgAccuracy: s.avgAccuracy,
          avgBps: s.avgBps,
          avgAdjustedBps: s.avgAdjustedBps,
          bpsReportCount: s.bpsReportCount,
          minTotalFuel: s.minTotalFuel,
          maxTotalFuel: s.maxTotalFuel,
          brokeCount: s.brokeCount,
          inconsistentCount: s.inconsistentCount,
          epa: epa?.epa ?? "",
          autoEpa: epa?.autoEpa ?? "",
          teleopEpa: epa?.teleopEpa ?? "",
          endgameEpa: epa?.endgameEpa ?? "",
        };
      });

    // --- Match list with stats ---------------------------------------------
    // Same projection the match preview shows, so the two never disagree:
    // avgTotalFuel + avgClimbPoints, summed over the alliance.
    const round1 = (n: number) => Number(n.toFixed(1));
    const projScouting = (nums: number[]) =>
      round1(nums.reduce((sum, n) => {
        const s = summaryByNumber.get(n);
        return sum + (s ? s.avgTotalFuel + s.avgClimbPoints : 0);
      }, 0));
    const projEpa = (nums: number[]) =>
      round1(nums.reduce((sum, n) => sum + (epaByNumber.get(n)?.epa ?? 0), 0));
    const reportsFor = (matchId: Id<"matches">, side: string) =>
      reports.filter((r) => r.matchId === matchId && allianceOf(r) === side).length;
    const stamp = (t: number | null | undefined) =>
      t === null || t === undefined ? "" : new Date(t).toISOString();

    const matchRows = matches
      .sort((a, b) => a.matchNumber - b.matchNumber)
      .map((m) => ({
        matchNumber: m.matchNumber,
        tbaMatchKey: m.tbaMatchKey,
        scheduledTime: stamp(m.scheduledTime),
        actualTime: stamp(m.actualTime),
        red1: m.redTeamNumbers[0] ?? "",
        red2: m.redTeamNumbers[1] ?? "",
        red3: m.redTeamNumbers[2] ?? "",
        blue1: m.blueTeamNumbers[0] ?? "",
        blue2: m.blueTeamNumbers[1] ?? "",
        blue3: m.blueTeamNumbers[2] ?? "",
        redScore: m.redScore ?? "",
        blueScore: m.blueScore ?? "",
        winningAlliance: m.winningAlliance ?? "",
        redProjScouting: projScouting(m.redTeamNumbers),
        blueProjScouting: projScouting(m.blueTeamNumbers),
        redProjEpa: projEpa(m.redTeamNumbers),
        blueProjEpa: projEpa(m.blueTeamNumbers),
        redReportsCollected: reportsFor(m._id, "red"),
        blueReportsCollected: reportsFor(m._id, "blue"),
      }));

    return {
      eventName: event.name,
      eventKey: event.tbaEventKey,
      teamNumber,
      pit: pitRows,
      matchReports: reportRows,
      teams: teamRows,
      matches: matchRows,
    };
  },
});
