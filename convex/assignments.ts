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

    // Match numbers this scout has reported here. Scoped to the event by the
    // index; by_scout alone pulled in every event the scout ever worked.
    const matchById = new Map(matches.map((m) => [m._id, m]));
    const myReports = await ctx.db
      .query("matchReports")
      .withIndex("by_scout_event", (q) =>
        q.eq("scoutId", userId).eq("eventId", event._id))
      .collect();
    const reportedMatchNumbers = new Set(
      myReports.flatMap((r) => {
        const match = matchById.get(r.matchId);
        return match ? [match.matchNumber] : [];
      }),
    );

    // "Current" is the furthest match anyone has reported. Pooled across
    // scouts — scout 1 finishing qual 12 moves everyone on to 13 — and your
    // own submission always advances your own card. TBA results deliberately
    // do not count: a refresh landing mid-shift would jump the card past
    // matches still waiting to be scouted. Distance stays in matches rather
    // than minutes, because scheduled times drift during an event.
    //
    // Walk down from the last match and stop at the first one with a report.
    // An unplayed match costs an empty index read. This used to collect every
    // report at the event, so each submission re-read all of them on every
    // phone with the dashboard open — the single largest I/O cost.
    let current = 0;
    const newestFirst = [...matches].sort((a, b) => b.matchNumber - a.matchNumber);
    for (const match of newestFirst) {
      const hit = await ctx.db
        .query("matchReports")
        .withIndex("by_match", (q) => q.eq("matchId", match._id))
        .first();
      if (hit) {
        current = match.matchNumber;
        break;
      }
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
      (a) => a.matchNumber > current && !reportedMatchNumbers.has(a.matchNumber),
    ) ?? null;

    // Once a shift runs out the card stays, naming the match the event has
    // moved on to. A scout whose assignment is finished should see the
    // schedule advancing rather than an empty space where the card was.
    const upcomingNumber = matches
      .map((m) => m.matchNumber)
      .filter((n) => n > current)
      .sort((a, b) => a - b)[0] ?? null;

    // One team row for the card, rather than the whole roster.
    const nextTeamNumber = next?.teamNumber ?? null;
    const nextNickname = nextTeamNumber === null
      ? null
      : ((await ctx.db
          .query("teams")
          .withIndex("by_event_number", (q) =>
            q.eq("eventId", event._id).eq("number", nextTeamNumber))
          .first())?.nickname ?? null);

    const upNext: {
      matchNumber: number;
      /** Null when nothing is assigned: no badge, no robot, no button. */
      station: Station | null;
      teamNumber: number | null;
      nickname: string | null;
      matchesAway: number;
      assigned: boolean;
    } | null = next
      ? {
          matchNumber: next.matchNumber,
          station: next.station,
          teamNumber: next.teamNumber,
          nickname: nextNickname,
          matchesAway: Math.max(0, next.matchNumber - current),
          assigned: true,
        }
      : upcomingNumber === null
        ? null
        : {
            matchNumber: upcomingNumber,
            station: null,
            teamNumber: null,
            nickname: null,
            matchesAway: Math.max(0, upcomingNumber - current),
            assigned: false,
          };

    return { shifts, upNext, assigned };
  },
});

/**
 * Several shifts for several scouts in one pass.
 *
 * Unlike `create`, a clash does not abort the batch. The shift is skipped for
 * that one scout and reported back, because one person holding a stray shift
 * should not stop the other seven from being assigned. The caller is expected
 * to show the skips somewhere that stays on screen.
 *
 * Overlaps within `shifts` are a different matter — every scout gets all of
 * them, so a clash there is wrong for everyone and is refused outright.
 */
export const createMany = mutation({
  args: {
    profileIds: v.array(v.id("profiles")),
    shifts: v.array(v.object({
      fromMatch: v.number(),
      toMatch: v.number(),
      station,
    })),
  },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");
    if (args.profileIds.length === 0) throw new Error("Pick at least one scout.");
    if (args.shifts.length === 0) throw new Error("Add at least one shift.");

    const wanted = args.shifts
      .map((s) => ({
        fromMatch: Math.min(s.fromMatch, s.toMatch),
        toMatch: Math.max(s.fromMatch, s.toMatch),
        station: s.station,
      }))
      .sort((a, b) => a.fromMatch - b.fromMatch);

    for (const s of wanted) {
      if (!Number.isInteger(s.fromMatch) || s.fromMatch < 1) {
        throw new Error("Bad match range.");
      }
    }

    // Sorted, so each shift only has to clear the one before it.
    let previous: { fromMatch: number; toMatch: number } | null = null;
    for (const s of wanted) {
      if (previous && s.fromMatch <= previous.toMatch) {
        throw new Error(
          `Quals ${previous.fromMatch}–${previous.toMatch} and ${s.fromMatch}–${s.toMatch} overlap each other.`,
        );
      }
      previous = s;
    }

    const skipped: {
      displayName: string;
      fromMatch: number;
      toMatch: number;
      station: Station;
      reason: string;
    }[] = [];
    let created = 0;

    for (const profileId of args.profileIds) {
      const target = await ctx.db.get(profileId);
      if (!target) {
        for (const s of wanted) {
          skipped.push({ displayName: "A removed scout", ...s, reason: "no longer exists" });
        }
        continue;
      }
      if (!managesTeam(me, target.teamNumber)) {
        for (const s of wanted) {
          skipped.push({ displayName: target.displayName, ...s, reason: "is not on your team" });
        }
        continue;
      }

      const existing = await ctx.db
        .query("matchAssignments")
        .withIndex("by_event_profile", (q) =>
          q.eq("eventId", event._id).eq("profileId", profileId))
        .collect();

      // Grows as we insert, so two staged shifts cannot both land on the same
      // gap in one run.
      const held = existing.map((row) => ({
        fromMatch: row.fromMatch,
        toMatch: row.toMatch,
      }));

      for (const s of wanted) {
        const clash = held.find(
          (row) => s.fromMatch <= row.toMatch && s.toMatch >= row.fromMatch);
        if (clash) {
          skipped.push({
            displayName: target.displayName,
            ...s,
            reason: `already has quals ${clash.fromMatch}–${clash.toMatch}`,
          });
          continue;
        }

        await ctx.db.insert("matchAssignments", {
          eventId: event._id,
          profileId,
          teamNumber: target.teamNumber ?? 0,
          fromMatch: s.fromMatch,
          toMatch: s.toMatch,
          station: s.station,
          createdAt: Date.now(),
          createdBy: me.userId,
        });
        held.push({ fromMatch: s.fromMatch, toMatch: s.toMatch });
        created += 1;
      }
    }

    return {
      created,
      attempted: args.profileIds.length * wanted.length,
      skipped,
    };
  },
});
