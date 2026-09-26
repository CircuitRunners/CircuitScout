#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-seasons.sh — pages by season.
#
# The active event's year (from its key: 2026gadal is 2026) picks which
# pages the app shows. 2026 gets the pages it has today, unchanged. Any year
# without its own forms gets the notes pages:
#
#   * Pit scouting: one "Notes" box per team.
#   * Match scouting: laid out like the 2026 page (search, robots with note
#     counts, your assigned matches, "My notes"), then one "Notes" box.
#   * Teams: team list, and a team modal with EPA/xP, the stat links, your
#     team's pit notes and every match note. No averages.
#   * Matches: the shared match list, and a match page with the TBA score,
#     projected EPA/xP and each robot's notes under it.
#   * Dashboard: Up next and your shifts (counted in notes), notes progress,
#     and a notes .xlsx export.
#   * Pick lists: the same lists, without stat sorts or stat lines.
#   * Admin: a notes tool in place of the 2026 report tools. Compare, Plot
#     and Coverage and quality say they have nothing for a notes season.
#
# Notes live in their own tables (pitNotes, matchNotes) behind convex/notes.ts.
# The 2026 pages never read them and the notes pages never read the 2026
# tables. Nothing is moved. To add a season later, build its pages and add
# one line to SEASONS in src/routes/seasons.tsx.
#
# Needs patch-match13.sh first. Every edit is checked before anything is
# written, and the script is safe to re-run. Re-running it over an earlier
# version of this patch updates the files that version wrote.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/schema.ts && -f src/routes/router.tsx ]] || {
  echo "ERROR: run from the repo root" >&2; exit 1; }
command -v bun >/dev/null || { echo "ERROR: bun not found" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# Relative on purpose: Git Bash rewrites /tmp in arguments but not inside
# the strings a script reads, so an absolute /tmp path breaks on Windows.
T=.patch-seasons-tmp
rm -rf "$T"; mkdir -p "$T/notes"
trap 'rm -rf "$T"' EXIT

say "Staging files"
cat > "$T/notes.ts" <<'PATCH_EOF'
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

PATCH_EOF

cat > "$T/season.ts" <<'PATCH_EOF'
import { createContext, useContext } from "react";
import type { FunctionReturnType } from "convex/server";

import type { api } from "../../convex/_generated/api";

export type ActiveEvent = NonNullable<FunctionReturnType<typeof api.events.active>>;

export type SeasonState = {
  /** True until the active event has loaded once. */
  loading: boolean;
  event: ActiveEvent | null;
  /** The event's season, from its key. Null with no active event. */
  year: number | null;
};

/** TBA event keys always start with the season: 2026gadal is 2026. */
export function seasonOf(eventKey: string): number | null {
  const year = Number.parseInt(eventKey.slice(0, 4), 10);
  return Number.isNaN(year) ? null : year;
}

export const SeasonContext = createContext<SeasonState>({
  loading: true, event: null, year: null,
});

/** The active event and its season, from the one subscription in the layout. */
export function useSeason(): SeasonState {
  return useContext(SeasonContext);
}
PATCH_EOF

cat > "$T/season-provider.tsx" <<'PATCH_EOF'
import { useQuery } from "convex/react";
import { useMemo, type ReactNode } from "react";

import { api } from "../../convex/_generated/api";
import { SeasonContext, seasonOf, type SeasonState } from "@/lib/season";

/**
 * The one subscription to the active event, at the top of the app. Every page
 * reads the season from here instead of querying for it, and when an admin
 * activates a different event Convex pushes it to every open phone.
 */
export function SeasonProvider({ children }: { children: ReactNode }) {
  const event = useQuery(api.events.active);
  const value = useMemo<SeasonState>(() => ({
    loading: event === undefined,
    event: event ?? null,
    year: event ? seasonOf(event.tbaEventKey) : null,
  }), [event]);
  return <SeasonContext.Provider value={value}>{children}</SeasonContext.Provider>;
}
PATCH_EOF

cat > "$T/seasons.tsx" <<'PATCH_EOF'
import type { ComponentType } from "react";

import { useSeason } from "@/lib/season";
import { PageShell } from "@/routes/page-shell";

// 2026: the pages as they were, unchanged.
import Dashboard2026 from "./dashboard";
import PitLanding2026 from "./pit/index";
import PitForm2026 from "./pit/form";
import ScoutLanding2026 from "./scout/index";
import MatchForm2026 from "./scout/form";
import Teams2026 from "./teams/index";
import Compare2026 from "./teams/compare";
import Plot2026 from "./teams/plot";
import MatchesPage from "./matches/index";
import MatchPreview2026 from "./matches/preview";
import PickListsPage from "./picklists/index";
import PickListBoard2026 from "./picklists/board";
import AdminData2026 from "./admin/data";
import {
  DeletionLog, FlaggedReports, ManageReports, PitReportsAdmin, TeamsNeedingAttention,
} from "./admin/reports-admin";

// Notes: for any season without its own forms.
import NotesDashboard from "./notes/dashboard";
import NotesPitLanding from "./notes/pit";
import NotesPitForm from "./notes/pit-form";
import NotesScoutLanding from "./notes/scout";
import NotesScoutForm from "./notes/scout-form";
import NotesTeams from "./notes/teams";
import NotesMatch from "./notes/match";
import NotesPickListBoard from "./notes/board";
import NotesAdminReports from "./notes/admin-notes";
import { NotAvailable } from "./notes/not-available";

export type SeasonPageKey =
  | "dashboard" | "pit" | "pitForm" | "scout" | "scoutForm"
  | "teams" | "teamsCompare" | "teamsPlot" | "matches" | "matchPreview"
  | "pickLists" | "pickListBoard" | "adminData" | "adminReports";

type SeasonPages = Record<SeasonPageKey, ComponentType>;

function Reports2026() {
  return (
    <>
      <TeamsNeedingAttention />
      <FlaggedReports />
      <ManageReports />
      <PitReportsAdmin />
      <DeletionLog />
    </>
  );
}

const PAGES_2026: SeasonPages = {
  dashboard: Dashboard2026,
  pit: PitLanding2026,
  pitForm: PitForm2026,
  scout: ScoutLanding2026,
  scoutForm: MatchForm2026,
  teams: Teams2026,
  teamsCompare: Compare2026,
  teamsPlot: Plot2026,
  matches: MatchesPage,
  matchPreview: MatchPreview2026,
  pickLists: PickListsPage,
  pickListBoard: PickListBoard2026,
  adminData: AdminData2026,
  adminReports: Reports2026,
};

const PAGES_NOTES: SeasonPages = {
  dashboard: NotesDashboard,
  pit: NotesPitLanding,
  pitForm: NotesPitForm,
  scout: NotesScoutLanding,
  scoutForm: NotesScoutForm,
  teams: NotesTeams,
  teamsCompare: () => <NotAvailable title="Compare" />,
  teamsPlot: () => <NotAvailable title="Plot" />,
  // The match list and the list of pick lists hold no scouting data, so
  // both seasons share them.
  matches: MatchesPage,
  matchPreview: NotesMatch,
  pickLists: PickListsPage,
  pickListBoard: NotesPickListBoard,
  adminData: () => <NotAvailable title="Coverage and quality" />,
  adminReports: NotesAdminReports,
};

/**
 * Seasons that have their own forms. Once a year's pages are built, add it
 * here; every event of that year switches to them. Any year not listed is
 * scouted with notes.
 */
const SEASONS: Partial<Record<number, SeasonPages>> = {
  2026: PAGES_2026,
};

function pagesFor(year: number | null): SeasonPages {
  // No active event: the 2026 pages, which already say so in their own words.
  if (year === null) return PAGES_2026;
  return SEASONS[year] ?? PAGES_NOTES;
}

/** A route element: whichever season's version of `page` the active event uses. */
export function SeasonPage({ page }: { page: SeasonPageKey }) {
  const { loading, year } = useSeason();
  if (loading) return <PageShell title="Loading…" />;
  const Page = pagesFor(year)[page];
  // Keyed by season, so switching events never carries one season's state
  // into the other's page.
  return <Page key={year ?? "none"} />;
}

/** The report tools at the bottom of the Admin page. */
export function SeasonAdminReports() {
  const { loading, year } = useSeason();
  if (loading) return null;
  const Reports = pagesFor(year).adminReports;
  return <Reports key={year ?? "none"} />;
}
PATCH_EOF

cat > "$T/notes/admin-notes.tsx" <<'PATCH_EOF'
import { useMutation, useQuery } from "convex/react";
import { Trash2 } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

/** The notes season's report tools: read and remove notes. */
export default function NotesAdminReports() {
  const data = useQuery(api.notes.adminList);
  const removePit = useMutation(api.notes.removePit);
  const removeMatch = useMutation(api.notes.removeMatch);
  const [confirm, setConfirm] = useState<string | null>(null);

  const run = (id: string, fn: () => Promise<unknown>) => {
    if (confirm !== id) { setConfirm(id); return; }
    setConfirm(null);
    void fn()
      .then(() => toast.success("Note removed"))
      .catch((error: unknown) =>
        toast.error("Could not remove", {
          description: error instanceof Error ? error.message : String(error),
        }));
  };

  const del = (id: string, fn: () => Promise<unknown>) => (
    <Button size="sm" variant={confirm === id ? "destructive" : "ghost"}
      aria-label="Remove note" onClick={() => run(id, fn)}>
      <Trash2 className="size-3.5" />
      {confirm === id ? "Tap again to remove" : null}
    </Button>
  );

  return (
    <Card>
      <CardHeader>
        <CardTitle>Notes</CardTitle>
        <CardDescription>
          This event is scouted with notes. Remove a note that is wrong or on the
          wrong robot; the scout can write it again.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-6">
        {data === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) : data === null ? (
          <p className="text-muted-foreground text-sm">No active event.</p>
        ) : (
          <>
            <div className="space-y-2">
              <h3 className="text-sm font-medium">Pit notes ({data.pit.length})</h3>
              {data.pit.length === 0 ? (
                <p className="text-muted-foreground text-sm">None yet.</p>
              ) : data.pit.map((n) => (
                <div key={n.id} className="flex items-start gap-3 rounded-lg border p-3">
                  <div className="min-w-0 flex-1 space-y-1">
                    <p className="text-xs font-medium">
                      Team {n.teamNumber ?? "?"}
                      <span className="text-muted-foreground font-normal">
                        {" "}· {n.scoutName} · for {n.scoutingTeam}
                      </span>
                    </p>
                    <p className="line-clamp-3 text-sm whitespace-pre-wrap">{n.notes}</p>
                  </div>
                  {del(n.id, () => removePit({ id: n.id as Id<"pitNotes"> }))}
                </div>
              ))}
            </div>
            <div className="space-y-2">
              <h3 className="text-sm font-medium">Match notes ({data.matches.length})</h3>
              {data.matches.length === 0 ? (
                <p className="text-muted-foreground text-sm">None yet.</p>
              ) : data.matches.map((n) => (
                <div key={n.id} className="flex items-start gap-3 rounded-lg border p-3">
                  <div className="min-w-0 flex-1 space-y-1">
                    <p className="text-xs font-medium">
                      Qual {n.matchNumber ?? "?"} · {n.teamNumber ?? "?"}
                      <span className="text-muted-foreground font-normal">
                        {" "}· {n.scoutName} · for {n.scoutingTeam}
                      </span>
                    </p>
                    <p className="line-clamp-3 text-sm whitespace-pre-wrap">{n.notes}</p>
                  </div>
                  {del(n.id, () => removeMatch({ id: n.id as Id<"matchNotes"> }))}
                </div>
              ))}
            </div>
          </>
        )}
      </CardContent>
    </Card>
  );
}
PATCH_EOF

