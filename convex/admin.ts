import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import type { MutationCtx } from "./_generated/server";
import {
  activeEvent, managesTeam, requireAdmin, requireTeamAdmin, requireUser,
} from "./lib/guards";
import {
  countedTeleopFuel,
  submittedBeforeMatchEnd,
  uncountedTeleopFuel,
} from "./lib/scoring";
import { bumpReportCount } from "./lib/reportCounts";
import { refreshTeamSummary } from "./lib/teamSummaries";
import { refreshMatchTally, refreshScoutTally } from "./lib/coverage";
import type { Doc, Id } from "./_generated/dataModel";
export type FlagReason =
  | "early"          // finished before the buzzer
  | "no-split"       // no time anchor, fuel not attributable to a shift
  | "dead-hub"       // more inactive-hub fuel than active
  | "disagreement";  // auto winner conflicts with other scouts in the match

const REASON_LABELS: Record<FlagReason, string> = {
  early: "Submitted before match end",
  "no-split": "No shift split",
  "dead-hub": "More dead-hub than counted fuel",
  disagreement: "Auto winner disagrees with other scouts",
};

/**
 * A team admin acts on reports written by their own team's scouts; a full
 * admin on anyone's. The reports view already hid other teams' reports, but
 * the mutations behind it did not check, so an id was enough.
 */
async function assertManagesReport(
  ctx: MutationCtx,
  admin: Doc<"profiles">,
  report: Doc<"matchReports">,
): Promise<void> {
  const scout = await ctx.db
    .query("profiles")
    .withIndex("by_user", (q) => q.eq("userId", report.scoutId))
    .first();
  if (!managesTeam(admin, scout?.teamNumber)) {
    throw new Error("That report was written by another team's scout.");
  }
}

export const flagLabels = query({
  args: {},
  handler: async () => REASON_LABELS,
});

type Row = {
  reportId: string;
  matchNumber: number;
  teamNumber: number;
  teamNickname: string;
  scoutName: string;
  alliance: "red" | "blue";
  autoWinner: "red" | "blue" | null;
  counted: number;
  dead: number;
  submittedAt: number;
  editCount: number;
  reasons: FlagReason[];
  reasonLabels: string[];
  dismissed: {
    reason: FlagReason;
    label: string;
    note: string;
    byName: string;
    at: number;
  }[];
};

/**
 * Every report at the active event, newest first, with any data-quality flags
 * attached. Flags are DERIVED on read, so correcting a report clears its flag
 * immediately rather than leaving a stale marker behind.
 */
export const reports = query({
  args: { onlyFlagged: v.boolean() },
  handler: async (ctx, args): Promise<Row[]> => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) return [];

    const all = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();

    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const matchById = new Map(matches.map((m) => [m._id, m]));

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const teamById = new Map(teams.map((t) => [t._id, t]));

    // Scouts and dismissers, looked up once each. A few dozen people, against
    // a profiles table that only grows.
    const profiles = new Map<Id<"users">, Doc<"profiles"> | null>();
    const profileFor = async (userId: Id<"users">) => {
      if (!profiles.has(userId)) {
        profiles.set(userId, await ctx.db
          .query("profiles")
          .withIndex("by_user", (q) => q.eq("userId", userId))
          .first());
      }
      return profiles.get(userId) ?? null;
    };

    // Auto-winner answers per match, for the cross-scout check.
    const answersByMatch = new Map<string, ("red" | "blue")[]>();
    for (const r of all) {
      if (r.autoWinner === null) continue;
      const list = answersByMatch.get(r.matchId) ?? [];
      list.push(r.autoWinner);
      answersByMatch.set(r.matchId, list);
    }

    const rows: Row[] = [];
    for (const report of all) {
      // A team admin only sees what their own scouts wrote.
      const scout = await profileFor(report.scoutId);
      if (!managesTeam(me, scout?.teamNumber)) continue;
      const match = matchById.get(report.matchId);
      const team = teamById.get(report.teamId);
      if (!match || !team) continue;

      const onRed = match.redTeamNumbers.includes(team.number);
      const alliance: "red" | "blue" = onRed ? "red" : "blue";
      const isWinner =
        report.autoWinner === null ? null : report.autoWinner === alliance;

      const counted =
        isWinner === null
          ? Object.values(report.teleop.byShift).reduce((a, b) => a + b, 0)
          : countedTeleopFuel(report.teleop.byShift, isWinner);
      const dead =
        isWinner === null ? 0 : uncountedTeleopFuel(report.teleop.byShift, isWinner);

      const reasons: FlagReason[] = [];
      if (submittedBeforeMatchEnd(report.matchStartedAt, report.submittedAt)) {
        reasons.push("early");
      }
      if (report.hubStateSource === "none") reasons.push("no-split");
      if (dead > counted && dead > 0) reasons.push("dead-hub");

      const answers = answersByMatch.get(report.matchId) ?? [];
      if (
        report.autoWinner !== null &&
        answers.length > 1 &&
        answers.some((a) => a !== report.autoWinner)
      ) {
        reasons.push("disagreement");
      }

      // A dismissal made before the report was last edited is stale: the edit
      // may be exactly what caused the flag to reappear.
      // Only a flagged report can have a dismissal worth reading, and the
      // flagDismissals table spans every event.
      const dismissalsFor = reasons.length === 0
        ? []
        : await ctx.db
            .query("flagDismissals")
            .withIndex("by_report", (q) => q.eq("reportId", report._id))
            .collect();
      const live = new Map(
        dismissalsFor
          .filter((d) => d.dismissedAt >= report.updatedAt)
          .map((d) => [d.reason, d]),
      );

      const dismissed: Row["dismissed"] = [];
      for (const r of reasons) {
        const d = live.get(r);
        if (!d) continue;
        dismissed.push({
          reason: r,
          label: REASON_LABELS[r],
          note: d.note,
          byName: (await profileFor(d.dismissedBy))?.displayName ?? "Unknown",
          at: d.dismissedAt,
        });
      }

      const activeReasons = reasons.filter((r) => !live.has(r));

      if (args.onlyFlagged && activeReasons.length === 0 && dismissed.length === 0) {
        continue;
      }

      const edits = await ctx.db
        .query("reportEdits")
        .withIndex("by_report", (q) => q.eq("reportId", report._id))
        .collect();

      rows.push({
        reportId: report._id,
        matchNumber: match.matchNumber,
        teamNumber: team.number,
        teamNickname: team.nickname,
        scoutName: scout?.displayName ?? "Unknown scout",
        alliance,
        autoWinner: report.autoWinner,
        counted,
        dead,
        submittedAt: report.submittedAt,
        editCount: edits.length,
        reasons: activeReasons,
        reasonLabels: activeReasons.map((r) => REASON_LABELS[r]),
        dismissed,
      });
    }

    return rows.sort((a, b) => b.submittedAt - a.submittedAt);
  },
});

