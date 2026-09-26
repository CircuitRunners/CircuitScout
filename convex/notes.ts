import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import type { QueryCtx } from "./_generated/server";
import type { Doc, Id } from "./_generated/dataModel";
import {
  activeEvent, currentProfile, currentTeamNumber, managesTeam, requireTeamAdmin, requireUser,
} from "./lib/guards";
import { stationIndex, type Station } from "./lib/types";

/**
 * Notes-only scouting: what the app offers for a season it has no forms for.
 * Everything here reads and writes pitNotes and matchNotes only. The 2026
 * tables (pitReports, matchReports and everything summarised from them) are
 * never touched, and nothing in the 2026 code reads these.
 */

const MAX_NOTE = 5000;

function cleanNote(notes: string): string {
  const text = notes.trim();
  if (text === "") throw new Error("Write something first.");
  if (text.length > MAX_NOTE) throw new Error(`Notes are limited to ${MAX_NOTE} characters.`);
  return text;
}

async function teamByNumber(ctx: QueryCtx, eventId: Id<"events">, number: number) {
  return await ctx.db
    .query("teams")
    .withIndex("by_event_number", (q) => q.eq("eventId", eventId).eq("number", number))
    .unique();
}

async function matchByNumber(ctx: QueryCtx, eventId: Id<"events">, matchNumber: number) {
  return await ctx.db
    .query("matches")
    .withIndex("by_event_number", (q) => q.eq("eventId", eventId).eq("matchNumber", matchNumber))
    .first();
}

async function namesByUser(ctx: QueryCtx): Promise<Map<Id<"users">, string>> {
  const profiles = await ctx.db.query("profiles").collect();
  return new Map(profiles.map((p) => [p.userId, p.displayName]));
}

function allianceOf(match: Doc<"matches">, teamNumber: number): "red" | "blue" | null {
  if (match.redTeamNumbers.includes(teamNumber)) return "red";
  if (match.blueTeamNumbers.includes(teamNumber)) return "blue";
  return null;
}

// ─── Pit ───────────────────────────────────────────────────────────────────

/** The event's teams, and which ones your team has pit notes for. */
export const teams = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    const myTeam = await currentTeamNumber(ctx);
    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const pit = await ctx.db
      .query("pitNotes")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const noted = new Set(
      pit.filter((p) => p.scoutingTeamNumber === myTeam).map((p) => p.teamId),
    );
    return teams
      .sort((a, b) => a.number - b.number)
      .map((t) => ({
        teamId: t._id,
        number: t.number,
        nickname: t.nickname,
        pitNoted: noted.has(t._id),
      }));
  },
});

/** Your team's pit note for one team: one per team per scouting team. */
export const pitNote = query({
  args: { teamNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    const team = await teamByNumber(ctx, event._id, args.teamNumber);
    if (!team) return null;
    const myTeam = await currentTeamNumber(ctx);
    const row = (
      await ctx.db
        .query("pitNotes")
        .withIndex("by_event_team", (q) => q.eq("eventId", event._id).eq("teamId", team._id))
        .collect()
    ).find((p) => p.scoutingTeamNumber === myTeam) ?? null;
    const names = row ? await namesByUser(ctx) : null;
    return {
      teamNumber: team.number,
      nickname: team.nickname,
      note: row
        ? {
            notes: row.notes,
            updatedAt: row.updatedAt,
            scoutName: names?.get(row.scoutId) ?? "Unknown scout",
          }
        : null,
    };
  },
});

export const savePit = mutation({
  args: { teamNumber: v.number(), notes: v.string() },
  handler: async (ctx, args) => {
    const scoutId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");
    const scoutingTeamNumber = await currentTeamNumber(ctx);
    if (scoutingTeamNumber === undefined) {
      throw new Error("Set your team number on your profile first.");
    }
    const team = await teamByNumber(ctx, event._id, args.teamNumber);
    if (!team) throw new Error("That team is not part of the active event.");
    const notes = cleanNote(args.notes);

    const existing = (
      await ctx.db
        .query("pitNotes")
        .withIndex("by_event_team", (q) => q.eq("eventId", event._id).eq("teamId", team._id))
        .collect()
    ).find((p) => p.scoutingTeamNumber === scoutingTeamNumber);

    const fields = { notes, scoutId, scoutingTeamNumber, updatedAt: Date.now() };
    if (existing) {
      await ctx.db.patch(existing._id, fields);
      return existing._id;
    }
    return await ctx.db.insert("pitNotes", { eventId: event._id, teamId: team._id, ...fields });
  },
});

// ─── Match ─────────────────────────────────────────────────────────────────