cat > "$T/notes/board.tsx" <<'PATCH_EOF'
import {
  DndContext, DragOverlay, PointerSensor, TouchSensor, closestCorners,
  pointerWithin, useDroppable, useSensor, useSensors,
  type CollisionDetection, type DragEndEvent, type DragOverEvent,
  type DragStartEvent,
} from "@dnd-kit/core";
import { SortableContext, useSortable, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { useMutation, useQuery } from "convex/react";
import { ArrowLeft, Check, GripVertical, MessageSquare, MessageSquareWarning } from "lucide-react";
import { useMemo, useState } from "react";
import { Link, useParams } from "react-router";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { NotesTeamDetail } from "./team-detail";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { TIERS, TIER_LABELS, type Tier } from "@/lib/types";

/**
 * The pick list board for a notes-only season. The same lists, tiers, drag
 * and picked ticks as the 2026 board, which is where this was copied from;
 * what is gone is everything counted: no stat sorts, no stat line on the
 * cards, and the notes team modal in place of the 2026 one.
 */

type Row = {
  entryId: string;
  teamId: string;
  teamNumber: number;
  nickname: string;
  tier: Tier;
  order: number;
  note: string;
};

function PickNote({ row, canEdit }: { row: Row; canEdit: boolean }) {
  const setNote = useMutation(api.entries.setNote);
  const [text, setText] = useState(row.note);
  const [saving, setSaving] = useState(false);
  const required = row.tier === "t1" || row.tier === "dnp";
  const dirty = text !== row.note;

  return (
    <div className="space-y-2 border-t pt-4">
      <div className="flex items-baseline justify-between">
        <h3 className="font-medium">Pick notes</h3>
        {required ? (
          <span className="text-destructive text-xs">Required for first picks and dnps</span>
        ) : null}
      </div>
      <Textarea rows={3} value={text} disabled={!canEdit} placeholder="Pick notes"
        onChange={(e) => setText(e.target.value)} />
      {canEdit ? (
        <Button size="sm" disabled={!dirty || saving}
          onClick={() => {
            setSaving(true);
            void setNote({ entryId: row.entryId as Id<"pickListEntries">, note: text })
              .then(() => toast.success("Note saved"))
              .catch((error: unknown) =>
                toast.error("Could not save", {
                  description: error instanceof Error ? error.message : String(error),
                }))
              .finally(() => setSaving(false));
          }}>
          {dirty ? "Save note" : "Saved"}
        </Button>
      ) : null}
    </div>
  );
}

function Column({ tier, rows, children }: { tier: Tier; rows: Row[]; children: React.ReactNode }) {
  const { setNodeRef, isOver } = useDroppable({ id: `col:${tier}` });
  return (
    <div ref={setNodeRef}
      className={[
        "flex max-h-[70vh] min-h-32 min-w-64 flex-1 flex-col gap-2 rounded-lg border p-2 transition-colors",
        isOver ? "bg-accent border-secondary" : "",
      ].join(" ")}>
      <div className="flex shrink-0 items-center justify-between px-1">
        <span className="text-sm font-medium">{TIER_LABELS[tier]}</span>
        <span className="text-muted-foreground text-xs tabular-nums">{rows.length}</span>
      </div>
      <div className="min-h-0 flex-1 space-y-2 overflow-y-auto overscroll-contain">{children}</div>
    </div>
  );
}

function Chip({
  row, pitNoted, draggable, picked, onTogglePicked, onOpen,
}: {
  row: Row;
  pitNoted: boolean;
  draggable: boolean;
  picked: boolean;
  onTogglePicked?: () => void;
  onOpen: () => void;
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } =
    useSortable({ id: row.entryId, disabled: !draggable });
  const needsNote = (row.tier === "t1" || row.tier === "dnp") && row.note.trim() === "";

  return (
    <div ref={setNodeRef}
      style={{ transform: CSS.Translate.toString(transform), transition }}
      className={["bg-background rounded-lg border p-2", isDragging ? "opacity-40" : ""].join(" ")}>
      <div className="flex items-center gap-1.5">
        {draggable ? (
          <button {...attributes} {...listeners} aria-label={`Reorder team ${row.teamNumber}`}
            className="text-muted-foreground touch-none p-1">
            <GripVertical className="size-4" />
          </button>
        ) : null}
        <button onClick={onOpen} className="min-w-0 flex-1 text-left">
          <span className="font-semibold tabular-nums">{row.teamNumber}</span>
          <span className="text-muted-foreground ml-1.5 text-xs">{row.nickname}</span>
        </button>
        {needsNote ? (
          <MessageSquareWarning className="text-destructive size-4 shrink-0" />
        ) : row.note ? (
          <MessageSquare className="text-muted-foreground size-4 shrink-0" />
        ) : null}
        {onTogglePicked ? (
          <Button size="icon" variant={picked ? "secondary" : "ghost"} className="size-6 shrink-0"
            aria-label={picked ? `Unmark ${row.teamNumber} as picked` : `Mark ${row.teamNumber} as picked`}
            onClick={(e) => { e.stopPropagation(); onTogglePicked(); }}>
            <Check className="size-3.5" />
          </Button>
        ) : null}
        <Badge variant={pitNoted ? "secondary" : "outline"} className="shrink-0 text-[10px]">
          {pitNoted ? "Pit notes" : "No pit"}
        </Badge>
      </div>
      {row.note ? <p className="mt-1 line-clamp-2 pl-1 text-[11px] italic">{row.note}</p> : null}
    </div>
  );
}

export default function NotesPickListBoardPage() {
  const params = useParams();
  const listId = params.listId as Id<"pickLists"> | undefined;

  const list = useQuery(api.pickLists.get, listId ? { listId } : "skip");
  const entries = useQuery(api.entries.forList, listId ? { listId } : "skip");
  const teams = useQuery(api.notes.teams);
  const move = useMutation(api.entries.move);
  const picked = useQuery(api.picked.forEvent);
  const togglePicked = useMutation(api.picked.toggle);

  const [dragging, setDragging] = useState<Row | null>(null);
  const [overTier, setOverTier] = useState<Tier | null>(null);
  const [selectedTeam, setSelectedTeam] = useState<number | null>(null);
  const [search, setSearch] = useState("");
  const [showPicked, setShowPicked] = useState(false);

  const collision: CollisionDetection = (args) => {
    const within = pointerWithin(args);
    return within.length > 0 ? within : closestCorners(args);
  };
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 200, tolerance: 8 } }),
  );

  const pitByTeam = useMemo(
    () => new Map<string, boolean>((teams ?? []).map((t) => [t.teamId, t.pitNoted])),
    [teams],
  );

  const byTier = useMemo(() => {
    const map = new Map<Tier, Row[]>();
    for (const tier of TIERS) map.set(tier, []);
    for (const row of (entries ?? []) as Row[]) map.get(row.tier)?.push(row);
    for (const rows of map.values()) rows.sort((a, b) => a.order - b.order);

    const pickedSet = new Set(picked ?? []);
    if (!showPicked) {
      for (const [tier, rows] of map) map.set(tier, rows.filter((r) => !pickedSet.has(r.teamId)));
    }
    const needle = search.trim().toLowerCase();
    if (needle !== "") {
      const hit = (r: Row) =>
        String(r.teamNumber).includes(needle) || r.nickname.toLowerCase().includes(needle);
      for (const [tier, rows] of map) {
        map.set(tier, tier === "uncategorized"
          ? [...rows].sort((a, b) => Number(hit(b)) - Number(hit(a)))
          : rows.filter(hit));
      }
    }
    return map;
  }, [entries, search, picked, showPicked]);

  const searching = search.trim() !== "";
  const selectedRow = ((entries ?? []) as Row[]).find((r) => r.teamNumber === selectedTeam) ?? null;

  const resolveTier = (overId: string | null): Tier | null => {
    if (!overId) return null;
    if (overId.startsWith("col:")) return overId.slice(4) as Tier;
    return ((entries ?? []) as Row[]).find((r) => r.entryId === overId)?.tier ?? null;
  };

  const onDragStart = (event: DragStartEvent) => {
    const row = (entries as Row[] | undefined)?.find((r) => r.entryId === event.active.id);
    setDragging(row ?? null);
    setOverTier(row?.tier ?? null);
  };

  const onDragOver = (event: DragOverEvent) => {
    const tier = resolveTier(event.over ? String(event.over.id) : null);
    if (tier) setOverTier(tier);
  };

  const onDragEnd = (event: DragEndEvent) => {
    setDragging(null);
    const { active, over } = event;
    if (!over) { setOverTier(null); return; }
    const rows = (entries ?? []) as Row[];
    const moved = rows.find((r) => r.entryId === active.id);
    if (!moved) return;
    const overId = String(over.id);
    const target = resolveTier(overId) ?? overTier;
    if (!target) return;
    const column = (byTier.get(target) ?? []).filter((r) => r.entryId !== moved.entryId);
    const index = overId.startsWith("col:") ? column.length : column.findIndex((r) => r.entryId === overId);
    const at = index < 0 ? column.length : index;
    const before = column[at - 1]?.order ?? 0;
    const after = column[at]?.order ?? before + 2000;
    const order = (before + after) / 2;
    if (target === moved.tier && Math.abs(order - moved.order) < 1e-9) return;
    void move({ entryId: moved.entryId as Id<"pickListEntries">, tier: target, order })
      .catch((error: unknown) =>
        toast.error("Could not move that card", {
          description: error instanceof Error ? error.message : String(error),
        }));
  };

  if (!listId) return <PageShell title="Pick list" description="Bad URL." />;
  if (list === undefined || entries === undefined) {
    return <PageShell title="Pick list" description="Loading…" />;
  }
  if (list === null) {
    return (
      <PageShell title="Pick list" description="That list no longer exists.">
        <Button variant="outline" render={<Link to="/picklists" />}>
          <ArrowLeft className="size-4" /> All lists
        </Button>
      </PageShell>
    );
  }

  return (
    <PageShell
      title={list.name}
      actions={
        <div className="flex flex-wrap gap-2">
          {!list.canEdit ? <Badge variant="outline">Read only</Badge> : null}
          <Button variant="outline" render={<Link to="/picklists" />}>
            <ArrowLeft className="size-4" /> All lists
          </Button>
        </div>
      }
    >
      <Input className="max-w-56" placeholder="Find a team"
        value={search} onChange={(e) => setSearch(e.target.value)} />

      <div className="flex flex-wrap items-center gap-2">
        <Button size="sm" variant={showPicked ? "secondary" : "outline"}
          onClick={() => setShowPicked(!showPicked)}>
          Show picked {showPicked ? "✓" : ""}
        </Button>
        <span className="text-muted-foreground text-xs">
          {(picked ?? []).length} taken
          {list.isPrimary && list.canEdit ? " · tick a team to mark it picked" : " · marked on the team primary list"}
        </span>
      </div>

      <DndContext sensors={sensors} collisionDetection={collision}
        onDragStart={onDragStart} onDragOver={onDragOver} onDragEnd={onDragEnd}>
        <div className="flex gap-3 overflow-x-auto pb-2">
          {TIERS.map((tier) => {
            const rows = byTier.get(tier) ?? [];
            return (
              <Column key={tier} tier={tier} rows={rows}>
                <SortableContext items={rows.map((r) => r.entryId)} strategy={verticalListSortingStrategy}>
                  {rows.map((row) => (
                    <Chip key={row.entryId} row={row}
                      pitNoted={pitByTeam.get(row.teamId) ?? false}
                      draggable={list.canEdit && (!searching || row.tier === "uncategorized")}
                      picked={(picked ?? []).includes(row.teamId)}
                      onTogglePicked={
                        list.isPrimary && list.canEdit
                          ? () => {
                              void togglePicked({ teamId: row.teamId as Id<"teams"> })
                                .catch((error: unknown) =>
                                  toast.error("Could not update", {
                                    description: error instanceof Error ? error.message : String(error),
                                  }));
                            }
                          : undefined
                      }
                      onOpen={() => setSelectedTeam(row.teamNumber)} />
                  ))}
                </SortableContext>
              </Column>
            );
          })}
        </div>

        <DragOverlay>
          {dragging ? (
            <div className="bg-background rounded-lg border p-2 shadow-lg">
              <span className="font-semibold tabular-nums">{dragging.teamNumber}</span>
              <span className="text-muted-foreground ml-1.5 text-xs">{dragging.nickname}</span>
            </div>
          ) : null}
        </DragOverlay>
      </DndContext>

      <NotesTeamDetail
        teamNumber={selectedTeam}
        onClose={() => setSelectedTeam(null)}
        footer={selectedRow ? (
          <PickNote key={selectedRow.entryId} row={selectedRow} canEdit={list.canEdit} />
        ) : null}
      />
    </PageShell>
  );
}
PATCH_EOF

