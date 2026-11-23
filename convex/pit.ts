import { v, type Infer, type ObjectType } from "convex/values";
import { mutation, query } from "./_generated/server";
import {
  activeEvent, activeEventOf, currentTeamNumber, requireUser, teamNumberOf,
} from "./lib/guards";
import type { Doc, Id } from "./_generated/dataModel";
import type { QueryCtx, MutationCtx } from "./_generated/server";
import { isPracticing, isPracticingAs, savePracticeAs } from "./lib/practice";
import { MAX_OTHER_SPARES, SPARE_PARTS, type Battery, type Spare } from "./lib/spares";
import { pitIsBlank } from "./lib/pitStatus";

const scoringInput = v.object({
  turret: v.boolean(),
  drumNonFullWidth: v.boolean(),
  drumFullWidth: v.boolean(),
  fixed: v.boolean(),
  kitbot: v.boolean(),
  other: v.boolean(),
  otherText: v.string(),
});

const climbInput = v.object({
  low: v.boolean(),
  mid: v.boolean(),
  high: v.boolean(),
  duringAuto: v.boolean(),
});

const hopperInput = v.object({
  roof: v.union(
    v.literal("solid"), v.literal("expanding"), v.literal("net"),
    v.literal("none"), v.null(),
  ),
  capacity: v.union(v.number(), v.null()),
  expandedCapacity: v.union(v.number(), v.null()),
});

/** Whole numbers only, and an expanded capacity only where the roof expands. */
function cleanHopper(h: Infer<typeof hopperInput>): Infer<typeof hopperInput> {
  const count = (n: number | null, what: string): number | null => {
    if (n === null) return null;
    if (!Number.isInteger(n) || n < 0 || n > 999) {
      throw new Error(`${what} must be a whole number from 0 to 999.`);
    }
    return n;
  };
  const expands = h.roof === "expanding" || h.roof === "net";
  return {
    roof: h.roof,
    capacity: count(h.capacity, "Hopper capacity"),
    expandedCapacity: expands
      ? count(h.expandedCapacity, "Expanded hopper capacity")
      : null,
  };
}

const spareInput = v.object({
  part: v.union(
    v.literal("intake"), v.literal("indexer"), v.literal("shooter"),
    v.literal("swerve"), v.literal("other"),
  ),
  quantity: v.optional(v.number()),
  specify: v.string(),
});

const batteryInput = v.object({
  type: v.union(
    v.literal("mk"), v.literal("energizer"), v.literal("duracell"), v.literal("other"),
  ),
  otherType: v.optional(v.string()),
  quantity: v.optional(v.number()),
  // Phones still running the old bundle send it; it is ignored.
  condition: v.optional(v.string()),
});

/** An optional count: absent, or a whole number from 1 to 999. */
function optionalCount(n: number | undefined, what: string): number | undefined {
  if (n === undefined) return undefined;
  if (!Number.isInteger(n) || n < 1 || n > 999) {
    throw new Error(`${what} must be whole numbers from 1 to 999.`);
  }
  return n;
}

/**
 * A spare needs to say what exactly it is; the count is an optional estimate.
 * Intake, indexer, shooter and swerve appear once at most; Other can repeat,
 * one row per thing. The form checks this too, but the server is what a stale
 * or edited client cannot skip.
 */
function cleanSpares(spares: Spare[]): Spare[] {
  const seen = new Set<string>();
  const order = new Map(SPARE_PARTS.map((p, i) => [p.part, i]));
  let others = 0;
  return spares
    .map((s) => {
      if (s.part === "other") {
        others += 1;
        if (others > MAX_OTHER_SPARES) {
          throw new Error(`List at most ${MAX_OTHER_SPARES} Other spares.`);
        }
      } else {
        if (seen.has(s.part)) throw new Error("Each spare part can only be listed once.");
        seen.add(s.part);
      }
      const quantity = optionalCount(s.quantity, "Spare quantities");
      const specify = s.specify.trim();
      if (specify === "") throw new Error("Say what each spare is.");
      if (specify.length > 200) throw new Error("Spare details are limited to 200 characters.");
      // Built field by field so an absent count is left out, not stored as undefined.
      return quantity === undefined
        ? { part: s.part, specify }
        : { part: s.part, quantity, specify };
    })
    // sort is stable, so several Other rows keep the order they were added in.
    .sort((a, b) => (order.get(a.part) ?? 0) - (order.get(b.part) ?? 0));
}