/** Your own note on one robot in one match, if you wrote one. */
export const matchNote = query({
  args: { matchNumber: v.number(), teamNumber: v.number() },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) return null;
    const match = await matchByNumber(ctx, event._id, args.matchNumber);
    if (!match) return null;
    const alliance = allianceOf(match, args.teamNumber);
    if (alliance === null) return null;
    const team = await teamByNumber(ctx, event._id, args.teamNumber);
    if (!team) return null;
    const mine = (
      await ctx.db
        .query("matchNotes")
        .withIndex("by_match", (q) => q.eq("matchId", match._id))
        .collect()
    ).find((n) => n.teamId === team._id && n.scoutId === userId) ?? null;
    return {
      matchNumber: match.matchNumber,
      teamNumber: team.number,
      nickname: team.nickname,
      alliance,
      notes: mine?.notes ?? null,
    };
  },
});

export const saveMatch = mutation({
  args: { matchNumber: v.number(), teamNumber: v.number(), notes: v.string() },
  handler: async (ctx, args) => {
    const scoutId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");
    const scoutingTeamNumber = await currentTeamNumber(ctx);
    if (scoutingTeamNumber === undefined) {
      throw new Error("Set your team number on your profile first.");
    }
    const match = await matchByNumber(ctx, event._id, args.matchNumber);
    if (!match) throw new Error("That match is not in the schedule.");
    if (allianceOf(match, args.teamNumber) === null) {
      throw new Error(`Team ${args.teamNumber} is not in Qual ${args.matchNumber}.`);
    }
    const team = await teamByNumber(ctx, event._id, args.teamNumber);
    if (!team) throw new Error("That team is not part of the active event.");
    const notes = cleanNote(args.notes);

    const existing = (
      await ctx.db
        .query("matchNotes")
        .withIndex("by_match", (q) => q.eq("matchId", match._id))
        .collect()
    ).find((n) => n.teamId === team._id && n.scoutId === scoutId);

    const now = Date.now();
    if (existing) {
      await ctx.db.patch(existing._id, { notes, scoutingTeamNumber, updatedAt: now });
      return existing._id;
    }
    return await ctx.db.insert("matchNotes", {
      eventId: event._id,
      matchId: match._id,
      teamId: team._id,
      scoutId,
      scoutingTeamNumber,
      notes,
      submittedAt: now,
      updatedAt: now,
    });
  },
});

/** Your match notes at this event, newest first, for "My notes". */
export const mine = query({
  args: {},
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) return [];
    const rows = await ctx.db
      .query("matchNotes")
      .withIndex("by_event_scout", (q) => q.eq("eventId", event._id).eq("scoutId", userId))
      .collect();
    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const teamById = new Map(teams.map((t) => [t._id, t]));
    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const matchNumberById = new Map(matches.map((m) => [m._id, m.matchNumber]));
    return rows
      .sort((a, b) => b.updatedAt - a.updatedAt)
      .map((r) => ({
        id: r._id,
        matchNumber: matchNumberById.get(r.matchId) ?? null,
        teamNumber: teamById.get(r.teamId)?.number ?? null,
        nickname: teamById.get(r.teamId)?.nickname ?? "",
        updatedAt: r.updatedAt,
      }));
  },
});

/** How many notes each robot in one match has, and whether one is yours. */
export const countsForMatch = query({
  args: { matchNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    const userId = await requireUser(ctx);
    const match = await matchByNumber(ctx, event._id, args.matchNumber);
    if (!match) return [];
    const notes = await ctx.db
      .query("matchNotes")
      .withIndex("by_match", (q) => q.eq("matchId", match._id))
      .collect();
    const byTeam = new Map<string, { count: number; mine: boolean }>();
    for (const n of notes) {
      const row = byTeam.get(n.teamId) ?? { count: 0, mine: false };
      row.count += 1;
      if (n.scoutId === userId) row.mine = true;
      byTeam.set(n.teamId, row);
    }
    return [...byTeam.entries()].map(([teamId, row]) => ({ teamId, ...row }));
  },
});

/** Which team number sits in that station for that match. */
function teamAt(
  match: { redTeamNumbers: number[]; blueTeamNumbers: number[] },
  s: Station,
): number | null {
  const list = s.startsWith("red") ? match.redTeamNumbers : match.blueTeamNumbers;
  return list[stationIndex(s)] ?? null;
}

/**
 * Your shifts, the matches they cover, and what is up next, counted in match
 * notes. The same answer assignments.mine gives for 2026, with notes in
 * place of reports. Shifts themselves (matchAssignments) belong to no
 * season: an admin assigns stations the same way whatever the form.
 */
