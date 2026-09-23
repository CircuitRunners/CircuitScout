import { v } from "convex/values";
import { internalMutation, mutation, query } from "./_generated/server";
import {
  activeEvent, activeEventForTeam, currentProfile, managesTeam,
  requireAdmin, requireTeamAdmin,
} from "./lib/guards";
import { seedPrimaryEntries } from "./pickLists";
import type { Id } from "./_generated/dataModel";
import { internal } from "./_generated/api";
import { reportCountsFor } from "./lib/reportCounts";
import { refreshTeamSummary } from "./lib/teamSummaries";
import { refreshMatchTally, refreshScoutTally } from "./lib/coverage";
import type { MutationCtx } from "./_generated/server";

export const active = query({
  args: {},
  handler: async (ctx) => await activeEvent(ctx),
});

export const list = query({
  args: {},
  handler: async (ctx) => {
    const events = await ctx.db.query("events").collect();
    // Read once. This used to be re-read inside the loop, once per event.
    const allSettings = await ctx.db.query("teamSettings").collect();
    const withCounts = [];
    for (const event of events) {
      const teams = await ctx.db
        .query("teams")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const matches = await ctx.db
        .query("matches")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      // The count comes from reportCounts. Whether the event is removable is
      // checked against the reports themselves: a stale counter must never
      // make scouting data look deletable.
      let reportCount = 0;
      for (const n of (await reportCountsFor(ctx, event._id)).values()) reportCount += n;
      const anyReport = await ctx.db
        .query("matchReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .first();
      const pit = await ctx.db
        .query("pitReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const lists = await ctx.db
        .query("pickLists")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      // Only "is there any" matters here, so stop at the first entry found.
      let hasEntries = false;
      for (const list of lists) {
        const entry = await ctx.db
          .query("pickListEntries")
          .withIndex("by_list", (q) => q.eq("pickListId", list._id))
          .first();
        if (entry) { hasEntries = true; break; }
      }

      const settings = allSettings
        .filter((t) => t.activeEventId === event._id)
        .map((t) => t.teamNumber)
        .sort((a, b) => a - b);

      withCounts.push({
        ...event,
        deletedAt: event.deletedAt ?? null,
        activeForTeams: settings,
        teamCount: teams.length,
        matchCount: matches.length,
        reportCount,
        pitCount: pit.length,
        // Teams and the schedule come back from TBA in one click. Scouting
        // data does not, so anything holding it is not removable.
        removable: anyReport === null && pit.length === 0 && !hasEntries,
      });
    }
    return withCounts.sort((a, b) => b._creationTime - a._creationTime);
  },
});

/**
 * Points one team at one event. A full admin can do this for any team; a team
 * admin only for their own.
 */
export const setActiveForTeam = mutation({
  args: { eventId: v.union(v.id("events"), v.null()), teamNumber: v.number() },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    if (!managesTeam(me, args.teamNumber)) {
      throw new Error("That is not your team.");
    }

    const existing = await ctx.db
      .query("teamSettings")
      .withIndex("by_team", (q) => q.eq("teamNumber", args.teamNumber))
      .unique();

    if (existing) {
      await ctx.db.patch(existing._id, {
        activeEventId: args.eventId,
        updatedAt: Date.now(),
        updatedBy: me.userId,
      });
      return existing._id;
    }
    return await ctx.db.insert("teamSettings", {
      teamNumber: args.teamNumber,
      activeEventId: args.eventId,
      updatedAt: Date.now(),
      updatedBy: me.userId,
    });
  },
});

/** Every team's current choice. Scoped for team admins, full for admins. */
export const teamSettings = query({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
    const rows = await ctx.db.query("teamSettings").collect();
    const events = await ctx.db.query("events").collect();
    const byId = new Map(events.map((e) => [e._id, e]));

    return rows
      .filter((row) => managesTeam(me, row.teamNumber))
      .map((row) => ({
        teamNumber: row.teamNumber,
        eventName: row.activeEventId ? (byId.get(row.activeEventId)?.name ?? null) : null,
        eventKey: row.activeEventId ? (byId.get(row.activeEventId)?.tbaEventKey ?? null) : null,
        activeEventId: row.activeEventId,
      }))
      .sort((a, b) => a.teamNumber - b.teamNumber);
  },
});