/** A type and a good-condition count on every row, and a brand for Other. */
function cleanBatteries(batteries: Battery[]): Battery[] {
  if (batteries.length > 20) throw new Error("List at most 20 battery types.");
  return batteries.map((b) => {
    if (b.quantity === undefined) {
      throw new Error("Say how many of each battery are in good condition.");
    }
    const quantity = optionalCount(b.quantity, "Battery counts");
    // condition is no longer stored, even when an old client sends one.
    const row: Battery = { type: b.type };
    if (b.type === "other") {
      const otherType = (b.otherType ?? "").trim();
      if (otherType === "") throw new Error("Say which brand each Other battery is.");
      if (otherType.length > 50) throw new Error("Battery brands are limited to 50 characters.");
      row.otherType = otherType;
    }
    if (quantity !== undefined) row.quantity = quantity;
    return row;
  });
}

/** Pounds with bumpers and battery, rounded to one decimal place; null clears it. */
function cleanWeight(pounds: number | null): number | undefined {
  if (pounds === null) return undefined;
  if (!Number.isFinite(pounds) || pounds < 10 || pounds > 200) {
    throw new Error("Robot weight must be between 10 and 200 lbs.");
  }
  return Math.round(pounds * 10) / 10;
}

/** Trimmed; blank clears it. */
function cleanGearing(text: string): string | undefined {
  const gearing = text.trim();
  if (gearing.length > 100) throw new Error("Drivetrain gearing is limited to 100 characters.");
  return gearing === "" ? undefined : gearing;
}

/**
 * One pit report per robot PER SCOUTING TEAM. Two teams at the same
 * competition each keep their own; without this the second team to visit a pit
 * silently overwrote the first.
 */
export async function mine(
  ctx: QueryCtx | MutationCtx,
  eventId: Id<"events">,
  teamId: Id<"teams">,
): Promise<Doc<"pitReports"> | null> {
  const scoutingTeamNumber = await currentTeamNumber(ctx);
  if (scoutingTeamNumber === undefined) return null;
  return await reportFor(ctx, eventId, teamId, scoutingTeamNumber);
}

/** A given scouting team's report on a robot. */
async function reportFor(
  ctx: QueryCtx | MutationCtx,
  eventId: Id<"events">,
  teamId: Id<"teams">,
  scoutingTeamNumber: number,
): Promise<Doc<"pitReports"> | null> {
  const rows = await ctx.db
    .query("pitReports")
    .withIndex("by_event_team", (q) =>
      q.eq("eventId", eventId).eq("teamId", teamId))
    .collect();
  return rows.find((r) => r.scoutingTeamNumber === scoutingTeamNumber) ?? null;
}

export const get = query({
  args: { teamId: v.id("teams") },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    return await mine(ctx, event._id, args.teamId);
  },
});

/** Resolves a team by number for the /pit/:teamNumber route. */
export const forTeamNumber = query({
  args: { teamNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;

    const team = await ctx.db
      .query("teams")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("number", args.teamNumber))
      .unique();
    if (!team) return null;

    // Practice starts from a blank form, not the team's real report.
    const report = (await isPracticing(ctx)) ? null : await mine(ctx, event._id, team._id);
    const photoUrl = report?.photoId ? await ctx.storage.getUrl(report.photoId) : null;

    return { team, report, photoUrl };
  },
});

export const generateUploadUrl = mutation({
  args: {},
  handler: async (ctx) => {
    await requireUser(ctx);
    return await ctx.storage.generateUploadUrl();
  },
});

/**
 * A second scout from the same team visiting the same pit updates their team's
 * report rather than creating a duplicate — pits get revisited, and two
 * conflicting reports for one robot is worse than one that changed.
 */
export const upsertArgs = {
    teamId: v.id("teams"),
    scoring: scoringInput,
    climb: climbInput,
    drivetrain: v.string(),
    underTrench: v.boolean(),
    overBump: v.boolean(),
    robotNotes: v.string(),
    otherNotes: v.string(),
    photoId: v.union(v.id("_storage"), v.null()),
    // Optional so a phone still running the old bundle can save mid-event.
    hopper: v.optional(hopperInput),
    // Optional for the same reason as hopper.
    spares: v.optional(v.array(spareInput)),
    batteries: v.optional(v.array(batteryInput)),
    // Optional for the same reason. null clears a weight that was set.
    robotWeight: v.optional(v.union(v.number(), v.null())),
    drivetrainGearing: v.optional(v.string()),
};
type UpsertArgs = ObjectType<typeof upsertArgs>;

/**
 * For a report that was filled in without seeing what is stored (held
 * offline, then sent): a blank in it means "not answered", so it takes the
 * stored answer instead of clearing it. Where both have an answer the new one
 * wins. An unticked box is a blank, and a group of boxes is one answer.
 */