export const assignments = query({
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
    const matchById = new Map(matches.map((m) => [m._id, m]));

    const myNotes = await ctx.db
      .query("matchNotes")
      .withIndex("by_event_scout", (q) => q.eq("eventId", event._id).eq("scoutId", userId))
      .collect();
    const notedMatchNumbers = new Set(
      myNotes.flatMap((n) => {
        const match = matchById.get(n.matchId);
        return match ? [match.matchNumber] : [];
      }),
    );

    // "Current" is the furthest match anyone has written a note on, pooled
    // across scouts. Walk down from the last match and stop at the first one
    // with a note, so an unplayed match costs one empty index read.
    let current = 0;
    for (const match of [...matches].sort((a, b) => b.matchNumber - a.matchNumber)) {
      const hit = await ctx.db
        .query("matchNotes")
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
          if (notedMatchNumbers.has(n)) done += 1;
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

    const assigned: { matchNumber: number; station: Station; teamNumber: number | null }[] = [];
    for (const row of rows) {
      for (let n = row.fromMatch; n <= row.toMatch; n++) {
        const match = byNumber.get(n);
        if (!match) continue;
        assigned.push({ matchNumber: n, station: row.station, teamNumber: teamAt(match, row.station) });
      }
    }
    assigned.sort((a, b) => a.matchNumber - b.matchNumber);

    const next = assigned.find(
      (a) => a.matchNumber > current && !notedMatchNumbers.has(a.matchNumber),
    ) ?? null;
    const upcomingNumber = matches
      .map((m) => m.matchNumber)
      .filter((n) => n > current)
      .sort((a, b) => a - b)[0] ?? null;

    const nextTeamNumber = next?.teamNumber ?? null;
    const nextNickname = nextTeamNumber === null
      ? null
      : ((await teamByNumber(ctx, event._id, nextTeamNumber))?.nickname ?? null);

    const upNext: {
      matchNumber: number;
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

// ─── Reading notes back ────────────────────────────────────────────────────

/** One team: your team's pit note, and every match note written about it. */
export const forTeam = query({
  args: { teamNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    const team = await teamByNumber(ctx, event._id, args.teamNumber);
    if (!team) return null;
    const myTeam = await currentTeamNumber(ctx);
    const names = await namesByUser(ctx);

    const pit = (
      await ctx.db
        .query("pitNotes")
        .withIndex("by_event_team", (q) => q.eq("eventId", event._id).eq("teamId", team._id))
        .collect()
    ).find((p) => p.scoutingTeamNumber === myTeam) ?? null;

    // Match notes are pooled across scouting teams, like 2026 match reports.
    const notes = await ctx.db
      .query("matchNotes")
      .withIndex("by_event_team", (q) => q.eq("eventId", event._id).eq("teamId", team._id))
      .collect();
    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const matchNumberById = new Map(matches.map((m) => [m._id, m.matchNumber]));

    return {
      eventKey: event.tbaEventKey,
      team: {
        number: team.number,
        nickname: team.nickname,
        city: team.city,
        stateProv: team.stateProv,
        country: team.country,
      },
      pit: pit
        ? { notes: pit.notes, updatedAt: pit.updatedAt, scoutName: names.get(pit.scoutId) ?? "Unknown scout" }
        : null,
      matches: notes
        .map((n) => ({
          id: n._id,
          matchNumber: matchNumberById.get(n.matchId) ?? null,
          scoutName: names.get(n.scoutId) ?? "Unknown scout",
          notes: n.notes,
          updatedAt: n.updatedAt,
        }))
        .sort((a, b) => (a.matchNumber ?? 0) - (b.matchNumber ?? 0) || a.updatedAt - b.updatedAt),
    };
  },
});

/** One match: its six robots, each with every note written about it. */
export const forMatch = query({
  args: { matchNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    const match = await matchByNumber(ctx, event._id, args.matchNumber);
    if (!match) return null;
    const notes = await ctx.db
      .query("matchNotes")
      .withIndex("by_match", (q) => q.eq("matchId", match._id))
      .collect();
    const names = await namesByUser(ctx);

    const side = async (numbers: number[]) =>
      await Promise.all(numbers.map(async (number) => {
        const team = await teamByNumber(ctx, event._id, number);
        return {
          teamNumber: number,
          nickname: team?.nickname ?? "Not at this event",
          notes: team
            ? notes
                .filter((n) => n.teamId === team._id)
                .sort((a, b) => a.updatedAt - b.updatedAt)
                .map((n) => ({
                  id: n._id,
                  scoutName: names.get(n.scoutId) ?? "Unknown scout",
                  notes: n.notes,
                }))
            : [],
        };
      }));

    return {
      eventKey: event.tbaEventKey,
      tbaMatchKey: match.tbaMatchKey,
      matchNumber: match.matchNumber,
      scheduledTime: match.scheduledTime,
      predictedTime: match.predictedTime ?? null,
      actualTime: match.actualTime ?? null,
      redScore: match.redScore ?? null,
      blueScore: match.blueScore ?? null,
      red: await side(match.redTeamNumbers),
      blue: await side(match.blueTeamNumbers),
    };
  },
});

// ─── Counts, export and admin ──────────────────────────────────────────────

/** For the dashboard: how far pit and match notes have got. */
export const progress = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    const myTeam = await currentTeamNumber(ctx);
    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const pit = await ctx.db
      .query("pitNotes")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const match = await ctx.db
      .query("matchNotes")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const withMatchNotes = new Set(match.map((n) => n.teamId));
    return {
      teams: teams.length,
      pitNoted: new Set(pit.filter((p) => p.scoutingTeamNumber === myTeam).map((p) => p.teamId)).size,
      matchNotes: match.length,
      teamsWithoutMatchNotes: teams
        .filter((t) => !withMatchNotes.has(t._id))
        .map((t) => t.number)
        .sort((a, b) => a - b),
    };
  },
});

/**
 * Everything for the notes spreadsheet. Team admins get their own team's pit
 * notes and every match note; full admins get every pit note.
 */
export const forExport = query({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) return null;
    const names = await namesByUser(ctx);
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
    const pit = await ctx.db
      .query("pitNotes")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const match = await ctx.db
      .query("matchNotes")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const stamp = (t: number) => new Date(t).toISOString();

    return {
      eventName: event.name,
      eventKey: event.tbaEventKey,
      pit: pit
        .filter((p) => me.role === "admin" || p.scoutingTeamNumber === me.teamNumber)
        .map((p) => ({
          team: teamById.get(p.teamId)?.number ?? "",
          nickname: teamById.get(p.teamId)?.nickname ?? "",
          scoutingTeam: p.scoutingTeamNumber,
          scout: names.get(p.scoutId) ?? "",
          updatedAt: stamp(p.updatedAt),
          notes: p.notes,
        }))
        .sort((a, b) => Number(a.team) - Number(b.team)),
      matches: match
        .map((n) => {
          const m = matchById.get(n.matchId);
          const number = teamById.get(n.teamId)?.number;
          return {
            match: m?.matchNumber ?? "",
            team: number ?? "",
            alliance: m && number !== undefined ? (allianceOf(m, number) ?? "") : "",
            scoutingTeam: n.scoutingTeamNumber,
            scout: names.get(n.scoutId) ?? "",
            updatedAt: stamp(n.updatedAt),
            notes: n.notes,
          };
        })
        .sort((a, b) => Number(a.match) - Number(b.match) || Number(a.team) - Number(b.team)),
    };
  },
});