/** My team's current event, for the header and the dashboard. */
export const myTeamActive = query({
  args: {},
  handler: async (ctx) => {
    const profile = await currentProfile(ctx);
    if (!profile?.teamNumber) return null;
    const event = await activeEventForTeam(ctx, profile.teamNumber);
    return event ? { ...event, teamNumber: profile.teamNumber } : null;
  },
});

const teamInput = v.object({
  tbaTeamKey: v.string(),
  number: v.number(),
  nickname: v.string(),
  city: v.string(),
  stateProv: v.string(),
  country: v.string(),
});

const matchInput = v.object({
  tbaMatchKey: v.string(),
  matchNumber: v.number(),
  redTeamNumbers: v.array(v.number()),
  blueTeamNumbers: v.array(v.number()),
  scheduledTime: v.union(v.number(), v.null()),
  predictedTime: v.union(v.number(), v.null()),
  actualTime: v.union(v.number(), v.null()),
  redScore: v.union(v.number(), v.null()),
  blueScore: v.union(v.number(), v.null()),
  winningAlliance: v.string(),
});

/**
 * Upserts an event's teams and qualification schedule.
 *
 * Removal is deliberately conservative: a team or match that has disappeared
 * from TBA is only deleted when nothing references it. Withdrawn teams with
 * scouting data stay, because silently deleting a report a scout spent a match
 * writing is worse than a stale row on the pick list.
 */
