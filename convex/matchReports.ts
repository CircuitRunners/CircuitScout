import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent, requireUser } from "./lib/guards";
import { MAX_AUTO_CYCLES } from "./lib/scoring";

const lane = v.union(
  v.literal("trench-left"), v.literal("bump-left"),
  v.literal("bump-right"), v.literal("trench-right"),
);

const reportInput = {
  auto: v.object({
    path: v.object({
      start: v.union(lane, v.literal("hub"), v.null()),
      steps: v.array(v.union(
        v.object({ kind: v.literal("neutral"), outbound: lane, inbound: v.union(lane, v.null()) }),
        v.object({ kind: v.literal("depot") }),
        v.object({ kind: v.literal("outpost") }),
        v.object({ kind: v.literal("climb") }),
      )),
    }),
    climbL1: v.boolean(),
    fuel: v.number(),
    fouls: v.number(),
    notes: v.string(),
  }),
  teleop: v.object({
    byShift: v.object({
      transition: v.number(),
      s1: v.number(), s2: v.number(), s3: v.number(), s4: v.number(),
    }),
    passedNeutral: v.number(),
    passedFullField: v.number(),
    stoleFuel: v.number(),
    defended: v.boolean(),
    notes: v.string(),
  }),
  endgame: v.object({
    climb: v.union(v.literal("none"), v.literal("low"),
                   v.literal("mid"), v.literal("high")),
    fuel: v.number(),
    stoleFuel: v.number(),
    passedNeutral: v.number(),
    passedFullField: v.number(),
    notes: v.string(),
  }),
  ratings: v.object({
    driver: v.number(), defense: v.number(), accuracy: v.number(),
    shootsOnMove: v.boolean(),
    broke: v.boolean(), brokeNotes: v.string(),
    inconsistent: v.boolean(), inconsistentNotes: v.string(),
  }),
  avgBps: v.number(),
  finalNotes: v.string(),
  matchStartedAt: v.union(v.number(), v.null()),
  autoWinner: v.union(v.literal("red"), v.literal("blue"), v.null()),
  hubStateSource: v.union(v.literal("timed"), v.literal("estimated"), v.literal("none")),
};

export const listForTeam = query({
  args: { teamId: v.id("teams") },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    return await ctx.db
      .query("matchReports")
      .withIndex("by_event_team", (q) =>
        q.eq("eventId", event._id).eq("teamId", args.teamId))
      .collect();
  },
});

/** My submitted reports, newest first — the "did it save?" surface. */
export const mine = query({
  args: {},
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_scout", (q) => q.eq("scoutId", userId))
      .collect();

    const rows = await Promise.all(
      reports.map(async (r) => ({
        ...r,
        match: await ctx.db.get(r.matchId),
        team: await ctx.db.get(r.teamId),
      })),
    );
    return rows.sort((a, b) => b.submittedAt - a.submittedAt);
  },
});

export const forMatchAndTeam = query({
  args: { matchNumber: v.number(), teamNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;

    const match = await ctx.db
      .query("matches")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("matchNumber", args.matchNumber))
      .unique();
    const team = await ctx.db
      .query("teams")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("number", args.teamNumber))
      .unique();
    if (!match || !team) return null;

    const userId = await requireUser(ctx);
    const existing = (
      await ctx.db
        .query("matchReports")
        .withIndex("by_match", (q) => q.eq("matchId", match._id))
        .collect()
    ).filter((r) => r.teamId === team._id);

    const myReport = existing.find((r) => r.scoutId === userId) ?? null;
    const onRed = match.redTeamNumbers.includes(team.number);
    return {
      match,
      team,
      myReport,
      othersCount: existing.length - (myReport ? 1 : 0),
      alliance: onRed ? "red" : "blue",
    };
  },
});

/**
 * How many reports each robot in a match already has, and whether one of them
 * is mine. Redundant coverage is deliberate — two scouts on one robot is a
 * cross-check, not a mistake — so this reports depth rather than locking.
 */
export const countsForMatch = query({
  args: { matchNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    const userId = await requireUser(ctx);

    const match = await ctx.db
      .query("matches")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("matchNumber", args.matchNumber))
      .unique();
    if (!match) return [];

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_match", (q) => q.eq("matchId", match._id))
      .collect();

    const byTeam = new Map<string, { count: number; mine: boolean }>();
    for (const r of reports) {
      const row = byTeam.get(r.teamId) ?? { count: 0, mine: false };
      row.count += 1;
      if (r.scoutId === userId) row.mine = true;
      byTeam.set(r.teamId, row);
    }

    return [...byTeam.entries()].map(([teamId, row]) => ({ teamId, ...row }));
  },
});