export const editHistory = query({
  args: { reportId: v.id("matchReports") },
  handler: async (ctx, args) => {
    await requireTeamAdmin(ctx);
    const edits = await ctx.db
      .query("reportEdits")
      .withIndex("by_report", (q) => q.eq("reportId", args.reportId))
      .collect();
    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));
    return edits
      .map((e) => ({ ...e, editorName: nameByUser.get(e.editedBy) ?? "Unknown" }))
      .sort((a, b) => b.editedAt - a.editedAt);
  },
});

/**
 * The highest-value correction available. Because teleop fuel is banked per
 * shift, flipping the auto winner reclassifies counted vs dead fuel without
 * touching a single observation the scout made.
 */
export const setAutoWinner = mutation({
  args: {
    reportId: v.id("matchReports"),
    autoWinner: v.union(v.literal("red"), v.literal("blue")),
    reason: v.string(),
  },
  handler: async (ctx, args) => {
    const admin = await requireTeamAdmin(ctx);
    const reason = args.reason.trim();
    if (reason === "") throw new Error("A reason is required.");

    const report = await ctx.db.get(args.reportId);
    if (!report) throw new Error("That report no longer exists.");
    await assertManagesReport(ctx, admin, report);

    await ctx.db.patch(args.reportId, {
      autoWinner: args.autoWinner,
      updatedAt: Date.now(),
    });
    await refreshTeamSummary(ctx, report.eventId, report.teamId);
    await ctx.db.insert("reportEdits", {
      reportId: args.reportId,
      editedBy: admin.userId,
      editedAt: Date.now(),
      reason: `Auto winner set to ${args.autoWinner}: ${reason}`,
    });
  },
});

/**
 * Loads a report for editing. Allowed for its author or an admin — the same
 * rule matchReports.update enforces, so the form never offers an edit the
 * mutation would then reject.
 */
export const reportForEdit = query({
  args: { reportId: v.id("matchReports") },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const report = await ctx.db.get(args.reportId);
    if (!report) return null;

    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .unique();
    if (report.scoutId !== userId && profile?.role !== "admin") return null;

    return report;
  },
});