export const applyImport = internalMutation({
  args: {
    tbaEventKey: v.string(),
    name: v.string(),
    importedBy: v.id("users"),
    teams: v.array(teamInput),
    matches: v.array(matchInput),
  },
  handler: async (ctx, args) => {
    let event = await ctx.db
      .query("events")
      .withIndex("by_key", (q) => q.eq("tbaEventKey", args.tbaEventKey))
      .unique();

    let eventId: Id<"events">;
    if (event) {
      eventId = event._id;
      await ctx.db.patch(eventId, {
        name: args.name,
        importedAt: Date.now(),
        importedBy: args.importedBy,
      });
    } else {
      eventId = await ctx.db.insert("events", {
        tbaEventKey: args.tbaEventKey,
        name: args.name,
        isActive: false,
        importedAt: Date.now(),
        importedBy: args.importedBy,
      });
    }

    // ---- teams ----
    const existingTeams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", eventId))
      .collect();
    const teamByKey = new Map(existingTeams.map((t) => [t.tbaTeamKey, t]));
    const incomingTeamKeys = new Set(args.teams.map((t) => t.tbaTeamKey));

    let teamsAdded = 0;
    let teamsUpdated = 0;
    for (const t of args.teams) {
      const existing = teamByKey.get(t.tbaTeamKey);
      if (existing) {
        await ctx.db.patch(existing._id, {
          number: t.number,
          nickname: t.nickname,
          city: t.city,
          stateProv: t.stateProv,
          country: t.country,
        });
        teamsUpdated++;
      } else {
        await ctx.db.insert("teams", { eventId, ...t });
        teamsAdded++;
      }
    }

    let teamsRemoved = 0;
    let teamsKept = 0;
    for (const existing of existingTeams) {
      if (incomingTeamKeys.has(existing.tbaTeamKey)) continue;
      const pit = await ctx.db
        .query("pitReports")
        .withIndex("by_event_team", (q) =>
          q.eq("eventId", eventId).eq("teamId", existing._id))
        .first();
      const report = await ctx.db
        .query("matchReports")
        .withIndex("by_event_team", (q) =>
          q.eq("eventId", eventId).eq("teamId", existing._id))
        .first();
      if (pit === null && report === null) {
        await ctx.db.delete(existing._id);
        teamsRemoved++;
      } else {
        teamsKept++;
      }
    }

    // ---- matches ----
    const existingMatches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", eventId))
      .collect();
    const matchByKey = new Map(existingMatches.map((m) => [m.tbaMatchKey, m]));
    const incomingMatchKeys = new Set(args.matches.map((m) => m.tbaMatchKey));

    let matchesAdded = 0;
    let matchesUpdated = 0;
    for (const m of args.matches) {
      const existing = matchByKey.get(m.tbaMatchKey);
      if (existing) {
        await ctx.db.patch(existing._id, {
          matchNumber: m.matchNumber,
          redTeamNumbers: m.redTeamNumbers,
          blueTeamNumbers: m.blueTeamNumbers,
          scheduledTime: m.scheduledTime,
          predictedTime: m.predictedTime,
          actualTime: m.actualTime,
          redScore: m.redScore,
          blueScore: m.blueScore,
          winningAlliance: m.winningAlliance,
        });
        matchesUpdated++;
      } else {
        await ctx.db.insert("matches", { eventId, ...m });
        matchesAdded++;
      }
    }

    let matchesRemoved = 0;
    for (const existing of existingMatches) {
      if (incomingMatchKeys.has(existing.tbaMatchKey)) continue;
      const report = await ctx.db
        .query("matchReports")
        .withIndex("by_match", (q) => q.eq("matchId", existing._id))
        .first();
      if (report === null) {
        await ctx.db.delete(existing._id);
        matchesRemoved++;
      }
    }

    // Teams added by a re-import should appear on the primary list without
    // anyone remembering to top it up.
    const primaries = (
      await ctx.db
        .query("pickLists")
        .withIndex("by_event", (q) => q.eq("eventId", eventId))
        .collect()
    ).filter((l) => l.ownerId === null);
    for (const list of primaries) {
      await seedPrimaryEntries(ctx, eventId, list._id);
    }

    // A revised schedule can move a team to the other alliance, which
    // changes which of its fuel counted.
    await ctx.scheduler.runAfter(0, internal.events.rebuildTeamSummaries, { eventId });

    return {
      eventId,
      name: args.name,
      teamsAdded, teamsUpdated, teamsRemoved, teamsKept,
      matchesAdded, matchesUpdated, matchesRemoved,
    };
  },
});

/**
 * Stands the event down without touching a row. Everything is preserved and
 * setActive brings it straight back — this is for "we are done for today",
 * not for cleanup.
 */
export const setInactive = mutation({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) throw new Error("That event no longer exists.");
    await ctx.db.patch(args.eventId, { isActive: false });
  },
});

/**
 * Removes an imported event and the TBA data that came with it. Refuses while
 * any scouting data exists, rather than offering a force flag — a destructive
 * override on a shared tool at a competition is a trap.
 */
export const remove = mutation({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) throw new Error("That event no longer exists.");

    const usedBy = (await ctx.db.query("teamSettings").collect())
      .filter((t) => t.activeEventId === args.eventId)
      .map((t) => t.teamNumber);
    if (usedBy.length > 0) {
      throw new Error(
        `Team ${usedBy.join(", ")} still has that event active. They have to switch first.`,
      );
    }

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    if (reports.length > 0 || pit.length > 0) {
      throw new Error(
        `${event.name} holds ${reports.length} match and ${pit.length} pit reports. Nothing with scouting data can be removed.`,
      );
    }

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const list of lists) {
      const entries = await ctx.db
        .query("pickListEntries")
        .withIndex("by_list", (q) => q.eq("pickListId", list._id))
        .collect();
      if (entries.length > 0) {
        throw new Error("A pick list for that event has teams on it.");
      }
    }

    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const match of matches) {
      await ctx.db.delete(match._id);
    }

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const team of teams) await ctx.db.delete(team._id);

    for (const list of lists) await ctx.db.delete(list._id);

    await ctx.db.delete(args.eventId);
    return { teams: teams.length, matches: matches.length };
  },
});