cat > "$T/notes/dashboard.tsx" <<'PATCH_EOF'
import { useQuery } from "convex/react";
import { Link } from "react-router";

import { api } from "../../../convex/_generated/api";
import { NotesExport } from "./export";
import { ShiftRow } from "@/components/shift-picker";
import { StatLinks } from "@/components/stat-links";
import { useSeason } from "@/lib/season";
import { STATION_LABELS, type Station } from "@/lib/types";
import { PageShell } from "@/routes/page-shell";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

function Metric({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <Card>
      <CardHeader>
        <CardDescription>{label}</CardDescription>
        <CardTitle className="text-3xl tabular-nums">{value}</CardTitle>
      </CardHeader>
      {hint ? <CardContent className="text-muted-foreground -mt-4 text-xs">{hint}</CardContent> : null}
    </Card>
  );
}

export default function NotesDashboardPage() {
  const { event, year } = useSeason();
  const progress = useQuery(api.notes.progress);
  const matches = useQuery(api.matches.listForEvent);
  // Shifts and "Up next", counted in notes rather than 2026 reports.
  const assignments = useQuery(api.notes.assignments);

  const teams = progress?.teams ?? 0;
  const pitNoted = progress?.pitNoted ?? 0;
  const missing = progress?.teamsWithoutMatchNotes ?? [];

  return (
    <PageShell
      title={
        event ? (
          <>
            {event.name}
            <StatLinks kind="event" eventKey={event.tbaEventKey} />
          </>
        ) : "No active event"
      }
      description={
        event
          ? `${event.tbaEventKey} · ${teams} teams · ${matches?.length ?? 0} qualification matches · scouted with notes (no ${year ?? ""} forms yet)`
          : undefined
      }
      actions={
        <div className="flex gap-2">
          <Button variant="outline" render={<Link to="/pit" />}>Pit</Button>
          <Button render={<Link to="/scout" />}>Scout a match</Button>
        </div>
      }
    >
      {assignments?.upNext ? (
        <Card>
          <CardHeader>
            <CardDescription>Up next</CardDescription>
            <CardTitle className="flex flex-wrap items-baseline gap-3">
              <span className="text-3xl tabular-nums">
                Qual {assignments.upNext.matchNumber}
              </span>
              {assignments.upNext.station === null ? null : (
                <span className={[
                  "rounded-md px-2 py-1 text-xs font-medium text-white",
                  assignments.upNext.station.startsWith("red") ? "bg-red-600" : "bg-blue-600",
                ].join(" ")}>
                  {STATION_LABELS[assignments.upNext.station as Station]}
                </span>
              )}
            </CardTitle>
          </CardHeader>
          <CardContent className="-mt-4 space-y-3">
            {assignments.upNext.assigned ? (
              <p className="text-muted-foreground text-sm">
                {assignments.upNext.teamNumber === null ? (
                  "That station has no team in the imported schedule."
                ) : (
                  <>
                    Team{" "}
                    <span className="text-foreground font-medium tabular-nums">
                      {assignments.upNext.teamNumber}
                    </span>
                    {assignments.upNext.nickname ? ` · ${assignments.upNext.nickname}` : ""}
                    {assignments.upNext.matchesAway === 0
                      ? ""
                      : ` · ${assignments.upNext.matchesAway} match${assignments.upNext.matchesAway === 1 ? "" : "es"} away`}
                  </>
                )}
              </p>
            ) : null}
            {assignments.upNext.teamNumber !== null ? (
              <Button variant="secondary"
                render={<Link to={`/scout/${assignments.upNext.matchNumber}/${assignments.upNext.teamNumber}`} />}>
                Scout this robot
              </Button>
            ) : null}
          </CardContent>
        </Card>
      ) : null}

      {(assignments?.shifts ?? []).length > 0 ? (
        <Card>
          <CardHeader>
            <CardTitle>Your shifts</CardTitle>
            <CardDescription>
              Progress counts matches you have written notes on in each range.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-2">
            {(assignments?.shifts ?? []).map((shift) => (
              <ShiftRow key={shift.assignmentId}
                fromMatch={shift.fromMatch} toMatch={shift.toMatch}
                station={shift.station as Station}
                trailing={`${shift.done} of ${shift.total}`} />
            ))}
          </CardContent>
        </Card>
      ) : null}

      <div className="grid gap-4 sm:grid-cols-3">
        <Metric label="Pit notes" value={`${pitNoted}/${teams}`}
          hint={teams - pitNoted > 0 ? `${teams - pitNoted} still to do` : "Complete"} />
        <Metric label="Match notes" value={String(progress?.matchNotes ?? 0)} />
        <Metric label="Teams with no match notes" value={String(missing.length)} />
      </div>

      {missing.length > 0 ? (
        <Card>
          <CardHeader>
            <CardTitle>Teams with no match notes</CardTitle>
            <CardDescription>Nobody has written about these in a match yet.</CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap gap-2">
            {missing.map((n) => (
              <Button key={n} size="sm" variant="outline" render={<Link to={`/teams?team=${n}`} />}>
                {n}
              </Button>
            ))}
          </CardContent>
        </Card>
      ) : null}

      <NotesExport />
    </PageShell>
  );
}
PATCH_EOF