export const deleteReport = mutation({
  args: { reportId: v.id("matchReports"), reason: v.string() },
  handler: async (ctx, args) => {
    const admin = await requireTeamAdmin(ctx);
    const reason = args.reason.trim();
    if (reason === "") throw new Error("A reason is required.");

    const report = await ctx.db.get(args.reportId);
    if (!report) throw new Error("That report no longer exists.");
    await assertManagesReport(ctx, admin, report);

    const team = await ctx.db.get(report.teamId);
    const match = await ctx.db.get(report.matchId);
    const profiles = await ctx.db.query("profiles").collect();
    const scoutName =
      profiles.find((p) => p.userId === report.scoutId)?.displayName ?? "Unknown";

    await ctx.db.insert("deletionLog", {
      eventId: report.eventId,
      kind: "matchReport",
      teamNumber: team?.number ?? 0,
      matchNumber: match?.matchNumber ?? null,
      scoutName,
      deletedBy: admin.userId,
      deletedAt: Date.now(),
      reason,
      snapshot: JSON.stringify(report),
      ownerTeamNumber: admin.teamNumber,
    });

    const edits = await ctx.db
      .query("reportEdits")
      .withIndex("by_report", (q) => q.eq("reportId", args.reportId))
      .collect();
    for (const edit of edits) await ctx.db.delete(edit._id);

    await ctx.db.delete(args.reportId);
    await bumpReportCount(ctx, report.eventId, report.teamId, -1);
    await refreshTeamSummary(ctx, report.eventId, report.teamId);
    await refreshMatchTally(ctx, report.eventId, report.matchId);
    await refreshScoutTally(ctx, report.eventId, report.scoutId);
  },
});

/** Pit reports for the active event, with team and scout resolved. */
export const pitReports = query({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) return [];

    const reports = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();

    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    const rows = [];
    for (const report of reports) {
      if (!managesTeam(me, report.scoutingTeamNumber)) continue;
      const team = await ctx.db.get(report.teamId);
      if (!team) continue;
      rows.push({
        pitReportId: report._id,
        teamNumber: team.number,
        teamNickname: team.nickname,
        scoutName: nameByUser.get(report.scoutId) ?? "Unknown scout",
        drivetrain: report.drivetrain,
        updatedAt: report.updatedAt,
      });
    }
    return rows.sort((a, b) => a.teamNumber - b.teamNumber);
  },
});

export const deletePitReport = mutation({
  args: { pitReportId: v.id("pitReports"), reason: v.string() },
  handler: async (ctx, args) => {
    const admin = await requireTeamAdmin(ctx);
    const reason = args.reason.trim();
    if (reason === "") throw new Error("A reason is required.");

    const report = await ctx.db.get(args.pitReportId);
    if (!report) throw new Error("That report no longer exists.");
    if (!managesTeam(admin, report.scoutingTeamNumber)) {
      throw new Error("That pit report belongs to another team.");
    }

    const team = await ctx.db.get(report.teamId);
    const profiles = await ctx.db.query("profiles").collect();
    const scoutName =
      profiles.find((p) => p.userId === report.scoutId)?.displayName ?? "Unknown";

    await ctx.db.insert("deletionLog", {
      eventId: report.eventId,
      kind: "pitReport",
      teamNumber: team?.number ?? 0,
      matchNumber: null,
      scoutName,
      deletedBy: admin.userId,
      deletedAt: Date.now(),
      reason,
      snapshot: JSON.stringify(report),
      ownerTeamNumber: admin.teamNumber,
    });

    await ctx.db.delete(args.pitReportId);
  },
});

/** The deletion trail. Read-only; nothing in the app removes from it. */
export const deletions = query({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) return [];
    const rows = await ctx.db
      .query("deletionLog")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();

    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    return rows
      .filter((r) => managesTeam(me, r.ownerTeamNumber))
      .map((r) => ({ ...r, deletedByName: nameByUser.get(r.deletedBy) ?? "Unknown" }))
      .sort((a, b) => b.deletedAt - a.deletedAt);
  },
});

/**
 * Dismisses one flag on one report. The note is required — a dismissal is an
 * assertion that someone checked, and the next person to read the number needs
 * to know what was checked.
 */
export const dismissFlag = mutation({
  args: {
    reportId: v.id("matchReports"),
    reason: v.string(),
    note: v.string(),
  },
  handler: async (ctx, args) => {
    const admin = await requireTeamAdmin(ctx);
    const note = args.note.trim();
    if (note === "") throw new Error("A note is required.");

    const report = await ctx.db.get(args.reportId);
    if (!report) throw new Error("That report no longer exists.");
    await assertManagesReport(ctx, admin, report);

    const existing = await ctx.db
      .query("flagDismissals")
      .withIndex("by_report_reason", (q) =>
        q.eq("reportId", args.reportId).eq("reason", args.reason))
      .unique();

    if (existing) {
      await ctx.db.patch(existing._id, {
        note,
        dismissedBy: admin.userId,
        dismissedAt: Date.now(),
      });
      return existing._id;
    }

    return await ctx.db.insert("flagDismissals", {
      reportId: args.reportId,
      reason: args.reason,
      note,
      dismissedBy: admin.userId,
      dismissedAt: Date.now(),
    });
  },
});