/** Exactly what a purge would destroy. Read-only; nothing acts on this. */
export const purgePreview = query({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) return null;

    const [teams, matches, reports, pit, lists, settings] = await Promise.all([
      ctx.db.query("teams").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("matches").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("matchReports").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("pitReports").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("pickLists").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("teamSettings").collect(),
    ]);

    const scouts = new Set(reports.map((r) => r.scoutId));
    const activeFor = settings
      .filter((t) => t.activeEventId === args.eventId)
      .map((t) => t.teamNumber);

    return {
      eventKey: event.tbaEventKey,
      name: event.name,
      teams: teams.length,
      matches: matches.length,
      matchReports: reports.length,
      pitReports: pit.length,
      pickLists: lists.length,
      contributingScouts: scouts.size,
      activeFor,
    };
  },
});

/**
 * Deletes an event and everything attached to it. Full admins only, and
 * separate from events.remove so the safe path stays safe.
 *
 * Order matters: children before parents, so a failure part-way leaves
 * orphaned rows rather than rows pointing at an event that no longer exists.
 */
export const RECOVERY_WINDOW_MS = 24 * 60 * 60 * 1000;

/** Shared by the immediate purge and the scheduled one. */
async function purgeEventData(ctx: MutationCtx, eventId: Id<"events">) {
  const args = { eventId };
  const counts = { matchReports: 0, pitReports: 0, entries: 0, lists: 0, matches: 0, teams: 0 };

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const report of reports) {
      const edits = await ctx.db
        .query("reportEdits")
        .withIndex("by_report", (q) => q.eq("reportId", report._id))
        .collect();
      for (const edit of edits) await ctx.db.delete(edit._id);
      const dismissals = await ctx.db
        .query("flagDismissals")
        .withIndex("by_report", (q) => q.eq("reportId", report._id))
        .collect();
      for (const row of dismissals) await ctx.db.delete(row._id);
      await ctx.db.delete(report._id);
      counts.matchReports += 1;
    }

    const counters = await ctx.db
      .query("reportCounts")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of counters) await ctx.db.delete(row._id);
    const summaries = await ctx.db
      .query("teamSummaries")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of summaries) await ctx.db.delete(row._id);
    const matchTallies = await ctx.db
      .query("matchTallies")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of matchTallies) await ctx.db.delete(row._id);
    const scoutTallies = await ctx.db
      .query("scoutTallies")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of scoutTallies) await ctx.db.delete(row._id);

    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of pit) { await ctx.db.delete(row._id); counts.pitReports += 1; }

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const list of lists) {
      const entries = await ctx.db
        .query("pickListEntries")
        .withIndex("by_list", (q) => q.eq("pickListId", list._id))
        .collect();
      for (const entry of entries) { await ctx.db.delete(entry._id); counts.entries += 1; }
      await ctx.db.delete(list._id);
      counts.lists += 1;
    }

    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const match of matches) {
      await ctx.db.delete(match._id);
      counts.matches += 1;
    }

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const team of teams) { await ctx.db.delete(team._id); counts.teams += 1; }

    // Any team pointing at this event is left with none rather than a
    // dangling id, so their app says "no active event" instead of breaking.
    const settings = await ctx.db.query("teamSettings").collect();
    for (const row of settings) {
      if (row.activeEventId === args.eventId) {
        await ctx.db.patch(row._id, { activeEventId: null, updatedAt: Date.now() });
      }
    }

    
  await ctx.db.delete(args.eventId);
  return counts;
}