export const editHistory = query({
  args: { reportId: v.id("matchReports") },
  handler: async (ctx, args) =>
    await ctx.db
      .query("reportEdits")
      .withIndex("by_report", (q) => q.eq("reportId", args.reportId))
      .collect(),
});

export const submit = mutation({
  args: { matchId: v.id("matches"), teamId: v.id("teams"), ...reportInput },
  handler: async (ctx, args) => {
    const scoutId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const neutral = args.auto.path.steps.filter((s) => s.kind === "neutral");
    if (neutral.length > MAX_AUTO_CYCLES) {
      throw new Error(`Autonomous allows at most ${MAX_AUTO_CYCLES} neutral-zone cycles.`);
    }
    const lastStep = args.auto.path.steps.at(-1);
    if (
      args.auto.path.steps.some(
        (s) => s.kind === "neutral" && s.inbound === null && s !== lastStep,
      )
    ) {
      throw new Error("Only the final step can be exit-only.");
    }
    // A robot on the tower is not doing anything else, so a climb must be the
    // last thing in the path and there can only be one.
    const climbs = args.auto.path.steps.filter((s) => s.kind === "climb");
    if (climbs.length > 1) throw new Error("Only one L1 climb per match.");
    if (climbs.length === 1 && args.auto.path.steps.at(-1)?.kind !== "climb") {
      throw new Error("Nothing can follow an L1 climb.");
    }

    const { matchId, teamId, ...rest } = args;
    const now = Date.now();

    const mineAlready = (
      await ctx.db
        .query("matchReports")
        .withIndex("by_match", (q) => q.eq("matchId", matchId))
        .collect()
    ).find((r) => r.teamId === teamId && r.scoutId === scoutId);
    if (mineAlready) {
      throw new Error("You have already reported that robot in this match.");
    }

    const reportId = await ctx.db.insert("matchReports", {
      eventId: event._id,
      matchId,
      teamId,
      scoutId,
      submittedAt: now,
      updatedAt: now,
      autoWinnerFlagged: false,
      ...rest,
    });

    return reportId;
  },
});

/**
 * Every edit needs a reason, appended to reportEdits and never overwritten.
 * A wrong number quietly poisons every average the team appears in, so the
 * history of what changed and why is part of judging whether to trust it.
 */
export const update = mutation({
  args: { reportId: v.id("matchReports"), reason: v.string(), ...reportInput },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const reason = args.reason.trim();
    if (reason === "") throw new Error("An edit reason is required.");
    const neutral = args.auto.path.steps.filter((s) => s.kind === "neutral");
    if (neutral.length > MAX_AUTO_CYCLES) {
      throw new Error(`Autonomous allows at most ${MAX_AUTO_CYCLES} neutral-zone cycles.`);
    }
    const lastStep = args.auto.path.steps.at(-1);
    if (
      args.auto.path.steps.some(
        (s) => s.kind === "neutral" && s.inbound === null && s !== lastStep,
      )
    ) {
      throw new Error("Only the final step can be exit-only.");
    }
    // A robot on the tower is not doing anything else, so a climb must be the
    // last thing in the path and there can only be one.
    const climbs = args.auto.path.steps.filter((s) => s.kind === "climb");
    if (climbs.length > 1) throw new Error("Only one L1 climb per match.");
    if (climbs.length === 1 && args.auto.path.steps.at(-1)?.kind !== "climb") {
      throw new Error("Nothing can follow an L1 climb.");
    }

    const report = await ctx.db.get(args.reportId);
    if (!report) throw new Error("That report no longer exists.");

    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .unique();
    const isAuthor = report.scoutId === userId;
    if (!isAuthor && profile?.role !== "admin") {
      throw new Error("Only the scout who wrote this report, or an admin, can edit it.");
    }

    await ctx.db.patch(args.reportId, {
      auto: args.auto,
      teleop: args.teleop,
      endgame: args.endgame,
      ratings: args.ratings,
      avgBps: args.avgBps,
      finalNotes: args.finalNotes,
      matchStartedAt: args.matchStartedAt,
      autoWinner: args.autoWinner,
      hubStateSource: args.hubStateSource,
      updatedAt: Date.now(),
    });
    await ctx.db.insert("reportEdits", {
      reportId: args.reportId,
      editedBy: userId,
      editedAt: Date.now(),
      reason,
    });
  },
});
