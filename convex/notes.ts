import { v, type ObjectType } from "convex/values";
import { mutation, query } from "./_generated/server";
import type { MutationCtx, QueryCtx } from "./_generated/server";
import type { Doc, Id } from "./_generated/dataModel";
import { isPracticing, isPracticingAs, savePractice, savePracticeAs } from "./lib/practice";
import {
  activeEvent, activeEventOf, currentProfile, currentTeamNumber, managesTeam, requireTeamAdmin,
  requireUser, teamNumberOf,
} from "./lib/guards";
import { stationIndex, type Station } from "./lib/types";
import {
  genericPitIsBlank, genericPitMissing, genericPitStatus, GENERIC_PIT_LABELS,
  type GenericPitStatus,
} from "./lib/genericPit";
import { MAX_OTHER_SPARES, batteryText, spareText } from "./lib/spares";
import { matchSections } from "./lib/genericMatch";

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
    const statusByTeam = new Map(
      pit.filter((p) => p.scoutingTeamNumber === myTeam).map((p) => [p.teamId, genericPitStatus(p)]),
    );
    return teams
      .sort((a, b) => a.number - b.number)
      .map((t) => ({
        teamId: t._id,
        number: t.number,
        nickname: t.nickname,
        pitNoted: noted.has(t._id),
        pitStatus: statusByTeam.get(t._id) ?? ("none" as GenericPitStatus),
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
    // Practice starts from a blank form, not the team's real report.
    const row = (await isPracticing(ctx)) ? null : ((
      await ctx.db
        .query("pitNotes")
        .withIndex("by_event_team", (q) => q.eq("eventId", event._id).eq("teamId", team._id))
        .collect()
    ).find((p) => p.scoutingTeamNumber === myTeam) ?? null);
    const names = row ? await namesByUser(ctx) : null;
    return {
      teamNumber: team.number,
      nickname: team.nickname,
      photoUrl: row?.photoId ? await ctx.storage.getUrl(row.photoId) : null,
      note: row
        ? {
            notes: row.notes,
            updatedAt: row.updatedAt,
            scoutName: names?.get(row.scoutId) ?? "Unknown scout",
            scoringText: row.scoringText ?? "",
            drivetrain: row.drivetrain ?? "",
            drivetrainGearing: row.drivetrainGearing ?? "",
            robotWeight: row.robotWeight ?? null,
            spares: row.spares ?? [],
            batteries: row.batteries ?? [],
            otherNotes: row.otherNotes ?? "",
            status: genericPitStatus(row),
            missing: genericPitMissing(row),
          }
        : null,
    };
  },
});