/**
 * Marks the event deleted. Nothing is destroyed yet — every table is scoped by
 * eventId, so hiding the event hides its data, and the teamSettings pointer is
 * deliberately left alone so recovery restores the team's event too.
 */
export const softDelete = mutation({
  args: { eventId: v.id("events"), confirmKey: v.string() },
  handler: async (ctx, args) => {
    const me = await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) throw new Error("That event no longer exists.");
    if (args.confirmKey.trim() !== event.tbaEventKey) {
      throw new Error("The event key does not match.");
    }
    await ctx.db.patch(args.eventId, {
      deletedAt: Date.now(),
      deletedBy: me.userId,
    });
  },
});

export const recover = mutation({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) throw new Error("That event is gone for good.");
    await ctx.db.patch(args.eventId, { deletedAt: null, deletedBy: null });
    return { name: event.name };
  },
});

/** Runs hourly. Anything past the window goes for real. */
export const purgeExpired = internalMutation({
  args: {},
  handler: async (ctx) => {
    const cutoff = Date.now() - RECOVERY_WINDOW_MS;
    const events = await ctx.db.query("events").collect();
    let purged = 0;
    for (const event of events) {
      if (!event.deletedAt || event.deletedAt > cutoff) continue;
      await purgeEventData(ctx, event._id);
      purged += 1;
    }
    return { purged };
  },
});

/** Skips the wait. Same confirmation, no recovery. */
export const purgeNow = mutation({
  args: { eventId: v.id("events"), confirmKey: v.string() },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) throw new Error("That event no longer exists.");
    if (args.confirmKey.trim() !== event.tbaEventKey) {
      throw new Error("The event key does not match.");
    }
    return await purgeEventData(ctx, args.eventId);
  },
});

/** Patches score and timing fields on existing matches. Adds nothing. */
export const applyScores = internalMutation({
  args: {
    tbaEventKey: v.string(),
    rows: v.array(v.object({
      tbaMatchKey: v.string(),
      scheduledTime: v.union(v.number(), v.null()),
      predictedTime: v.union(v.number(), v.null()),
      actualTime: v.union(v.number(), v.null()),
      redScore: v.union(v.number(), v.null()),
      blueScore: v.union(v.number(), v.null()),
      winningAlliance: v.string(),
    })),
  },
  handler: async (ctx, args) => {
    const event = await ctx.db
      .query("events")
      .withIndex("by_key", (q) => q.eq("tbaEventKey", args.tbaEventKey))
      .unique();
    if (!event) return { updated: 0 };

    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const byKey = new Map(matches.map((m) => [m.tbaMatchKey, m]));

    let updated = 0;
    for (const row of args.rows) {
      const match = byKey.get(row.tbaMatchKey);
      if (!match) continue;
      await ctx.db.patch(match._id, {
        scheduledTime: row.scheduledTime,
        predictedTime: row.predictedTime,
        actualTime: row.actualTime,
        redScore: row.redScore,
        blueScore: row.blueScore,
        winningAlliance: row.winningAlliance,
      });
      updated += 1;
    }
    return { updated };
  },
});

/**
 * Recount one event's match reports from scratch. The counter table is a
 * cache of the reports, so this is always safe to run — after deploying the
 * table, or any time a count looks wrong.
 */
export const rebuildReportCounts = internalMutation({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    const tally = new Map<Id<"teams">, number>();
    for (const r of reports) tally.set(r.teamId, (tally.get(r.teamId) ?? 0) + 1);

    const existing = await ctx.db
      .query("reportCounts")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of existing) await ctx.db.delete(row._id);
    for (const [teamId, count] of tally) {
      await ctx.db.insert("reportCounts", { eventId: args.eventId, teamId, count });
    }
    return { reports: reports.length, teams: tally.size };
  },
});

/**
 * Recount every event, one mutation per event so a season's worth of reports
 * never lands in a single transaction.
 *   bunx convex run events:rebuildAllReportCounts          (dev)
 *   bunx convex run --prod events:rebuildAllReportCounts   (prod)
 */