/** Notes an admin can remove: a team admin's own team's, or all for a full admin. */
export const adminList = query({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) return null;
    const names = await namesByUser(ctx);
    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const numberById = new Map(teams.map((t) => [t._id, t.number]));
    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const matchNumberById = new Map(matches.map((m) => [m._id, m.matchNumber]));
    const pit = await ctx.db
      .query("pitNotes")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const match = await ctx.db
      .query("matchNotes")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();

    return {
      pit: pit
        .filter((p) => managesTeam(me, p.scoutingTeamNumber))
        .map((p) => ({
          id: p._id,
          teamNumber: numberById.get(p.teamId) ?? null,
          scoutingTeam: p.scoutingTeamNumber,
          scoutName: names.get(p.scoutId) ?? "Unknown scout",
          notes: p.notes,
          updatedAt: p.updatedAt,
        }))
        .sort((a, b) => (a.teamNumber ?? 0) - (b.teamNumber ?? 0)),
      matches: match
        .filter((n) => managesTeam(me, n.scoutingTeamNumber))
        .map((n) => ({
          id: n._id,
          matchNumber: matchNumberById.get(n.matchId) ?? null,
          teamNumber: numberById.get(n.teamId) ?? null,
          scoutingTeam: n.scoutingTeamNumber,
          scoutName: names.get(n.scoutId) ?? "Unknown scout",
          notes: n.notes,
          updatedAt: n.updatedAt,
        }))
        .sort((a, b) =>
          (a.matchNumber ?? 0) - (b.matchNumber ?? 0) || (a.teamNumber ?? 0) - (b.teamNumber ?? 0)),
    };
  },
});

export const removePit = mutation({
  args: { id: v.id("pitNotes") },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const row = await ctx.db.get(args.id);
    if (!row) return;
    if (!managesTeam(me, row.scoutingTeamNumber)) throw new Error("That is not your team's note.");
    await ctx.db.delete(args.id);
  },
});

export const removeMatch = mutation({
  args: { id: v.id("matchNotes") },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const row = await ctx.db.get(args.id);
    if (!row) return;
    if (!managesTeam(me, row.scoutingTeamNumber)) throw new Error("That is not your team's note.");
    await ctx.db.delete(args.id);
  },
});

