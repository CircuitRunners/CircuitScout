import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent, currentProfile, requireUser } from "./lib/guards";
import type { Doc, Id } from "./_generated/dataModel";

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

    // Only reports that carry a flag, straight off the index. Reading every
    // report to find the few with one re-ran on each submission, on every
    // phone with the teams tab open.
    const [broke, inconsistent] = await Promise.all([
      ctx.db
        .query("matchReports")
        .withIndex("by_event_broke", (q) =>
          q.eq("eventId", event._id).eq("ratings.broke", true))
        .collect(),
      ctx.db
        .query("matchReports")
        .withIndex("by_event_inconsistent", (q) =>
          q.eq("eventId", event._id).eq("ratings.inconsistent", true))
        .collect(),
    ]);
    // A report flagged both ways comes back from both indexes.
    const reports = new Map<Id<"matchReports">, Doc<"matchReports">>();
    for (const r of [...broke, ...inconsistent]) reports.set(r._id, r);

    // A handful of scouts, looked up once each, rather than the whole
    // profiles table.
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

    const rows = [];
    for (const report of reports.values()) {
      const team = await ctx.db.get(report.teamId);
      if (!team) continue;
      const match = await ctx.db.get(report.matchId);
      const dismissals = await ctx.db
        .query("flagDismissals")
        .withIndex("by_report", (q) => q.eq("reportId", report._id))
        .collect();

      for (const kind of ["broke", "inconsistent"] as const) {
        if (!report.ratings[kind]) continue;
        // A decision made before the report changed is stale.
        const settled = dismissals.some(
          (d) => d.reason === kind && d.dismissedAt >= report.updatedAt,
        );
        if (settled) continue;

        rows.push({
          reportId: report._id,
          kind,
          teamId: report.teamId,
          teamNumber: team.number,
          nickname: team.nickname,
          matchNumber: match?.matchNumber ?? 0,
          scoutName: await scoutName(report.scoutId),
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