export const rebuildAllReportCounts = internalMutation({
  args: {},
  handler: async (ctx) => {
    const events = await ctx.db.query("events").collect();
    for (const event of events) {
      await ctx.scheduler.runAfter(0, internal.events.rebuildReportCounts, {
        eventId: event._id,
      });
    }
    return { scheduled: events.length };
  },
});

/**
 * Rewrite every stored team summary at one event from its reports. Always
 * safe to run: after deploying the table, after a re-import (scheduled
 * automatically), or whenever a team's stats look wrong.
 */
export const rebuildTeamSummaries = internalMutation({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    const existing = await ctx.db
      .query("teamSummaries")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    // Rows for teams no longer at the event, then one refresh per team.
    const current = new Set(teams.map((t) => t._id));
    for (const row of existing) {
      if (!current.has(row.teamId)) await ctx.db.delete(row._id);
    }
    for (const team of teams) await refreshTeamSummary(ctx, args.eventId, team._id);
    return { teams: teams.length };
  },
});

/**
 * Rebuild every event, one mutation per event.
 *   bunx convex run events:rebuildAllTeamSummaries          (dev)
 *   bunx convex run --prod events:rebuildAllTeamSummaries   (prod)
 */
export const rebuildAllTeamSummaries = internalMutation({
  args: {},
  handler: async (ctx) => {
    const events = await ctx.db.query("events").collect();
    for (const event of events) {
      await ctx.scheduler.runAfter(0, internal.events.rebuildTeamSummaries, {
        eventId: event._id,
      });
    }
    return { scheduled: events.length };
  },
});

/**
 * Rewrite one event's match and scout tallies from its reports. Always safe
 * to run: after deploying the tables, or whenever coverage looks wrong.
 */
export const rebuildCoverage = internalMutation({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    const [matches, reports, matchRows, scoutRows] = await Promise.all([
      ctx.db.query("matches").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("matchReports").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("matchTallies").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("scoutTallies").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
    ]);

    // Every match on the schedule or holding a row, and every scout with a
    // report or a row: refreshing each rewrites or removes it.
    const matchIds = new Set([...matches.map((m) => m._id), ...matchRows.map((r) => r.matchId)]);
    for (const matchId of matchIds) await refreshMatchTally(ctx, args.eventId, matchId);
    const scoutIds = new Set([...reports.map((r) => r.scoutId), ...scoutRows.map((r) => r.scoutId)]);
    for (const scoutId of scoutIds) await refreshScoutTally(ctx, args.eventId, scoutId);

    return { matches: matchIds.size, scouts: scoutIds.size };
  },
});

/**
 * Rebuild every event's tallies, one mutation per event.
 *   bunx convex run --prod events:rebuildAllCoverage
 */
export const rebuildAllCoverage = internalMutation({
  args: {},
  handler: async (ctx) => {
    const events = await ctx.db.query("events").collect();
    for (const event of events) {
      await ctx.scheduler.runAfter(0, internal.events.rebuildCoverage, { eventId: event._id });
    }
    return { scheduled: events.length };
  },
});

/**
 * Everything the io patches store, rebuilt for every event: report counts,
 * team summaries and coverage tallies. The one command to run on prod after
 * deploying any of them.
 *   bunx convex run --prod events:rebuildAllDerived
 */
export const rebuildAllDerived = internalMutation({
  args: {},
  handler: async (ctx) => {
    const events = await ctx.db.query("events").collect();
    for (const event of events) {
      const args = { eventId: event._id };
      await ctx.scheduler.runAfter(0, internal.events.rebuildReportCounts, args);
      await ctx.scheduler.runAfter(0, internal.events.rebuildTeamSummaries, args);
      await ctx.scheduler.runAfter(0, internal.events.rebuildCoverage, args);
    }
    return { events: events.length };
  },
});
