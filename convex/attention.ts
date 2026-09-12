import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent, currentProfile, requireUser } from "./lib/guards";
import type { Doc } from "./_generated/dataModel";

/**
 * Who may settle an item. Trusted scouts are included deliberately: they are
 * the people in the stands who saw the robot, and making them wait for an
 * admin is how a warning sits unread through alliance selection.
 */
export function canSettle(profile: Doc<"profiles"> | null): boolean {
  if (!profile) return false;
  if (profile.role === "admin" || profile.role === "teamAdmin") return true;
  return profile.weightTier === "lead" || profile.weightTier === "trusted";
}

export const permissions = query({
  args: {},
  handler: async (ctx) => ({ canSettle: canSettle(await currentProfile(ctx)) }),
});

/**
 * Every outstanding broke/inconsistent report at the active event, from any
 * scouting team. Readable by anyone signed in.
 */
export const forEvent = query({
  args: {},
  handler: async (ctx) => {
    await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) return [];

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();

    const profiles = await ctx.db.query("profiles").collect();
    const byUser = new Map(profiles.map((p) => [p.userId, p]));
    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const teamById = new Map(teams.map((t) => [t._id, t]));
    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const matchById = new Map(matches.map((m) => [m._id, m]));

    const dismissals = await ctx.db.query("flagDismissals").collect();

    const rows = [];
    for (const report of reports) {
      const team = teamById.get(report.teamId);
      if (!team) continue;

      for (const kind of ["broke", "inconsistent"] as const) {
        if (!report.ratings[kind]) continue;
        // A decision made before the report changed is stale.
        const settled = dismissals.find(
          (d) => d.reportId === report._id && d.reason === kind &&
                 d.dismissedAt >= report.updatedAt,
        );
        if (settled) continue;

        rows.push({
          reportId: report._id,
          kind,
          teamId: report.teamId,
          teamNumber: team.number,
          nickname: team.nickname,
          matchNumber: matchById.get(report.matchId)?.matchNumber ?? 0,
          scoutName: byUser.get(report.scoutId)?.displayName ?? "Unknown scout",
          detail: kind === "broke"
            ? report.ratings.brokeNotes
            : report.ratings.inconsistentNotes,
          submittedAt: report.submittedAt,
        });
      }
    }
    return rows.sort((a, b) => b.submittedAt - a.submittedAt);
  },
});

export const settle = mutation({
  args: {
    reportId: v.id("matchReports"),
    kind: v.union(v.literal("broke"), v.literal("inconsistent")),
    state: v.union(v.literal("dismissed"), v.literal("resolved")),
    note: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);
    if (!canSettle(profile)) {
      throw new Error("Only admins and trusted scouts can settle these.");
    }
    const note = args.note.trim();
    if (note === "") throw new Error("A note is required.");

    const existing = await ctx.db
      .query("flagDismissals")
      .withIndex("by_report_reason", (q) =>
        q.eq("reportId", args.reportId).eq("reason", args.kind))
      .unique();

    const fields = {
      note,
      state: args.state,
      dismissedBy: userId,
      dismissedAt: Date.now(),
    };

    if (existing) {
      await ctx.db.patch(existing._id, fields);
      return existing._id;
    }
    return await ctx.db.insert("flagDismissals", {
      reportId: args.reportId,
      reason: args.kind,
      ...fields,
    });
  },
});
