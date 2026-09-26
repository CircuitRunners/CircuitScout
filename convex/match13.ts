/// <reference types="node" />

import { v } from "convex/values";
import { internalAction, internalMutation, query } from "./_generated/server";
import { internal } from "./_generated/api";
import { activeEvent } from "./lib/guards";

const BASE = "https://actions.match13.com/v1";

/**
 * match13 xP for the caller's active event. The twin of statbotics.forEvent,
 * with the same shape of answer so the two can sit side by side.
 */
export const forEvent = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return { rows: [], fetchedAt: null };
    const rows = await ctx.db
      .query("teamXp")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    return {
      rows: rows.map((r) => ({
        teamNumber: r.teamNumber,
        xp: r.xp,
        autoXp: r.autoXp,
        teleopXp: r.teleopXp,
        endgameXp: r.endgameXp,
      })),
      fetchedAt: rows.reduce<number | null>(
        (max, r) => (max === null || r.fetchedAt > max ? r.fetchedAt : max), null),
    };
  },
});

export const store = internalMutation({
  args: {
    eventId: v.id("events"),
    rows: v.array(v.object({
      teamNumber: v.number(),
      xp: v.number(),
      autoXp: v.union(v.number(), v.null()),
      teleopXp: v.union(v.number(), v.null()),
      endgameXp: v.union(v.number(), v.null()),
    })),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("teamXp")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    const byTeam = new Map(existing.map((r) => [r.teamNumber, r]));
    const now = Date.now();

    for (const row of args.rows) {
      const fields = { ...row, fetchedAt: now };
      const found = byTeam.get(row.teamNumber);
      if (found) await ctx.db.patch(found._id, fields);
      else await ctx.db.insert("teamXp", { eventId: args.eventId, ...fields });
    }
    return { stored: args.rows.length };
  },
});

const num = (value: unknown): number | null =>
  typeof value === "number" && Number.isFinite(value) ? value : null;

async function fetchEvent(eventKey: string) {
  // The key stays on the deployment. match13 sends no CORS headers, so a
  // browser could not call it anyway — and every key on one account shares
  // one allowance, which is why this runs on a cron and never per page view.
  const key = process.env.MATCH13_API_KEY;
  if (!key) {
    throw new Error("MATCH13_API_KEY is not set on this deployment.");
  }

  // One request for the whole event, like Statbotics: one call per active
  // event every two hours is nowhere near the 1,000-an-hour allowance.
  const response = await fetch(
    `${BASE}/events/${encodeURIComponent(eventKey)}/teams`,
    { headers: { Authorization: `Bearer ${key}`, Accept: "application/json" } },
  );
  if (response.status === 404) {
    throw new Error(`match13 has no data for ${eventKey} yet.`);
  }
  if (response.status === 401 || response.status === 403) {
    throw new Error("match13 rejected the API key. Check MATCH13_API_KEY.");
  }
  if (response.status === 429) {
    const after = response.headers.get("Retry-After");
    throw new Error(
      `match13 rate limit reached${after ? `; try again in ${after}s` : ""}.`,
    );
  }
  if (!response.ok) {
    throw new Error(`match13 returned ${response.status} for ${eventKey}.`);
  }

  const body = (await response.json()) as { teams?: unknown } | null;
  const list: unknown[] = Array.isArray(body?.teams) ? body.teams : [];
  if (list.length === 0) {
    throw new Error(`match13 has no teams for ${eventKey} yet.`);
  }

  // xpEnd is the rating a team holds now, or left the event with.
  // xAuto + xTele + xEnd add up to it.
  const rows = list.flatMap((row) => {
    const r = (row ?? {}) as Record<string, unknown>;
    const teamNumber = num(r.teamNumber);
    const xp = num(r.xpEnd);
    if (teamNumber === null || xp === null) return [];
    return [{
      teamNumber,
      xp,
      autoXp: num(r.xAuto),
      teleopXp: num(r.xTele),
      endgameXp: num(r.xEnd),
    }];
  });

  // Rows arrived but nothing parsed: a changed field name, not an empty
  // event. Show the shape rather than storing nothing and calling it done.
  if (rows.length === 0) {
    throw new Error(
      `Got ${list.length} rows from match13 but found no xpEnd. First row: ${JSON.stringify(list[0]).slice(0, 400)}`,
    );
  }
  return rows;
}

/**
 * Pull one event. Internal only: the Admin button reaches it through
 * refresh.now, which checks the caller is an admin first, and the cron calls
 * it directly. Nothing outside can spend the account's allowance.
 */
export const refreshEvent = internalAction({
  args: { eventId: v.id("events"), eventKey: v.string() },
  handler: async (ctx, args): Promise<{ stored: number }> => {
    const rows = await fetchEvent(args.eventKey);
    return await ctx.runMutation(internal.match13.store, {
      eventId: args.eventId,
      rows,
    });
  },
});