function keepStoredAnswers(args: UpsertArgs, stored: Doc<"pitReports">): UpsertArgs {
  const blank = (text: string) => text.trim() === "";
  const s = args.scoring;
  const noScoring = !(s.turret || s.drumNonFullWidth || s.drumFullWidth || s.fixed || s.kitbot || s.other)
    && blank(s.otherText);
  const c = args.climb;
  const noClimb = !(c.low || c.mid || c.high || c.duringAuto);
  return {
    ...args,
    scoring: noScoring ? stored.scoring : s,
    climb: noClimb ? stored.climb : c,
    drivetrain: blank(args.drivetrain) ? stored.drivetrain : args.drivetrain,
    underTrench: args.underTrench || stored.underTrench,
    overBump: args.overBump || stored.overBump,
    robotNotes: blank(args.robotNotes) ? stored.robotNotes : args.robotNotes,
    otherNotes: blank(args.otherNotes) ? stored.otherNotes : args.otherNotes,
    hopper: args.hopper && {
      roof: args.hopper.roof ?? stored.hopper?.roof ?? null,
      capacity: args.hopper.capacity ?? stored.hopper?.capacity ?? null,
      expandedCapacity: args.hopper.expandedCapacity ?? stored.hopper?.expandedCapacity ?? null,
    },
    // Left out, these keep what is stored (see the fields below).
    spares: args.spares?.length ? args.spares : undefined,
    batteries: args.batteries?.length ? args.batteries : undefined,
    robotWeight: args.robotWeight ?? undefined,
    drivetrainGearing: args.drivetrainGearing === undefined || blank(args.drivetrainGearing)
      ? undefined
      : args.drivetrainGearing,
  };
}

/**
 * Writes one pit report for the given scout's team. pit.upsert calls it for
 * the signed-in scout; a report held offline arrives through
 * convex/lib/transfer.ts with held set, which keeps stored answers where the
 * held report is blank.
 */
export async function writePitReport(
  ctx: MutationCtx,
  scoutId: Id<"users">,
  input: UpsertArgs,
  held = false,
) {
    const event = await activeEventOf(ctx, scoutId);
    if (!event) throw new Error("No active event.");
    let args = input;

    if (await isPracticingAs(ctx, scoutId)) {
      const team = await ctx.db.get(args.teamId);
      if (!team || team.eventId !== event._id) {
        throw new Error("That team is not part of the active event.");
      }
      // A practice photo is not kept.
      if (args.photoId) await ctx.storage.delete(args.photoId);
      return await savePracticeAs(ctx, scoutId, {
        kind: "pit", teamNumber: team.number, matchNumber: null, payload: { ...args, photoId: null },
      });
    }

    const scoutingTeamNumber = await teamNumberOf(ctx, scoutId);
    if (scoutingTeamNumber === undefined) {
      throw new Error("Set your team number on your profile first.");
    }

    const team = await ctx.db.get(args.teamId);
    if (!team || team.eventId !== event._id) {
      throw new Error("That team is not part of the active event.");
    }

    const existing = await reportFor(ctx, event._id, args.teamId, scoutingTeamNumber);
    if (held && existing) args = keepStoredAnswers(args, existing);

    const fields = {
      scoring: args.scoring,
      climb: args.climb,
      drivetrain: args.drivetrain,
      underTrench: args.underTrench,
      overBump: args.overBump,
      robotNotes: args.robotNotes,
      otherNotes: args.otherNotes,
      // Keep the old photo when this save did not include a new one.
      photoId: args.photoId ?? existing?.photoId ?? null,
      // An old client that sends no hopper keeps whatever is stored.
      hopper: args.hopper ? cleanHopper(args.hopper) : existing?.hopper,
      spares: args.spares ? cleanSpares(args.spares) : existing?.spares,
      batteries: args.batteries ? cleanBatteries(args.batteries) : existing?.batteries,
      robotWeight: args.robotWeight === undefined
        ? existing?.robotWeight
        : cleanWeight(args.robotWeight),
      drivetrainGearing: args.drivetrainGearing === undefined
        ? existing?.drivetrainGearing
        : cleanGearing(args.drivetrainGearing),
      scoutId,
      scoutingTeamNumber,
      updatedAt: Date.now(),
    };

    // A blank report would leave the team looking visited with nothing in it.
    // The form refuses too; this covers stale and edited clients.
    if (pitIsBlank(fields)) {
      throw new Error("Nothing is filled in, so there is nothing to save.");
    }

    if (existing) {
      await ctx.db.patch(existing._id, fields);
      return existing._id;
    }
    return await ctx.db.insert("pitReports", {
      eventId: event._id,
      teamId: args.teamId,
      ...fields,
    });
}

export const upsert = mutation({
  args: upsertArgs,
  handler: async (ctx, args) => await writePitReport(ctx, await requireUser(ctx), args),
});
