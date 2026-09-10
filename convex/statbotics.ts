/// <reference types="node" />

import { v } from "convex/values";
import { action, internalMutation, internalQuery, query } from "./_generated/server";
import { internal } from "./_generated/api";
import { activeEvent, requireTeamAdmin } from "./lib/guards";
import type { Id } from "./_generated/dataModel";

const BASE = "https://api-statbotics.popcornpenguins.com/v3";

/**
 * The v3 response has nested EPA objects and the exact shape has moved between
 * versions. Rather than pin one path and silently read zero, try the ones that
 * have existed and take the first number found.
 */
function pluck(row: unknown, paths: string[][]): number | null {
  for (const path of paths) {
    let node: unknown = row;
    for (const key of path) {
      if (node === null || typeof node !== "object") { node = undefined; break; }
      node = (node as Record<string, unknown>)[key];
    }
    if (typeof node === "number" && Number.isFinite(node)) return node;
  }
  return null;
}

const TOTAL_PATHS = [
  ["epa", "total_points", "mean"],
  ["epa", "breakdown", "total_points"],
  ["epa_end"],
  ["epa", "mean"],
];
const AUTO_PATHS = [
  ["epa", "breakdown", "auto_points"],
  ["epa", "breakdown", "auto_points", "mean"],
  ["auto_epa_end"],
];
const TELEOP_PATHS = [
  ["epa", "breakdown", "teleop_points"],
  ["epa", "breakdown", "teleop_points", "mean"],
  ["teleop_epa_end"],
];
const ENDGAME_PATHS = [
  ["epa", "breakdown", "endgame_points"],
  ["epa", "breakdown", "endgame_points", "mean"],
  ["endgame_epa_end"],
];

export const forEvent = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return { rows: [], fetchedAt: null, sample: null };
    const rows = await ctx.db
      .query("teamEpa")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    return {
      rows: rows.map((r) => ({
        teamNumber: r.teamNumber,
        epa: r.epa,
        autoEpa: r.autoEpa,
        teleopEpa: r.teleopEpa,
        endgameEpa: r.endgameEpa,
      })),
      fetchedAt: rows.reduce<number | null>(
        (max, r) => (max === null || r.fetchedAt > max ? r.fetchedAt : max), null),
      sample: rows.find((r) => r.sample)?.sample ?? null,
    };
  },
});

export const activeEventKey = internalQuery({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    return event ? { eventId: event._id, eventKey: event.tbaEventKey } : null;
  },
});

export const store = internalMutation({
  args: {
    eventId: v.id("events"),
    rows: v.array(v.object({
      teamNumber: v.number(),
      epa: v.number(),
      autoEpa: v.union(v.number(), v.null()),
      teleopEpa: v.union(v.number(), v.null()),
      endgameEpa: v.union(v.number(), v.null()),
    })),
    sample: v.string(),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("teamEpa")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    const byTeam = new Map(existing.map((r) => [r.teamNumber, r]));
    const now = Date.now();

    let first = true;
    for (const row of args.rows) {
      const fields = { ...row, fetchedAt: now, sample: first ? args.sample : undefined };
      first = false;
      const found = byTeam.get(row.teamNumber);
      if (found) await ctx.db.patch(found._id, fields);
      else await ctx.db.insert("teamEpa", { eventId: args.eventId, ...fields });
    }
    return { stored: args.rows.length };
  },
});

async function fetchEvent(eventKey: string) {
  // One request for the whole event rather than one per team — 40-odd calls
  // per refresh would be rude to a free API and slow besides.
  const response = await fetch(
    `${BASE}/team_events?event=${encodeURIComponent(eventKey)}&limit=200`,
    { headers: { Accept: "application/json" } },
  );
  if (!response.ok) {
    throw new Error(`Statbotics returned ${response.status} for ${eventKey}.`);
  }
  const body = (await response.json()) as unknown;
  const list = Array.isArray(body)
    ? body
    : Array.isArray((body as { results?: unknown[] } | null)?.results)
      ? ((body as { results: unknown[] }).results)
      : Array.isArray((body as { data?: unknown[] } | null)?.data)
        ? ((body as { data: unknown[] }).data)
        : [];
  if (list.length === 0) {
    throw new Error(`Statbotics has no data for ${eventKey} yet.`);
  }

  const rows = list.flatMap((row) => {
    const teamNumber = pluck(row, [["team"], ["team_number"]]);
    const epa = pluck(row, TOTAL_PATHS);
    if (teamNumber === null || epa === null) return [];
    return [{
      teamNumber,
      epa,
      autoEpa: pluck(row, AUTO_PATHS),
      teleopEpa: pluck(row, TELEOP_PATHS),
      endgameEpa: pluck(row, ENDGAME_PATHS),
    }];
  });

  // Rows arrived but nothing parsed: that is a field-path problem, not an
  // empty event, and the difference matters. Show the shape rather than
  // silently storing nothing and calling it a success.
  if (rows.length === 0) {
    throw new Error(
      `Got ${list.length} rows from ${BASE} but found no EPA field. First row: ${JSON.stringify(list[0]).slice(0, 400)}`,
    );
  }

  return { rows, sample: JSON.stringify(list[0]) };
}

/** Manual refresh. Statbotics updates as matches are played. */
export const refresh = action({
  args: {},
  handler: async (ctx): Promise<{ stored: number }> => {
    await ctx.runQuery(internal.statbotics.requireAdminCheck, {});
    const event = await ctx.runQuery(internal.statbotics.activeEventKey, {});
    if (!event) throw new Error("No active event.");

    const { rows, sample } = await fetchEvent(event.eventKey);
    return await ctx.runMutation(internal.statbotics.store, {
      eventId: event.eventId as Id<"events">,
      rows,
      sample,
    });
  },
});

export const requireAdminCheck = internalQuery({
  args: {},
  handler: async (ctx) => {
    await requireTeamAdmin(ctx);
    return true;
  },
});

/** Called by the cron for every event a team currently has active. */
export const refreshAll = action({
  args: {},
  handler: async (ctx): Promise<{ events: number }> => {
    const events = await ctx.runQuery(internal.statbotics.activeEventKeys, {});
    let done = 0;
    for (const event of events) {
      try {
        const { rows, sample } = await fetchEvent(event.eventKey);
        await ctx.runMutation(internal.statbotics.store, {
          eventId: event.eventId as Id<"events">,
          rows,
          sample,
        });
        done += 1;
      } catch {
        // One event without Statbotics data must not stop the others.
      }
    }
    return { events: done };
  },
});

export const activeEventKeys = internalQuery({
  args: {},
  handler: async (ctx) => {
    const settings = await ctx.db.query("teamSettings").collect();
    const ids = [...new Set(settings.flatMap((s) => (s.activeEventId ? [s.activeEventId] : [])))];
    const out = [];
    for (const id of ids) {
      const event = await ctx.db.get(id);
      if (event && !event.deletedAt) {
        out.push({ eventId: event._id, eventKey: event.tbaEventKey });
      }
    }
    return out;
  },
});