/** Puts a dismissed flag back. */
export const restoreFlag = mutation({
  args: { reportId: v.id("matchReports"), reason: v.string() },
  handler: async (ctx, args) => {
    await requireTeamAdmin(ctx);
    const existing = await ctx.db
      .query("flagDismissals")
      .withIndex("by_report_reason", (q) =>
        q.eq("reportId", args.reportId).eq("reason", args.reason))
      .unique();
    if (existing) await ctx.db.delete(existing._id);
  },
});

/**
 * Robots a scout reported as broken or inconsistent. Separate from the flagged
 * list: those are doubts about the DATA, these are facts about a ROBOT, and
 * conflating them buries the ones a strategy lead needs before a pick.
 */
export const attentionItems = query({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
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
      if (!managesTeam(me, byUser.get(report.scoutId)?.teamNumber)) continue;
      const team = teamById.get(report.teamId);
      if (!team) continue;

      for (const kind of ["broke", "inconsistent"] as const) {
        if (!report.ratings[kind]) continue;

        // A decision made before the report changed is stale, same rule the
        // flagged list uses.
        const handled = dismissals.find(
          (d) => d.reportId === report._id && d.reason === kind &&
                 d.dismissedAt >= report.updatedAt,
        );
        if (handled) continue;

        rows.push({
          reportId: report._id,
          kind,
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

/** Dismiss ("it was fine") or resolve ("it has been dealt with"). */
export const settleAttention = mutation({
  args: {
    reportId: v.id("matchReports"),
    kind: v.union(v.literal("broke"), v.literal("inconsistent")),
    state: v.union(v.literal("dismissed"), v.literal("resolved")),
    note: v.string(),
  },
  handler: async (ctx, args) => {
    const admin = await requireTeamAdmin(ctx);
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
      dismissedBy: admin.userId,
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

/**
 * Events for the usage card, newest first. Deleted events are left out.
 * Full admins only: the card compares teams, which no single team's admin
 * needs to see.
 */
export const usageEvents = query({
  args: {},
  handler: async (ctx) => {
    await requireAdmin(ctx);
    const events = await ctx.db.query("events").collect();
    return events
      .filter((e) => !e.deletedAt)
      .sort((a, b) => b._creationTime - a._creationTime)
      .map((e) => ({ eventId: e._id, name: e.name, tbaEventKey: e.tbaEventKey }));
  },
});

export type UsageRow = {
  /** Null for scouts with no team number on their profile. */
  teamNumber: number | null;
  scouts: number;
  matchReports: number;
  pitReports: number;
};

/**
 * Scouting activity at one event, per SCOUTING team. Match reports go to the
 * scout's current team; pit reports to the team recorded on the report.
 * Scouts counts people who submitted either kind.
 *
 * Reads every report at the event, so the card calls this once per event on
 * open and on Refresh — never as a live subscription.
 */
export const usageForEvent = query({
  args: { eventId: v.id("events") },
  handler: async (ctx, args): Promise<UsageRow[]> => {
    await requireAdmin(ctx);
    const [reports, pit] = await Promise.all([
      ctx.db.query("matchReports").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("pitReports").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
    ]);

    const teamOf = new Map<Id<"users">, number | null>();
    const scoutTeam = async (userId: Id<"users">): Promise<number | null> => {
      if (!teamOf.has(userId)) {
        const profile = await ctx.db
          .query("profiles")
          .withIndex("by_user", (q) => q.eq("userId", userId))
          .first();
        teamOf.set(userId, profile?.teamNumber ?? null);
      }
      return teamOf.get(userId) ?? null;
    };

    const rows = new Map<number | null, UsageRow & { scoutIds: Set<Id<"users">> }>();
    const rowFor = (teamNumber: number | null) => {
      let row = rows.get(teamNumber);
      if (!row) {
        row = { teamNumber, scouts: 0, matchReports: 0, pitReports: 0, scoutIds: new Set() };
        rows.set(teamNumber, row);
      }
      return row;
    };

    for (const r of reports) {
      const row = rowFor(await scoutTeam(r.scoutId));
      row.matchReports += 1;
      row.scoutIds.add(r.scoutId);
    }
    for (const p of pit) {
      const row = rowFor(p.scoutingTeamNumber ?? (await scoutTeam(p.scoutId)));
      row.pitReports += 1;
      row.scoutIds.add(p.scoutId);
    }

    return [...rows.values()]
      .map(({ scoutIds, ...row }) => ({ ...row, scouts: scoutIds.size }))
      .sort((a, b) => b.matchReports - a.matchReports || b.pitReports - a.pitReports);
  },
});
