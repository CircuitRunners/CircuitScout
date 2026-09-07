import { v } from "convex/values";
import { internalMutation, mutation, query } from "./_generated/server";
import {
  activeEvent, activeEventForTeam, currentProfile, managesTeam,
  requireAdmin, requireTeamAdmin,
} from "./lib/guards";
import type { Id } from "./_generated/dataModel";

export const active = query({
  args: {},
  handler: async (ctx) => await activeEvent(ctx),
});

export const list = query({
  args: {},
  handler: async (ctx) => {
    const events = await ctx.db.query("events").collect();
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
      const reports = await ctx.db
        .query("matchReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const pit = await ctx.db
        .query("pitReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const lists = await ctx.db
        .query("pickLists")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      let entryCount = 0;
      for (const list of lists) {
        const entries = await ctx.db
          .query("pickListEntries")
          .withIndex("by_list", (q) => q.eq("pickListId", list._id))
          .collect();
        entryCount += entries.length;
      }

      const settings = (await ctx.db.query("teamSettings").collect())
        .filter((t) => t.activeEventId === event._id)
        .map((t) => t.teamNumber)
        .sort((a, b) => a - b);

      withCounts.push({
        ...event,
        activeForTeams: settings,
        teamCount: teams.length,
        matchCount: matches.length,
        reportCount: reports.length,
        pitCount: pit.length,
        entryCount,
        // Teams and the schedule come back from TBA in one click. Scouting
        // data does not, so anything holding it is not removable.
        removable: reports.length === 0 && pit.length === 0 && entryCount === 0,
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
      const claims = await ctx.db
        .query("matchClaims")
        .withIndex("by_match_team", (q) => q.eq("matchId", match._id))
        .collect();
      for (const claim of claims) await ctx.db.delete(claim._id);
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