cat > "$T/notes/export.tsx" <<'PATCH_EOF'
import { useConvex, useQuery } from "convex/react";
import { Download, LoaderCircle } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

/**
 * Pit notes and match notes as a two-sheet workbook. No cooldown: notes are
 * a few rows of text, nothing like the 2026 workbook's reads.
 */
export function NotesExport() {
  const convex = useConvex();
  const me = useQuery(api.profiles.me);
  const [busy, setBusy] = useState(false);

  if (me?.role !== "admin" && me?.role !== "teamAdmin") return null;

  const download = async () => {
    setBusy(true);
    try {
      const data = await convex.query(api.notes.forExport, {});
      if (!data) {
        toast.error("No active event");
        return;
      }
      // Dynamic import: nobody downloads the xlsx library until they export.
      const XLSX = await import("xlsx");
      const book = XLSX.utils.book_new();
      XLSX.utils.book_append_sheet(book,
        XLSX.utils.json_to_sheet(data.pit.length > 0 ? data.pit : [{}]), "Pit notes");
      XLSX.utils.book_append_sheet(book,
        XLSX.utils.json_to_sheet(data.matches.length > 0 ? data.matches : [{}]), "Match notes");
      XLSX.writeFile(book, `circuitscout-${data.eventKey}-notes.xlsx`);
      toast.success("Downloaded", {
        description: `${data.pit.length} pit notes · ${data.matches.length} match notes.`,
      });
    } catch (error) {
      toast.error("Could not build the workbook", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>Export notes</CardTitle>
        <CardDescription>
          Two sheets: pit notes{me.role === "admin" ? " from every team" : " from your team"},
          and every match note at this event.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <Button variant="outline" disabled={busy} onClick={() => void download()}>
          {busy ? <LoaderCircle className="size-4 animate-spin" /> : <Download className="size-4" />}
          Download .xlsx
        </Button>
      </CardContent>
    </Card>
  );
}
PATCH_EOF

cat > "$T/notes/match.tsx" <<'PATCH_EOF'
import { useQuery } from "convex/react";
import { ArrowLeft } from "lucide-react";
import { Link, useParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { StatLinks } from "@/components/stat-links";
import { useRatings } from "@/lib/stat-site";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

type Robot = {
  teamNumber: number;
  nickname: string;
  notes: { id: string; scoutName: string; notes: string }[];
};

function Side({ label, robots, red }: { label: string; robots: Robot[]; red: boolean }) {
  return (
    <div className="space-y-3">
      <h3 className={red ? "font-medium text-red-600 dark:text-red-400" : "font-medium text-blue-600 dark:text-blue-400"}>
        {label}
      </h3>
      {robots.map((robot) => (
        <Card key={robot.teamNumber} className={red ? "border-red-600/30" : "border-blue-600/30"}>
          <CardHeader>
            <CardTitle className="flex items-baseline gap-2">
              <Link to={`/teams?team=${robot.teamNumber}`} className="tabular-nums hover:underline">
                {robot.teamNumber}
              </Link>
              <span className="text-muted-foreground text-sm font-normal">{robot.nickname}</span>
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            {robot.notes.length === 0 ? (
              <p className="text-muted-foreground text-sm">No notes on this robot in this match.</p>
            ) : (
              robot.notes.map((n) => (
                <div key={n.id} className="space-y-0.5">
                  <p className="text-sm whitespace-pre-wrap">{n.notes}</p>
                  <p className="text-muted-foreground text-xs">{n.scoutName}</p>
                </div>
              ))
            )}
          </CardContent>
        </Card>
      ))}
    </div>
  );
}

export default function NotesMatchPage() {
  const params = useParams();
  const matchNumber = Number.parseInt(params.matchNumber ?? "", 10);
  const data = useQuery(api.notes.forMatch, Number.isNaN(matchNumber) ? "skip" : { matchNumber });
  const ratings = useRatings();

  const back = (
    <Button variant="outline" render={<Link to="/matches" />}>
      <ArrowLeft className="size-4" /> All matches
    </Button>
  );

  if (Number.isNaN(matchNumber)) return <PageShell title="Match" description="Bad URL." actions={back} />;
  if (data === undefined) return <PageShell title="Match" description="Loading…" actions={back} />;
  if (data === null) {
    return <PageShell title="Match" description="That match is not at the active event." actions={back} />;
  }

  const sum = (side: Robot[]) =>
    side.reduce((total, r) => total + (ratings.byTeam.get(r.teamNumber)?.total ?? 0), 0);
  const covered = [...data.red, ...data.blue].filter((r) => ratings.byTeam.has(r.teamNumber)).length;
  const played = data.redScore !== null && data.blueScore !== null;
  const whenMs = data.actualTime ?? data.predictedTime ?? data.scheduledTime;

  return (
    <PageShell
      title={
        <>
          Qual {data.matchNumber}
          <StatLinks kind="match" eventKey={data.eventKey} matchKey={data.tbaMatchKey} />
        </>
      }
      description={whenMs === null ? undefined : `${played ? "Played" : "Scheduled"} ${new Date(whenMs).toLocaleString()}`}
      actions={back}
    >
      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>{played ? "Final score" : "Not played yet"}</CardTitle>
            <CardDescription>From The Blue Alliance.</CardDescription>
          </CardHeader>
          {played ? (
            <CardContent className="flex items-center gap-6">
              <div>
                <p className="text-xs text-red-600 dark:text-red-400">Red</p>
                <p className="text-3xl font-semibold tabular-nums">{data.redScore}</p>
              </div>
              <div>
                <p className="text-xs text-blue-600 dark:text-blue-400">Blue</p>
                <p className="text-3xl font-semibold tabular-nums">{data.blueScore}</p>
              </div>
            </CardContent>
          ) : null}
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Projected · {ratings.metric}</CardTitle>
            <CardDescription>
              {ratings.siteName} {ratings.metric} summed per alliance.
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap items-center gap-6">
            {ratings.loading ? (
              <p className="text-muted-foreground text-sm">Loading…</p>
            ) : ratings.byTeam.size === 0 ? (
              <p className="text-muted-foreground text-sm">
                No {ratings.metric} yet — an admin can pull it from the Admin page.
              </p>
            ) : (
              <>
                <div>
                  <p className="text-xs text-red-600 dark:text-red-400">Red</p>
                  <p className="text-3xl font-semibold tabular-nums">{sum(data.red).toFixed(0)}</p>
                </div>
                <div>
                  <p className="text-xs text-blue-600 dark:text-blue-400">Blue</p>
                  <p className="text-3xl font-semibold tabular-nums">{sum(data.blue).toFixed(0)}</p>
                </div>
                {covered < 6 ? (
                  <Badge variant="outline">Only {covered} of 6 have {ratings.metric}</Badge>
                ) : null}
              </>
            )}
          </CardContent>
        </Card>
      </div>

      <div className="grid gap-6 md:grid-cols-2">
        <Side label="Red" robots={data.red} red />
        <Side label="Blue" robots={data.blue} red={false} />
      </div>
    </PageShell>
  );
}
PATCH_EOF

cat > "$T/notes/not-available.tsx" <<'PATCH_EOF'
import { useSeason } from "@/lib/season";
import { PageShell } from "@/routes/page-shell";

/**
 * For pages that only exist for seasons with their own forms. Says so plainly
 * rather than showing another season's page with nothing in it.
 */
export function NotAvailable({ title }: { title: string }) {
  const { year } = useSeason();
  return (
    <PageShell title={title}>
      <p className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
        CircuitScout has no {year ?? "this season's"} forms yet, so this event is
        scouted with notes and {title.toLowerCase()} has nothing to show.
      </p>
    </PageShell>
  );
}
PATCH_EOF

cat > "$T/notes/note-editor.tsx" <<'PATCH_EOF'
import { LoaderCircle } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";

/**
 * The whole notes form: one box, one button. Mount it with a key once the
 * saved note has loaded, so `initial` seeds it exactly once.
 */
export function NoteEditor({
  id, initial, onSave, onSaved,
}: {
  id: string;
  initial: string;
  onSave: (notes: string) => Promise<unknown>;
  onSaved?: () => void;
}) {
  const [text, setText] = useState(initial);
  const [saved, setSaved] = useState(initial);
  const [saving, setSaving] = useState(false);
  const dirty = text.trim() !== saved.trim();

  return (
    <div className="space-y-2">
      <Label htmlFor={id}>Notes</Label>
      <Textarea id={id} rows={8} value={text} className="text-base"
        placeholder="What did you see?"
        onChange={(e) => setText(e.target.value)} />
      <Button className="w-full sm:w-auto" disabled={saving || !dirty || text.trim() === ""}
        onClick={() => {
          setSaving(true);
          void onSave(text)
            .then(() => {
              setSaved(text);
              toast.success("Notes saved");
              onSaved?.();
            })
            .catch((error: unknown) =>
              toast.error("Could not save", {
                description: error instanceof Error ? error.message : String(error),
              }))
            .finally(() => setSaving(false));
        }}>
        {saving ? <LoaderCircle className="size-4 animate-spin" /> : null}
        {dirty || saved === "" ? "Save notes" : "Saved"}
      </Button>
    </div>
  );
}
PATCH_EOF

cat > "$T/notes/pit-form.tsx" <<'PATCH_EOF'
import { useMutation, useQuery } from "convex/react";
import { ArrowLeft } from "lucide-react";
import { Link, useParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { NoteEditor } from "./note-editor";
import { PageShell } from "@/routes/page-shell";
import { Button } from "@/components/ui/button";

export default function NotesPitFormPage() {
  const params = useParams();
  const teamNumber = Number.parseInt(params.teamNumber ?? "", 10);
  const data = useQuery(api.notes.pitNote, Number.isNaN(teamNumber) ? "skip" : { teamNumber });
  const save = useMutation(api.notes.savePit);

  const back = (
    <Button variant="outline" render={<Link to="/pit" />}>
      <ArrowLeft className="size-4" /> All teams
    </Button>
  );

  if (Number.isNaN(teamNumber)) return <PageShell title="Pit notes" description="Bad URL." actions={back} />;
  if (data === undefined) return <PageShell title="Pit notes" description="Loading…" actions={back} />;
  if (data === null) {
    return <PageShell title="Pit notes" description="That team is not at the active event." actions={back} />;
  }

  return (
    <PageShell
      title={`${data.teamNumber} · ${data.nickname}`}
      description={
        data.note
          ? `Your team's pit notes, last saved by ${data.note.scoutName} ${new Date(data.note.updatedAt).toLocaleString()}.`
          : "Your team's pit notes. Anyone on your team can add to them."
      }
      actions={back}
    >
      <NoteEditor key={data.teamNumber} id="pit-notes"
        initial={data.note?.notes ?? ""}
        onSave={(notes) => save({ teamNumber, notes })} />
    </PageShell>
  );
}
PATCH_EOF

cat > "$T/notes/pit.tsx" <<'PATCH_EOF'
import { useQuery } from "convex/react";
import { useMemo, useState } from "react";
import { useNavigate } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

type Filter = "all" | "todo" | "done";

const FILTERS: ReadonlyArray<{ value: Filter; label: string }> = [
  { value: "todo", label: "No notes" },
  { value: "done", label: "Noted" },
  { value: "all", label: "All" },
];

export default function NotesPitLandingPage() {
  const teams = useQuery(api.notes.teams);
  const navigate = useNavigate();
  const [filter, setFilter] = useState<Filter>("todo");
  const [search, setSearch] = useState("");

  const shown = useMemo(() => {
    const needle = search.trim().toLowerCase();
    return (teams ?? []).filter((team) => {
      if (filter === "todo" && team.pitNoted) return false;
      if (filter === "done" && !team.pitNoted) return false;
      if (needle === "") return true;
      return String(team.number).includes(needle) || team.nickname.toLowerCase().includes(needle);
    });
  }, [teams, filter, search]);

  const done = teams?.filter((t) => t.pitNoted).length ?? 0;
  const total = teams?.length ?? 0;

  return (
    <PageShell
      title="Pit Scouting"
      description={
        total === 0
          ? "No teams yet. An admin needs to import an event."
          : `${done} of ${total} teams have pit notes. Tap a team to write about it.`
      }
    >
      <div className="flex flex-wrap items-center gap-2">
        {FILTERS.map((f) => (
          <Button key={f.value} size="sm"
            variant={filter === f.value ? "default" : "outline"}
            onClick={() => setFilter(f.value)}>
            {f.label}
          </Button>
        ))}
        <Input className="ml-auto max-w-48" placeholder="Find a team" inputMode="numeric"
          value={search} onChange={(e) => setSearch(e.target.value)} />
      </div>

      {teams === undefined ? (
        <p className="text-muted-foreground text-sm">Loading…</p>
      ) : shown.length === 0 ? (
        <p className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
          {filter === "todo" && total > 0 ? "Every team has pit notes." : "Nothing matches."}
        </p>
      ) : (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
          {shown.map((team) => (
            <button key={team.teamId}
              onClick={() => void navigate(`/pit/${team.number}`)}
              className={[
                "flex min-h-24 flex-col justify-between rounded-lg border p-3 text-left transition-colors",
                team.pitNoted ? "bg-primary/5 border-primary/40" : "hover:bg-accent/50",
              ].join(" ")}>
              <span className="text-2xl font-semibold tabular-nums">{team.number}</span>
              <span className="text-muted-foreground truncate text-xs">{team.nickname}</span>
              <Badge variant={team.pitNoted ? "default" : "outline"} className="mt-1 w-fit">
                {team.pitNoted ? "Noted" : "No notes"}
              </Badge>
            </button>
          ))}
        </div>
      )}
    </PageShell>
  );
}
PATCH_EOF

cat > "$T/notes/scout-form.tsx" <<'PATCH_EOF'
import { useMutation, useQuery } from "convex/react";
import { ArrowLeft } from "lucide-react";
import { Link, useNavigate, useParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { NoteEditor } from "./note-editor";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";

export default function NotesScoutFormPage() {
  const params = useParams();
  const navigate = useNavigate();
  const matchNumber = Number.parseInt(params.matchNumber ?? "", 10);
  const teamNumber = Number.parseInt(params.teamNumber ?? "", 10);
  const bad = Number.isNaN(matchNumber) || Number.isNaN(teamNumber);
  const data = useQuery(api.notes.matchNote, bad ? "skip" : { matchNumber, teamNumber });
  const save = useMutation(api.notes.saveMatch);

  const back = (
    <Button variant="outline" render={<Link to="/scout" />}>
      <ArrowLeft className="size-4" /> All matches
    </Button>
  );

  if (bad) return <PageShell title="Match notes" description="Bad URL." actions={back} />;
  if (data === undefined) return <PageShell title="Match notes" description="Loading…" actions={back} />;
  if (data === null) {
    return (
      <PageShell title="Match notes" actions={back}
        description={`Team ${teamNumber} is not in Qual ${matchNumber} at the active event.`} />
    );
  }

  return (
    <PageShell
      title={
        <>
          Qual {data.matchNumber} · {data.teamNumber}
          <Badge className={data.alliance === "red" ? "bg-red-600 text-white" : "bg-blue-600 text-white"}>
            {data.alliance === "red" ? "Red" : "Blue"}
          </Badge>
        </>
      }
      description={
        data.notes === null
          ? `${data.nickname}. Your notes on this robot in this match.`
          : `${data.nickname}. You have notes on this robot already; saving replaces them.`
      }
      actions={back}
    >
      <NoteEditor key={`${data.matchNumber}:${data.teamNumber}`} id="match-notes"
        initial={data.notes ?? ""}
        onSave={(notes) => save({ matchNumber, teamNumber, notes })}
        onSaved={() => void navigate("/scout")} />
    </PageShell>
  );
}
PATCH_EOF

cat > "$T/notes/scout.tsx" <<'PATCH_EOF'
import { useQuery } from "convex/react";
import { ChevronRight, X } from "lucide-react";
import { useMemo, useState } from "react";
import { useNavigate } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { STATION_LABELS, type Station } from "@/lib/types";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

/**
 * Match scouting for a notes-only season. Laid out exactly like the 2026 page,
 * which is where it was copied from, with notes in place of reports: the
 * counts, the ticks, "My notes" and your assignments all come from
 * matchNotes, never from the 2026 tables.
 */
function MatchRobots({
  matchNumber,
  highlight,
  assignedTeam,
}: {
  matchNumber: number;
  highlight: number | null;
  assignedTeam: number | null;
}) {
  const data = useQuery(api.matches.teamsInMatch, { matchNumber });
  const counts = useQuery(api.notes.countsForMatch, { matchNumber });
  const navigate = useNavigate();

  if (data === undefined || data === null) {
    return <p className="text-muted-foreground p-3 text-sm">Loading…</p>;
  }

  const countFor = (teamId: string) =>
    counts?.find((c) => c.teamId === teamId) ?? { count: 0, mine: false };

  const column = (
    teams: typeof data.red,
    label: string,
    tone: string,
  ) => (
    <div className="space-y-2">
      <p className={`text-xs font-medium uppercase tracking-wide ${tone}`}>{label}</p>
      {teams.map((team, index) =>
        team === null ? (
          <div key={index} className="text-muted-foreground rounded-md border p-3 text-sm">
            Unknown team
          </div>
        ) : (
          (() => {
            const { count, mine } = countFor(team._id);
            return (
              <button
                key={team._id}
                onClick={() => void navigate(`/scout/${matchNumber}/${team.number}`)}
                className={[
                  "flex min-h-14 w-full items-center gap-2 rounded-md border p-3 text-left transition-colors",
                  team.number === assignedTeam
                    ? "border-2 border-green-500 bg-green-500/10"
                    : team.number === highlight
                      ? "border-primary bg-primary/10"
                      : "hover:bg-accent/50",
                ].join(" ")}
              >
                <span className="font-semibold tabular-nums">{team.number}</span>
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {team.number === assignedTeam ? "yours" : team.nickname}
                </span>
                <Badge
                  variant={count === 0 ? "outline" : mine ? "secondary" : "default"}
                  className="shrink-0 tabular-nums"
                  title={
                    mine
                      ? "You have notes on this robot"
                      : "Notes written on this robot"
                  }
                >
                  {count}
                  {mine ? " ✓" : ""}
                </Badge>
              </button>
            );
          })()
        ),
      )}
    </div>
  );

  return (
    <div className="space-y-3 p-3">
      <div className="grid grid-cols-2 gap-4">
        {column(data.red, "Red", "text-red-600 dark:text-red-400")}
        {column(data.blue, "Blue", "text-blue-600 dark:text-blue-400")}
      </div>
      <p className="text-muted-foreground text-xs">
        The number is how many scouts have written notes on that robot. A tick
        means one of them is you. More than one is fine — a second look is a
        cross-check, not a duplicate.
      </p>
    </div>
  );
}

export default function NotesScoutLandingPage() {
  const matches = useQuery(api.matches.listForEvent);
  const myNotes = useQuery(api.notes.mine);
  const navigate = useNavigate();
  const [open, setOpen] = useState<number | null>(null);
  const [matchSearch, setMatchSearch] = useState("");
  const assignments = useQuery(api.notes.assignments);
  const assignedByMatch = new Map(
    (assignments?.assigned ?? []).map((a) => [a.matchNumber, a]),
  );

  // One box for both, because a scout looking for "their" match knows either
  // the match number or their assigned team — and often only one of them.
  const searchNumber = Number.parseInt(matchSearch.trim(), 10);
  const shown = useMemo(() => {
    if (!matches) return [];
    const needle = matchSearch.trim();
    if (needle === "") return matches;
    return matches.filter(
      (m) =>
        String(m.matchNumber) === needle ||
        (!Number.isNaN(searchNumber) &&
          (m.redTeamNumbers.includes(searchNumber) ||
            m.blueTeamNumbers.includes(searchNumber))),
    );
  }, [matches, matchSearch, searchNumber]);

  // A single hit is unambiguous, so open it rather than making them tap again.
  const onlyHit = shown.length === 1 ? (shown[0]?.matchNumber ?? null) : null;
  const expanded = onlyHit ?? open;
  const highlight =
    !Number.isNaN(searchNumber) &&
    matches?.some((m) =>
      m.redTeamNumbers.includes(searchNumber) ||
      m.blueTeamNumbers.includes(searchNumber))
      ? searchNumber
      : null;

  return (
    <PageShell
      title="Match Scouting"
      description="Search by match or team, then pick a robot. The badge shows how many notes that robot already has."
    >
      <Card>
        <CardHeader>
          <CardTitle>Matches</CardTitle>
          <CardDescription>
            {matches === undefined
              ? "Loading…"
              : matches.length === 0
                ? "No schedule imported yet."
                : `${matches.length} qualification matches.`}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <div className="flex gap-2">
            <Input
              placeholder="Match number or team number"
              inputMode="numeric"
              value={matchSearch}
              onChange={(e) => setMatchSearch(e.target.value)}
            />
            {matchSearch !== "" ? (
              <Button variant="ghost" size="icon" aria-label="Clear search"
                onClick={() => setMatchSearch("")}>
                <X className="size-4" />
              </Button>
            ) : null}
          </div>

          {matchSearch.trim() !== "" ? (
            <p className="text-muted-foreground text-xs">
              {shown.length === 0
                ? "No match with that number, and no team with that number is playing."
                : `${shown.length} match${shown.length === 1 ? "" : "es"} — a number can mean either a match or a team, so both are searched.`}
            </p>
          ) : null}

          {shown.map((match) => (
            <div key={match._id} className={[
              "rounded-lg border",
              assignedByMatch.has(match.matchNumber)
                ? "border-2 border-green-500 bg-green-500/5"
                : "",
            ].join(" ")}>
              <button
                onClick={() =>
                  setOpen(expanded === match.matchNumber ? null : match.matchNumber)
                }
                className="hover:bg-accent/50 flex min-h-14 w-full items-center gap-3 p-3 text-left transition-colors"
              >
                <span className="font-medium">Qual {match.matchNumber}</span>
                {assignedByMatch.has(match.matchNumber) ? (
                  <span className={[
                    "shrink-0 rounded px-1.5 py-0.5 text-[11px] font-medium text-white",
                    assignedByMatch.get(match.matchNumber)!.station.startsWith("red")
                      ? "bg-red-600" : "bg-blue-600",
                  ].join(" ")}>
                    {STATION_LABELS[assignedByMatch.get(match.matchNumber)!.station as Station]} · yours
                  </span>
                ) : null}
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {match.redTeamNumbers.join(", ")} vs {match.blueTeamNumbers.join(", ")}
                </span>
                <ChevronRight
                  className={`size-4 shrink-0 transition-transform ${
                    expanded === match.matchNumber ? "rotate-90" : ""
                  }`}
                />
              </button>
              {expanded === match.matchNumber ? (
                <MatchRobots matchNumber={match.matchNumber} highlight={highlight}
                  assignedTeam={assignedByMatch.get(match.matchNumber)?.teamNumber ?? null} />
              ) : null}
            </div>
          ))}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>My notes</CardTitle>
          <CardDescription>Newest first.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {myNotes === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : myNotes.length === 0 ? (
            <p className="text-muted-foreground text-sm">Nothing written yet.</p>
          ) : (
            myNotes.slice(0, 20).map((note) => (
              <button
                key={note.id}
                onClick={() => void navigate(`/scout/${note.matchNumber}/${note.teamNumber}`)}
                disabled={note.matchNumber === null || note.teamNumber === null}
                className="hover:bg-accent/50 flex w-full items-center gap-3 rounded-md border p-3 text-left text-sm transition-colors"
              >
                <span className="font-medium">Qual {note.matchNumber ?? "?"}</span>
                <span className="tabular-nums">{note.teamNumber ?? "?"}</span>
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {note.nickname}
                </span>
              </button>
            ))
          )}
        </CardContent>
      </Card>
    </PageShell>
  );
}
PATCH_EOF

cat > "$T/notes/team-detail.tsx" <<'PATCH_EOF'
import { useQuery } from "convex/react";
import type { ReactNode } from "react";

import { api } from "../../../convex/_generated/api";
import { StatLinks } from "@/components/stat-links";
import { useRatings } from "@/lib/stat-site";
import {
  Dialog, DialogContent, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";

/**
 * A team in a notes-only season: its rating from the chosen stat site, your
 * team's pit notes, and every match note written about it. No averages,
 * because nothing here is counted.
 */
export function NotesTeamDetail({
  teamNumber, onClose, footer,
}: {
  teamNumber: number | null;
  onClose: () => void;
  /** Rendered at the bottom. The pick list passes its note editor. */
  footer?: ReactNode;
}) {
  const data = useQuery(api.notes.forTeam, teamNumber === null ? "skip" : { teamNumber });
  const ratings = useRatings();
  const rating = teamNumber === null ? null : (ratings.byTeam.get(teamNumber) ?? null);

  return (
    <Dialog open={teamNumber !== null} onOpenChange={(open) => { if (!open) onClose(); }}>
      <DialogContent className="max-h-[85vh] max-w-3xl overflow-y-auto">
        {data === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) : data === null ? (
          <p className="text-muted-foreground text-sm">Team not found.</p>
        ) : (
          <>
            <DialogHeader>
              <DialogTitle className="flex flex-wrap items-center gap-2">
                <span className="tabular-nums">{data.team.number}</span>
                <span>{data.team.nickname}</span>
                <StatLinks kind="team" eventKey={data.eventKey} teamNumber={data.team.number} />
              </DialogTitle>
            </DialogHeader>

            <p className="text-muted-foreground text-sm">
              {[data.team.city, data.team.stateProv, data.team.country].filter(Boolean).join(", ")}
            </p>

            {rating ? (
              <div className="w-fit rounded-lg border p-3">
                <p className="text-muted-foreground text-xs">{ratings.metric}</p>
                <p className="text-xl font-semibold tabular-nums">{rating.total.toFixed(1)}</p>
                <p className="text-muted-foreground text-[10px]">
                  {ratings.siteName}, not your scouting
                </p>
              </div>
            ) : null}

            <div className="space-y-2">
              <h3 className="font-medium">Pit notes</h3>
              {data.pit ? (
                <div className="space-y-1 rounded-lg border p-3">
                  <p className="text-sm whitespace-pre-wrap">{data.pit.notes}</p>
                  <p className="text-muted-foreground text-xs">
                    {data.pit.scoutName} · {new Date(data.pit.updatedAt).toLocaleString()}
                  </p>
                </div>
              ) : (
                <p className="text-muted-foreground text-sm">Your team has no pit notes on them yet.</p>
              )}
            </div>

            <div className="space-y-2">
              <h3 className="font-medium">Match notes</h3>
              {data.matches.length === 0 ? (
                <p className="text-muted-foreground rounded-lg border border-dashed p-6 text-center text-sm">
                  No match notes yet.
                </p>
              ) : (
                <div className="space-y-2">
                  {data.matches.map((n) => (
                    <div key={n.id} className="space-y-1 rounded-lg border p-3">
                      <p className="text-xs font-medium">
                        {n.matchNumber === null ? "Unknown match" : `Qual ${n.matchNumber}`}
                        <span className="text-muted-foreground font-normal"> · {n.scoutName}</span>
                      </p>
                      <p className="text-sm whitespace-pre-wrap">{n.notes}</p>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {footer}
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}
PATCH_EOF

cat > "$T/notes/teams.tsx" <<'PATCH_EOF'
import { useQuery } from "convex/react";
import { useMemo, useState } from "react";
import { useSearchParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { NotesTeamDetail } from "./team-detail";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";

export default function NotesTeamsPage() {
  const teams = useQuery(api.notes.teams);
  const [search, setSearch] = useState("");
  // ?team=1002 opens that team, the same link the 2026 page answers to.
  const [params, setParams] = useSearchParams();
  const openTeam = Number.parseInt(params.get("team") ?? "", 10);

  const shown = useMemo(() => {
    const needle = search.trim().toLowerCase();
    return (teams ?? []).filter((t) =>
      needle === "" || String(t.number).includes(needle) || t.nickname.toLowerCase().includes(needle));
  }, [teams, search]);

  return (
    <PageShell title="Teams" description="Tap a team for its pit notes and every match note written about it.">
      <Input className="max-w-56" placeholder="Team number or name"
        value={search} onChange={(e) => setSearch(e.target.value)} />

      {teams === undefined ? (
        <p className="text-muted-foreground text-sm">Loading…</p>
      ) : shown.length === 0 ? (
        <p className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
          {(teams ?? []).length === 0 ? "No teams yet. An admin needs to import an event." : "Nothing matches."}
        </p>
      ) : (
        <div className="space-y-2">
          {shown.map((team) => (
            <button key={team.teamId}
              onClick={() => setParams({ team: String(team.number) })}
              className="hover:bg-accent/50 flex min-h-16 w-full items-center gap-3 rounded-lg border p-3 text-left transition-colors">
              <span className="w-14 shrink-0 text-lg font-semibold tabular-nums">{team.number}</span>
              <span className="min-w-0 flex-1 truncate text-sm">{team.nickname}</span>
              <Badge variant={team.pitNoted ? "default" : "outline"}>
                {team.pitNoted ? "Pit notes" : "No pit notes"}
              </Badge>
            </button>
          ))}
        </div>
      )}

      <NotesTeamDetail
        teamNumber={Number.isNaN(openTeam) ? null : openTeam}
        onClose={() => setParams({})}
      />
    </PageShell>
  );
}
PATCH_EOF

cat > "$T/apply.mjs" <<'PATCH_EOF'
// Applies every edit in memory first and writes nothing unless all of them
// found their anchors. Safe to re-run: files already patched are skipped.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { createHash } from "node:crypto";

const T = process.argv[2];
const staged = new Map();
const eol = new Map();
const report = [];
const fail = (message) => {
  console.error(`\nERROR: ${message}\nNothing was written.`);
  process.exit(1);
};

// Windows checkouts can carry CRLF. Match on LF, write back what was there.
function load(path) {
  if (staged.has(path)) return staged.get(path);
  if (!existsSync(path)) fail(`${path} not found. Run this from the repo root.`);
  const raw = readFileSync(path, "utf8");
  eol.set(path, raw.includes("\r\n") ? "\r\n" : "\n");
  return raw.replace(/\r\n/g, "\n");
}
const snippet = (name) => readFileSync(`${T}/${name}`, "utf8").replace(/\r\n/g, "\n");

function count(haystack, needle) {
  let n = 0;
  for (let i = haystack.indexOf(needle); i !== -1; i = haystack.indexOf(needle, i + 1)) n += 1;
  return n;
}

function once(s, find, replace, where) {
  const n = count(s, find);
  if (n !== 1) {
    fail(`${where}: expected 1 match, found ${n}, for:\n  ${find.split("\n")[0].trim()}`);
  }
  return s.replace(find, () => replace);
}

/** Replace the block from `start` up to (not including) `end`. */
function between(s, start, end, replace, where, mustContain) {
  if (count(s, start) !== 1) fail(`${where}: could not find the start of the block to replace.`);
  const from = s.indexOf(start);
  const to = s.indexOf(end, from);
  if (to === -1) fail(`${where}: could not find the end of the block to replace.`);
  if (mustContain && !s.slice(from, to).includes(mustContain)) {
    fail(`${where}: the block found does not look like the expected one.`);
  }
  return s.slice(0, from) + replace + s.slice(to);
}

/** Replace the first `find` after a unique `anchor`. */
function after(s, anchor, find, replace, where) {
  if (count(s, anchor) !== 1) fail(`${where}: anchor not unique.`);
  const at = s.indexOf(anchor);
  const i = s.indexOf(find, at);
  if (i === -1) fail(`${where}: nothing to replace after the anchor.`);
  return s.slice(0, i) + replace + s.slice(i + find.length);
}

function edit(path, doneMarker, fn) {
  const s = load(path);
  if (s.includes(doneMarker)) { report.push(`skip   ${path} (already patched)`); return; }
  staged.set(path, fn(s));
  report.push(`edit   ${path}`);
}

/**
 * A file this patch owns. `earlier` lists SHA-256 hashes of versions an
 * earlier run of this patch wrote: those are replaced, anything else is
 * someone's edit and stops the run.
 */
function create(path, name, earlier = []) {
  const content = snippet(name);
  if (existsSync(path)) {
    const current = readFileSync(path, "utf8").replace(/\r\n/g, "\n");
    if (current === content) { report.push(`skip   ${path} (already present)`); return; }
    const hash = createHash("sha256").update(current).digest("hex");
    if (earlier.includes(hash)) {
      staged.set(path, content);
      eol.set(path, "\n");
      report.push(`update ${path}`);
      return;
    }
    fail(`${path} already exists with different content. Move it aside and re-run.`);
  }
  staged.set(path, content);
  eol.set(path, "\n");
  report.push(`create ${path}`);
}


// ─── Prerequisites ─────────────────────────────────────────────────────────
for (const needed of ["src/components/stat-links.tsx", "src/lib/stat-site.ts", "convex/match13.ts"]) {
  if (!existsSync(needed)) fail(`${needed} is missing. Run patch-match13.sh first.`);
}

// ─── Convex ────────────────────────────────────────────────────────────────

create("convex/notes.ts", "notes.ts", ["76db0252f46b3fd7b21edfc0bffa08446a04cd81843edc735acedcaa31c0f777"]);

edit("convex/schema.ts", "pitNotes: defineTable", (s) => once(s,
  `  /**
   * Statbotics EPA for one team at one event.`,
  `  /**
   * Notes-only scouting, for seasons CircuitScout has no forms for. One pit
   * note per team per scouting team. Nothing in the 2026 pages reads these,
   * and nothing in the notes pages reads the 2026 report tables.
   */
  pitNotes: defineTable({
    eventId: v.id("events"),
    teamId: v.id("teams"),
    scoutId: v.id("users"),
    scoutingTeamNumber: v.number(),
    notes: v.string(),
    updatedAt: v.number(),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"]),

  /** One note per scout per robot per match. Pooled across scouting teams. */
  matchNotes: defineTable({
    eventId: v.id("events"),
    matchId: v.id("matches"),
    teamId: v.id("teams"),
    scoutId: v.id("users"),
    scoutingTeamNumber: v.number(),
    notes: v.string(),
    submittedAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"])
    .index("by_event_scout", ["eventId", "scoutId"])
    .index("by_match", ["matchId"]),

  /**
   * Statbotics EPA for one team at one event.`,
  "schema.ts"));

edit("convex/events.ts", "deleteNotes", (s) => {
  const w = "events.ts";
  if (!s.includes("async function deleteRatings(")) {
    fail(`${w}: deleteRatings not found. Run patch-match13.sh first.`);
  }
  s = once(s, "/** Shared by the immediate purge and the scheduled one. */",
    `/** Notes-only scouting for one event. Purged with everything else. */
async function deleteNotes(ctx: MutationCtx, eventId: Id<"events">) {
  const pit = await ctx.db
    .query("pitNotes")
    .withIndex("by_event", (q) => q.eq("eventId", eventId))
    .collect();
  for (const row of pit) await ctx.db.delete(row._id);
  const match = await ctx.db
    .query("matchNotes")
    .withIndex("by_event", (q) => q.eq("eventId", eventId))
    .collect();
  for (const row of match) await ctx.db.delete(row._id);
}

/** Shared by the immediate purge and the scheduled one. */`, w);
  s = once(s,
    "    await deleteRatings(ctx, args.eventId);\n\n    // Any team pointing at this event",
    "    await deleteRatings(ctx, args.eventId);\n    await deleteNotes(ctx, args.eventId);\n\n    // Any team pointing at this event", `${w} purge`);
  // Remove is for events nobody scouted. Notes are scouting, so they block it.
  s = once(s,
    `        \`\${event.name} holds \${reports.length} match and \${pit.length} pit reports. Nothing with scouting data can be removed.\`,
      );
    }
`,
    `        \`\${event.name} holds \${reports.length} match and \${pit.length} pit reports. Nothing with scouting data can be removed.\`,
      );
    }
    const anyNote =
      (await ctx.db.query("pitNotes").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).first()) ??
      (await ctx.db.query("matchNotes").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).first());
    if (anyNote) {
      throw new Error(\`\${event.name} holds scouting notes. Nothing with scouting data can be removed.\`);
    }
`, `${w} remove`);
  // The Events list: notes count as scouting data there too.
  s = once(s,
    "      const settings = allSettings\n        .filter((t) => t.activeEventId === event._id)",
    `      const pitNotes = await ctx.db
        .query("pitNotes")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const matchNotes = await ctx.db
        .query("matchNotes")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();

      const settings = allSettings
        .filter((t) => t.activeEventId === event._id)`, `${w} list`);
  s = once(s, "        pitCount: pit.length,\n",
    "        pitCount: pit.length,\n        noteCount: pitNotes.length + matchNotes.length,\n", `${w} list`);
  s = once(s,
    "        removable: anyReport === null && pit.length === 0 && !hasEntries,",
    "        removable: anyReport === null && pit.length === 0 && !hasEntries\n          && pitNotes.length === 0 && matchNotes.length === 0,", `${w} list`);
  // Delete-event preview.
  s = once(s,
    "    const [teams, matches, reports, pit, lists, settings] = await Promise.all([",
    "    const [teams, matches, reports, pit, lists, settings, pitNotes, matchNotes] = await Promise.all([", `${w} preview`);
  s = once(s,
    `      ctx.db.query("teamSettings").collect(),
    ]);`,
    `      ctx.db.query("teamSettings").collect(),
      ctx.db.query("pitNotes").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("matchNotes").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
    ]);`, `${w} preview`);
  s = once(s, "      pitReports: pit.length,\n      pickLists: lists.length,",
    "      pitReports: pit.length,\n      notes: pitNotes.length + matchNotes.length,\n      pickLists: lists.length,", `${w} preview`);
  return s;
});

{
  const path = "convex/_generated/api.d.ts";
  let s = load(path);
  let changed = false;
  if (!s.includes(`import type * as notes from "../notes.js";`)) {
    s = once(s, `import type * as pickLists from "../pickLists.js";`,
      `import type * as notes from "../notes.js";\nimport type * as pickLists from "../pickLists.js";`, "api.d.ts import notes");
    changed = true;
  }
  if (!s.includes("  notes: typeof notes;")) {
    s = once(s, "  pickLists: typeof pickLists;", "  notes: typeof notes;\n  pickLists: typeof pickLists;", "api.d.ts entry notes");
    changed = true;
  }
  if (changed) { staged.set(path, s); report.push(`edit   ${path}`); }
  else report.push(`skip   ${path} (already lists notes)`);
}

// ─── Season switch ─────────────────────────────────────────────────────────

create("src/lib/season.ts", "season.ts");
create("src/components/season-provider.tsx", "season-provider.tsx");
create("src/routes/seasons.tsx", "seasons.tsx");
// Earlier versions of files this patch has since changed.
const EARLIER = {
  "scout.tsx": ["1a3d01cf6c35a0aa2c90919b1fd7e34a13a4f5043c24e70248c1c9a20cea6c6c"],
  "dashboard.tsx": ["33f97d656d9cea531b02b0c17aa2051d6fa4c1be13fd254c5902b731e18e4ba0"],
};
for (const f of [
  "not-available.tsx", "note-editor.tsx", "pit.tsx", "pit-form.tsx", "scout.tsx",
  "scout-form.tsx", "team-detail.tsx", "teams.tsx", "match.tsx", "export.tsx",
  "dashboard.tsx", "admin-notes.tsx", "board.tsx",
]) create(`src/routes/notes/${f}`, `notes/${f}`, EARLIER[f] ?? []);

edit("src/routes/app-layout.tsx", "SeasonProvider", (s) => {
  s = once(s, `import { AppNav } from "@/components/app-nav";`,
    `import { AppNav } from "@/components/app-nav";\nimport { SeasonProvider } from "@/components/season-provider";`, "app-layout");
  s = once(s, "        <Outlet />", "        <SeasonProvider>\n          <Outlet />\n        </SeasonProvider>", "app-layout");
  return s;
});

edit("src/routes/router.tsx", "SeasonPage", (s) => {
  const w = "router.tsx";
  // These pages now come in through the season registry.
  for (const line of [
    `import DashboardPage from "./dashboard";\n`,
    `import PitLandingPage from "./pit/index";\n`,
    `import PitFormPage from "./pit/form";\n`,
    `import ScoutLandingPage from "./scout/index";\n`,
    `import MatchFormPage from "./scout/form";\n`,
    `import TeamsPage from "./teams/index";\n`,
    `import ComparePage from "./teams/compare";\n`,
    `import PlotPage from "./teams/plot";\n`,
    `import MatchesPage from "./matches/index";\n`,
    `import MatchPreviewPage from "./matches/preview";\n`,
    `import PickListsPage from "./picklists/index";\n`,
    `import PickListBoardPage from "./picklists/board";\n`,
    `import AdminDataPage from "./admin/data";\n`,
  ]) s = once(s, line, "", w);
  s = once(s, `import { RootLayout } from "./root-layout";\n`,
    `import { RootLayout } from "./root-layout";\nimport { SeasonPage } from "./seasons";\n`, w);
  for (const [from, to] of [
    [`{ index: true, element: <DashboardPage /> }`, `{ index: true, element: <SeasonPage page="dashboard" /> }`],
    [`{ path: "pit", element: <PitLandingPage /> }`, `{ path: "pit", element: <SeasonPage page="pit" /> }`],
    [`{ path: "pit/:teamNumber", element: <PitFormPage /> }`, `{ path: "pit/:teamNumber", element: <SeasonPage page="pitForm" /> }`],
    [`{ path: "scout", element: <ScoutLandingPage /> }`, `{ path: "scout", element: <SeasonPage page="scout" /> }`],
    [`{ path: "scout/:matchNumber/:teamNumber", element: <MatchFormPage /> }`, `{ path: "scout/:matchNumber/:teamNumber", element: <SeasonPage page="scoutForm" /> }`],
    [`{ path: "teams", element: <TeamsPage /> }`, `{ path: "teams", element: <SeasonPage page="teams" /> }`],
    [`{ path: "teams/compare", element: <ComparePage /> }`, `{ path: "teams/compare", element: <SeasonPage page="teamsCompare" /> }`],
    [`{ path: "teams/plot", element: <PlotPage /> }`, `{ path: "teams/plot", element: <SeasonPage page="teamsPlot" /> }`],
    [`{ path: "matches", element: <MatchesPage /> }`, `{ path: "matches", element: <SeasonPage page="matches" /> }`],
    [`{ path: "matches/:matchNumber", element: <MatchPreviewPage /> }`, `{ path: "matches/:matchNumber", element: <SeasonPage page="matchPreview" /> }`],
    [`{ path: "picklists", element: <PickListsPage /> }`, `{ path: "picklists", element: <SeasonPage page="pickLists" /> }`],
    [`{ path: "picklists/:listId", element: <PickListBoardPage /> }`, `{ path: "picklists/:listId", element: <SeasonPage page="pickListBoard" /> }`],
    [`{ path: "admin/data", element: <AdminDataPage /> }`, `{ path: "admin/data", element: <SeasonPage page="adminData" /> }`],
  ]) s = once(s, from, to, w);
  return s;
});

edit("src/routes/admin/index.tsx", "SeasonAdminReports", (s) => {
  const w = "admin/index.tsx";
  s = once(s,
    `import {
  DeletionLog, FlaggedReports, ManageReports, PitReportsAdmin,
  TeamsNeedingAttention,
} from "./reports-admin";`,
    `import { SeasonAdminReports } from "@/routes/seasons";`, w);
  s = once(s,
    `      <TeamsNeedingAttention />

      <FlaggedReports />

      <ManageReports />

      <PitReportsAdmin />

      <DeletionLog />`,
    `      {/* 2026 report tools, or the notes tools for a notes-only season. */}
      <SeasonAdminReports />`, w);
  s = once(s,
    `                    {event.reportCount + event.pitCount} report
                    {event.reportCount + event.pitCount === 1 ? "" : "s"}`,
    `                    {event.noteCount > 0
                      ? \`\${event.noteCount} note\${event.noteCount === 1 ? "" : "s"}\`
                      : \`\${event.reportCount + event.pitCount} report\${event.reportCount + event.pitCount === 1 ? "" : "s"}\`}`, w);
  s = once(s,
    "    preview.matchReports === 0 && preview.pitReports === 0 && preview.pickLists === 0;",
    "    preview.matchReports === 0 && preview.pitReports === 0 && preview.pickLists === 0\n    && preview.notes === 0;", w);
  s = once(s,
    "        <li>{preview.pitReports} pit reports</li>",
    "        <li>{preview.pitReports} pit reports</li>\n        {preview.notes > 0 ? <li>{preview.notes} notes</li> : null}", w);
  return s;
});

// ─── Write ─────────────────────────────────────────────────────────────────

for (const [path, content] of staged) {
  // Only when missing: Bun on Windows throws EEXIST for mkdir(".") even with
  // recursive set, which is the folder index.html sits in.
  const dir = dirname(path);
  if (dir !== "." && !existsSync(dir)) mkdirSync(dir, { recursive: true });
  writeFileSync(path, eol.get(path) === "\r\n" ? content.replace(/\n/g, "\r\n") : content);
}
console.log(report.join("\n"));
PATCH_EOF

say "Applying"
bun "$T/apply.mjs" "$T"

say "Typecheck"
if [[ -d node_modules ]]; then
  bunx tsc -b --noEmit && bunx tsc -p convex --noEmit && echo "Typecheck clean."
else
  echo "node_modules missing; run bun install, then bun run typecheck."
fi

cat <<'NEXT'

Next:
  1. bunx convex dev   (adds the pitNotes and matchNotes tables)
  2. 2026 events look exactly as before. To see the notes pages, import an
     event from a year without forms (a 2025 or 2027 event) and activate it.
NEXT
