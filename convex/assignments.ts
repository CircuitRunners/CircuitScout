import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import {
  activeEvent, currentProfile, managesTeam, requireTeamAdmin, requireUser,
} from "./lib/guards";
import { stationIndex, type Station } from "./lib/types";

const station = v.union(
  v.literal("red1"), v.literal("red2"), v.literal("red3"),
  v.literal("blue1"), v.literal("blue2"), v.literal("blue3"),
);

/** Which team number sits in that station for that match. */
function teamAt(
  match: { redTeamNumbers: number[]; blueTeamNumbers: number[] },
  s: Station,
): number | null {
  const list = s.startsWith("red") ? match.redTeamNumbers : match.blueTeamNumbers;
  return list[stationIndex(s)] ?? null;
}

export const forProfile = query({
  args: { profileId: v.id("profiles") },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) return [];

    const target = await ctx.db.get(args.profileId);
    if (!target || !managesTeam(me, target.teamNumber)) return [];

    const rows = await ctx.db
      .query("matchAssignments")
      .withIndex("by_event_profile", (q) =>
        q.eq("eventId", event._id).eq("profileId", args.profileId))
      .collect();
    return rows.sort((a, b) => a.fromMatch - b.fromMatch);
  },
});

/**
 * Creates one shift per selected scout. Overlaps are refused and the message
 * names the shift in the way — "overlaps an existing shift" leaves an admin
 * hunting through a list on a phone.
 */
export const create = mutation({
  args: {
    profileIds: v.array(v.id("profiles")),
    fromMatch: v.number(),
    toMatch: v.number(),
    station,
  },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const from = Math.min(args.fromMatch, args.toMatch);
    const to = Math.max(args.fromMatch, args.toMatch);
    if (!Number.isInteger(from) || from < 1) throw new Error("Bad match range.");

    for (const profileId of args.profileIds) {
      const target = await ctx.db.get(profileId);
      if (!target) throw new Error("That scout no longer exists.");
      if (!managesTeam(me, target.teamNumber)) {
        throw new Error(`${target.displayName} is not on your team.`);
      }

      const existing = await ctx.db
        .query("matchAssignments")
        .withIndex("by_event_profile", (q) =>
          q.eq("eventId", event._id).eq("profileId", profileId))
        .collect();

      // One scout cannot be in two places, whatever the stations. Switching
      // station mid-event means ending one shift and starting another.
      const clash = existing.find((row) => from <= row.toMatch && to >= row.fromMatch);
      if (clash) {
        throw new Error(
          `${target.displayName} already has quals ${clash.fromMatch}–${clash.toMatch}. End that shift first.`,
        );
      }

      await ctx.db.insert("matchAssignments", {
        eventId: event._id,
        profileId,
        teamNumber: target.teamNumber ?? 0,
        fromMatch: from,
        toMatch: to,
        station: args.station,
        createdAt: Date.now(),
        createdBy: me.userId,
      });
    }

    return { created: args.profileIds.length };
  },
});

export const remove = mutation({
  args: { assignmentId: v.id("matchAssignments") },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const row = await ctx.db.get(args.assignmentId);
    if (!row) return;
    if (!managesTeam(me, row.teamNumber)) {
      throw new Error("That shift is for another team.");
    }
    await ctx.db.delete(args.assignmentId);
  },
});

/** The signed-in scout's own shifts, with progress and what is next. */
export const mine = query({
  args: {},
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);
    const event = await activeEvent(ctx);
    if (!profile || !event) return { shifts: [], upNext: null, assigned: [] };

    const rows = await ctx.db
      .query("matchAssignments")
      .withIndex("by_event_profile", (q) =>
        q.eq("eventId", event._id).eq("profileId", profile._id))
      .collect();

    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const byNumber = new Map(matches.map((m) => [m.matchNumber, m]));

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const teamByNumber = new Map(teams.map((t) => [t.number, t]));

    const myReports = await ctx.db
      .query("matchReports")
      .withIndex("by_scout", (q) => q.eq("scoutId", userId))
      .collect();
    const reportedMatchNumbers = new Set(
      myReports.flatMap((r) => {
        const match = matches.find((m) => m._id === r.matchId);
        return match ? [match.matchNumber] : [];
      }),
    );

    // "Current" is the furthest match anyone has scouted. Distance is measured
    // in matches rather than minutes: scheduled times drift during an event
    // and only refresh on re-import, so a countdown would be confidently wrong.
    const allReports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    let current = 0;
    for (const report of allReports) {
      const match = matches.find((m) => m._id === report.matchId);
      if (match && match.matchNumber > current) current = match.matchNumber;
    }

    const shifts = rows
      .sort((a, b) => a.fromMatch - b.fromMatch)
      .map((row) => {
        let total = 0;
        let done = 0;
        for (let n = row.fromMatch; n <= row.toMatch; n++) {
          if (!byNumber.has(n)) continue;
          total += 1;
          if (reportedMatchNumbers.has(n)) done += 1;
        }
        return {
          assignmentId: row._id,
          fromMatch: row.fromMatch,
          toMatch: row.toMatch,
          station: row.station,
          done,
          total,
        };
      });

    // Every assigned match number, so the scouting list can highlight them.
    const assigned: { matchNumber: number; station: Station; teamNumber: number | null }[] = [];
    for (const row of rows) {
      for (let n = row.fromMatch; n <= row.toMatch; n++) {
        const match = byNumber.get(n);
        if (!match) continue;
        assigned.push({
          matchNumber: n,
          station: row.station,
          teamNumber: teamAt(match, row.station),
        });
      }
    }
    assigned.sort((a, b) => a.matchNumber - b.matchNumber);

    const next = assigned.find(
      (a) => !reportedMatchNumbers.has(a.matchNumber) && a.matchNumber > current,
    ) ?? assigned.find((a) => !reportedMatchNumbers.has(a.matchNumber)) ?? null;

    const upNext = next
      ? {
          matchNumber: next.matchNumber,
          station: next.station,
          teamNumber: next.teamNumber,
          nickname: next.teamNumber
            ? (teamByNumber.get(next.teamNumber)?.nickname ?? null)
            : null,
          matchesAway: Math.max(0, next.matchNumber - current),
        }
      : null;

    return { shifts, upNext, assigned };
  },
});