export const savePit = mutation({
  args: { teamNumber: v.number(), notes: v.string() },
  handler: async (ctx, args) => {
    const scoutId = await requireUser(ctx);
    if (await isPracticing(ctx)) {
      return await savePractice(ctx, {
        kind: "pitNote", teamNumber: args.teamNumber, matchNumber: null, payload: { notes: args.notes },
      });
    }
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

const genericSpare = v.object({
  part: v.union(v.literal("swerve"), v.literal("other")),
  quantity: v.optional(v.number()),
  specify: v.string(),
});
const genericBattery = v.object({
  type: v.union(v.literal("mk"), v.literal("energizer"), v.literal("duracell"), v.literal("other")),
  otherType: v.optional(v.string()),
  quantity: v.optional(v.number()),
});

function count(n: number | undefined, what: string): number | undefined {
  if (n === undefined) return undefined;
  if (!Number.isInteger(n) || n < 1 || n > 999) throw new Error(`${what} must be whole numbers from 1 to 999.`);
  return n;
}
function text(s: string, max: number, what: string): string {
  const t = s.trim();
  if (t.length > max) throw new Error(`${what} is limited to ${max} characters.`);
  return t;
}

/**
 * The pit form for seasons without their own forms. One report per team per
 * scouting team, like 2026: a second scout from the same team updates it.
 */
export const savePitReportArgs = {
    teamNumber: v.number(),
    scoringText: v.string(),
    drivetrain: v.string(),
    drivetrainGearing: v.string(),
    robotWeight: v.union(v.number(), v.null()),
    spares: v.array(genericSpare),
    batteries: v.array(genericBattery),
    photoId: v.union(v.id("_storage"), v.null()),
    notes: v.string(),
    otherNotes: v.string(),
};

/**
 * Writes one other-season pit report for the given scout's team.
 * notes.savePitReport calls it for the signed-in scout; a report held offline
 * arrives through convex/lib/transfer.ts with held set. A held report was
 * filled in without seeing what is stored, so its blanks keep the stored
 * answers; where both have an answer the new one wins.
 */
export async function writeGenericPit(
  ctx: MutationCtx,
  scoutId: Id<"users">,
  args: ObjectType<typeof savePitReportArgs>,
  held = false,
) {
    const event = await activeEventOf(ctx, scoutId);
    if (!event) throw new Error("No active event.");
    const scoutingTeamNumber = await teamNumberOf(ctx, scoutId);
    if (scoutingTeamNumber === undefined) {
      throw new Error("Set your team number on your profile first.");
    }
    const team = await teamByNumber(ctx, event._id, args.teamNumber);
    if (!team) throw new Error("That team is not part of the active event.");

    // Checked here as well as in the form: a stale or edited client cannot skip it.
    let others = 0;
    let swerve = 0;
    const spares = args.spares.map((s) => {
      if (s.part === "other" && ++others > MAX_OTHER_SPARES) {
        throw new Error(`List at most ${MAX_OTHER_SPARES} Other spares.`);
      }
      if (s.part === "swerve" && ++swerve > 1) throw new Error("Swerve modules can only be listed once.");
      const quantity = count(s.quantity, "Spare quantities");
      const specify = text(s.specify, 200, "Spare details");
      if (specify === "") throw new Error("Say what each spare is.");
      return quantity === undefined ? { part: s.part, specify } : { part: s.part, quantity, specify };
    });
    if (args.batteries.length > 20) throw new Error("List at most 20 battery types.");
    const batteries = args.batteries.map((b) => {
      if (b.quantity === undefined) throw new Error("Say how many of each battery are in good condition.");
      const quantity = count(b.quantity, "Battery counts");
      if (b.type !== "other") return { type: b.type, quantity };
      const otherType = text(b.otherType ?? "", 50, "A battery brand");
      if (otherType === "") throw new Error("Say which brand each Other battery is.");
      return { type: b.type, otherType, quantity };
    });
    let robotWeight: number | undefined;
    if (args.robotWeight !== null) {
      if (!Number.isFinite(args.robotWeight) || args.robotWeight < 10 || args.robotWeight > 200) {
        throw new Error("Robot weight must be between 10 and 200 lbs.");
      }
      robotWeight = Math.round(args.robotWeight * 10) / 10;
    }
    const fields = {
      scoringText: text(args.scoringText, 2000, "Scoring capability"),
      drivetrain: text(args.drivetrain, 200, "Drivetrain"),
      drivetrainGearing: text(args.drivetrainGearing, 100, "Drivetrain gearing"),
      robotWeight,
      spares,
      batteries,
      notes: text(args.notes, MAX_NOTE, "Robot notes"),
      otherNotes: text(args.otherNotes, MAX_NOTE, "Other notes"),
    };

    if (await isPracticingAs(ctx, scoutId)) {
      // A practice photo is not kept.
      if (args.photoId) await ctx.storage.delete(args.photoId);
      return await savePracticeAs(ctx, scoutId, {
        kind: "pitNote", teamNumber: team.number, matchNumber: null, payload: fields,
      });
    }

    const existing = (
      await ctx.db
        .query("pitNotes")
        .withIndex("by_event_team", (q) => q.eq("eventId", event._id).eq("teamId", team._id))
        .collect()
    ).find((p) => p.scoutingTeamNumber === scoutingTeamNumber);

    const kept = held && existing
      ? {
          scoringText: fields.scoringText || existing.scoringText || "",
          drivetrain: fields.drivetrain || existing.drivetrain || "",
          drivetrainGearing: fields.drivetrainGearing || existing.drivetrainGearing || "",
          robotWeight: fields.robotWeight ?? existing.robotWeight,
          spares: fields.spares.length > 0 ? fields.spares : existing.spares ?? [],
          batteries: fields.batteries.length > 0 ? fields.batteries : existing.batteries ?? [],
          notes: fields.notes || existing.notes,
          otherNotes: fields.otherNotes || existing.otherNotes || "",
        }
      : fields;

    const row = {
      ...kept,
      // Keep the old photo when this save did not include a new one.
      photoId: args.photoId ?? existing?.photoId ?? null,
      scoutId,
      scoutingTeamNumber,
      updatedAt: Date.now(),
    };
    if (genericPitIsBlank(row)) throw new Error("Nothing is filled in, so there is nothing to save.");

    if (existing) {
      await ctx.db.patch(existing._id, row);
      return existing._id;
    }
    return await ctx.db.insert("pitNotes", { eventId: event._id, teamId: team._id, ...row });
}

export const savePitReport = mutation({
  args: savePitReportArgs,
  handler: async (ctx, args) => await writeGenericPit(ctx, await requireUser(ctx), args),
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
    // Practice starts from a blank form, not the scout's real report.
    const mine = (await isPracticing(ctx)) ? null : ((
      await ctx.db
        .query("matchNotes")
        .withIndex("by_match", (q) => q.eq("matchId", match._id))
        .collect()
    ).find((n) => n.teamId === team._id && n.scoutId === userId) ?? null);
    return {
      matchNumber: match.matchNumber,
      teamNumber: team.number,
      nickname: team.nickname,
      alliance,
      notes: mine?.notes ?? null,
      report: mine
        ? {
            autoPath: mine.autoPath ?? "",
            autoScoring: mine.autoScoring ?? "",
            teleopScoring: mine.teleopScoring ?? "",
            endgame: mine.endgame ?? "",
            driver: mine.driver ?? null,
            defense: mine.defense ?? null,
            broke: mine.broke ?? false,
            brokeNotes: mine.brokeNotes ?? "",
            inconsistent: mine.inconsistent ?? false,
            inconsistentNotes: mine.inconsistentNotes ?? "",
            notes: mine.notes,
          }
        : null,
    };
  },
});

export const saveMatch = mutation({
  args: { matchNumber: v.number(), teamNumber: v.number(), notes: v.string() },
  handler: async (ctx, args) => {
    const scoutId = await requireUser(ctx);
    if (await isPracticing(ctx)) {
      return await savePractice(ctx, {
        kind: "matchNote", teamNumber: args.teamNumber, matchNumber: args.matchNumber,
        payload: { notes: args.notes },
      });
    }
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

/**
 * The match form for seasons without their own forms. One report per scout
 * per robot per match; saving again replaces it.
 */
export const saveMatchReportArgs = {
    matchNumber: v.number(),
    teamNumber: v.number(),
    autoPath: v.string(),
    autoScoring: v.string(),
    teleopScoring: v.string(),
    endgame: v.string(),
    driver: v.number(),
    defense: v.number(),
    broke: v.boolean(),
    brokeNotes: v.string(),
    inconsistent: v.boolean(),
    inconsistentNotes: v.string(),
    notes: v.string(),
};

/**
 * Writes one other-season match report for the given scout.
 * notes.saveMatchReport calls it for the signed-in scout; a report held
 * offline arrives through convex/lib/transfer.ts with held set, which keeps
 * the scout's stored answers where the held report is blank.
 */
export async function writeGenericMatch(
  ctx: MutationCtx,
  scoutId: Id<"users">,
  args: ObjectType<typeof saveMatchReportArgs>,
  held = false,
) {
    const event = await activeEventOf(ctx, scoutId);
    if (!event) throw new Error("No active event.");
    const scoutingTeamNumber = await teamNumberOf(ctx, scoutId);
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

    const rating = (n: number, what: string) => {
      if (!Number.isInteger(n) || n < 1 || n > 10) throw new Error(`${what} rating must be from 1 to 10.`);
      return n;
    };
    const notes = args.notes.trim();
    if (notes === "") throw new Error("Final notes are required.");
    const fields = {
      autoPath: text(args.autoPath, 2000, "Auto path"),
      autoScoring: text(args.autoScoring, 2000, "Auto scoring"),
      teleopScoring: text(args.teleopScoring, 2000, "Teleop scoring"),
      endgame: text(args.endgame, 2000, "Endgame"),
      driver: rating(args.driver, "Driver"),
      defense: rating(args.defense, "Defense"),
      broke: args.broke,
      brokeNotes: args.broke ? text(args.brokeNotes, 500, "What happened") : "",
      inconsistent: args.inconsistent,
      inconsistentNotes: args.inconsistent ? text(args.inconsistentNotes, 500, "In what way") : "",
      notes: text(notes, MAX_NOTE, "Final notes"),
    };

    if (await isPracticingAs(ctx, scoutId)) {
      return await savePracticeAs(ctx, scoutId, {
        kind: "matchNote", teamNumber: team.number, matchNumber: match.matchNumber, payload: fields,
      });
    }

    const existing = (
      await ctx.db
        .query("matchNotes")
        .withIndex("by_match", (q) => q.eq("matchId", match._id))
        .collect()
    ).find((n) => n.teamId === team._id && n.scoutId === scoutId);

    const now = Date.now();
    if (existing) {
      // An unticked box is a blank too: it cannot untick what is stored.
      const kept = held
        ? {
            ...fields,
            autoPath: fields.autoPath || existing.autoPath || "",
            autoScoring: fields.autoScoring || existing.autoScoring || "",
            teleopScoring: fields.teleopScoring || existing.teleopScoring || "",
            endgame: fields.endgame || existing.endgame || "",
            broke: fields.broke || existing.broke === true,
            brokeNotes: fields.brokeNotes || existing.brokeNotes || "",
            inconsistent: fields.inconsistent || existing.inconsistent === true,
            inconsistentNotes: fields.inconsistentNotes || existing.inconsistentNotes || "",
          }
        : fields;
      await ctx.db.patch(existing._id, { ...kept, scoutingTeamNumber, updatedAt: now });
      return existing._id;
    }
    return await ctx.db.insert("matchNotes", {
      eventId: event._id,
      matchId: match._id,
      teamId: team._id,
      scoutId,
      scoutingTeamNumber,
      ...fields,
      submittedAt: now,
      updatedAt: now,
    });
}

export const saveMatchReport = mutation({
  args: saveMatchReportArgs,
  handler: async (ctx, args) => await writeGenericMatch(ctx, await requireUser(ctx), args),
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
        ? {
            notes: pit.notes,
            updatedAt: pit.updatedAt,
            scoutName: names.get(pit.scoutId) ?? "Unknown scout",
            scoringText: pit.scoringText ?? "",
            drivetrain: pit.drivetrain ?? "",
            drivetrainGearing: pit.drivetrainGearing ?? "",
            robotWeight: pit.robotWeight ?? null,
            spares: (pit.spares ?? []).map(spareText),
            batteries: (pit.batteries ?? []).map(batteryText),
            otherNotes: pit.otherNotes ?? "",
            photoUrl: pit.photoId ? await ctx.storage.getUrl(pit.photoId) : null,
            status: genericPitStatus(pit),
            missing: genericPitMissing(pit),
          }
        : null,
      matches: notes
        .map((n) => ({
          id: n._id,
          matchNumber: matchNumberById.get(n.matchId) ?? null,
          scoutName: names.get(n.scoutId) ?? "Unknown scout",
          notes: n.notes,
          sections: matchSections(n),
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
                  sections: matchSections(n),
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
          status: GENERIC_PIT_LABELS[genericPitStatus(p)],
          scoring: p.scoringText ?? "",
          drivetrain: p.drivetrain ?? "",
          drivetrainGearing: p.drivetrainGearing ?? "",
          robotWeightLbs: p.robotWeight ?? "",
          spares: (p.spares ?? []).map(spareText).join("; "),
          batteriesInGoodCondition: (p.batteries ?? []).map(batteryText).join("; "),
          notes: p.notes,
          otherNotes: p.otherNotes ?? "",
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
            autoPath: n.autoPath ?? "",
            autoScoring: n.autoScoring ?? "",
            teleopScoring: n.teleopScoring ?? "",
            endgame: n.endgame ?? "",
            driver: n.driver ?? "",
            defense: n.defense ?? "",
            broke: n.broke ? (n.brokeNotes || "yes") : "",
            inconsistent: n.inconsistent ? (n.inconsistentNotes || "yes") : "",
            finalNotes: n.notes,
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

