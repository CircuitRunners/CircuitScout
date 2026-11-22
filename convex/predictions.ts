/// <reference types="node" />

import { v } from "convex/values";
import { internalAction, internalMutation, query } from "./_generated/server";
import { internal } from "./_generated/api";
import { requireUser } from "./lib/guards";
import { STATBOTICS_BASE } from "./statbotics";
import { MATCH13_BASE } from "./match13";

/**
 * Match predictions straight from Statbotics (EPA model) and match13 (xP
 * model). Summing EPA or xP per alliance ignores everything those models know
 * about how robots combine; their own predictions do not.
 */

type Row = { matchKey: string; redScore: number; blueScore: number; redWinProb: number };
const source = v.union(v.literal("statbotics"), v.literal("match13"));

const num = (value: unknown): number | null =>
  typeof value === "number" && Number.isFinite(value) ? value : null;

/** Both sources' predictions for one match; null where a source has none. */
export const forMatch = query({
  args: { matchKey: v.string() },
  handler: async (ctx, args) => {
    await requireUser(ctx);
    const rows = await ctx.db
      .query("matchPredictions")
      .withIndex("by_match", (q) => q.eq("matchKey", args.matchKey))
      .collect();
    const pick = (s: "statbotics" | "match13") => {
      const row = rows.find((r) => r.source === s);
      return row
        ? { redScore: row.redScore, blueScore: row.blueScore, redWinProb: row.redWinProb, fetchedAt: row.fetchedAt }
        : null;
    };
    return { statbotics: pick("statbotics"), match13: pick("match13") };
  },
});

/** Replaces one source's predictions for one event. */
export const store = internalMutation({
  args: {
    eventId: v.id("events"),
    source,
    rows: v.array(v.object({
      matchKey: v.string(),
      redScore: v.number(),
      blueScore: v.number(),
      redWinProb: v.number(),
    })),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("matchPredictions")
      .withIndex("by_event_source", (q) => q.eq("eventId", args.eventId).eq("source", args.source))
      .collect();
    const byKey = new Map(existing.map((r) => [r.matchKey, r]));
    const now = Date.now();
    for (const row of args.rows) {
      const found = byKey.get(row.matchKey);
      if (found) {
        await ctx.db.patch(found._id, { ...row, fetchedAt: now });
        byKey.delete(row.matchKey);
      } else {
        await ctx.db.insert("matchPredictions", {
          eventId: args.eventId, source: args.source, ...row, fetchedAt: now,
        });
      }
    }
    // A match the source no longer lists (a replayed or removed match).
    for (const stale of byKey.values()) await ctx.db.delete(stale._id);
    return { stored: args.rows.length };
  },
});

async function fetchStatbotics(eventKey: string): Promise<Row[]> {
  const response = await fetch(
    `${STATBOTICS_BASE}/matches?event=${encodeURIComponent(eventKey)}&limit=1000`,
    { headers: { Accept: "application/json" } },
  );
  if (!response.ok) {
    throw new Error(`Statbotics returned ${response.status} for ${eventKey} matches.`);
  }
  const body = (await response.json()) as unknown;
  const list: unknown[] = Array.isArray(body)
    ? body
    : Array.isArray((body as { results?: unknown[] } | null)?.results)
      ? (body as { results: unknown[] }).results
      : [];
  const rows = list.flatMap((item): Row[] => {
    const m = (item ?? {}) as { key?: unknown; pred?: Record<string, unknown> | null };
    const pred = m.pred ?? {};
    const redScore = num(pred.red_score);
    const blueScore = num(pred.blue_score);
    const redWinProb = num(pred.red_win_prob);
    if (typeof m.key !== "string" || redScore === null || blueScore === null || redWinProb === null) {
      return [];
    }
    return [{ matchKey: m.key, redScore, blueScore, redWinProb }];
  });
  if (list.length > 0 && rows.length === 0) {
    throw new Error(
      `Got ${list.length} matches from Statbotics but no predictions. First: ${JSON.stringify(list[0]).slice(0, 300)}`,
    );
  }
  return rows;
}

async function fetchMatch13(eventKey: string): Promise<Row[]> {
  const key = process.env.MATCH13_API_KEY;
  if (!key) throw new Error("MATCH13_API_KEY is not set on this deployment.");
  const response = await fetch(
    `${MATCH13_BASE}/events/${encodeURIComponent(eventKey)}/matches`,
    { headers: { Authorization: `Bearer ${key}`, Accept: "application/json" } },
  );
  if (response.status === 404) return [];
  if (response.status === 401 || response.status === 403) {
    throw new Error("match13 rejected the API key. Check MATCH13_API_KEY.");
  }
  if (response.status === 429) {
    const after = response.headers.get("Retry-After");
    throw new Error(`match13 rate limit reached${after ? `; try again in ${after}s` : ""}.`);
  }
  if (!response.ok) {
    throw new Error(`match13 returned ${response.status} for ${eventKey} matches.`);
  }
  const body = (await response.json()) as { matches?: unknown } | null;
  const list: unknown[] = Array.isArray(body?.matches) ? body.matches : [];
  const rows = list.flatMap((item): Row[] => {
    const m = (item ?? {}) as { key?: unknown; pred?: Record<string, unknown> | null };
    const pred = m.pred ?? {};
    const redScore = num(pred.redScore);
    const blueScore = num(pred.blueScore);
    // winProb is the chance red wins.
    const redWinProb = num(pred.winProb);
    if (typeof m.key !== "string" || redScore === null || blueScore === null || redWinProb === null) {
      return [];
    }
    return [{ matchKey: m.key, redScore, blueScore, redWinProb }];
  });
  if (list.length > 0 && rows.length === 0) {
    throw new Error(
      `Got ${list.length} matches from match13 but no predictions. First: ${JSON.stringify(list[0]).slice(0, 300)}`,
    );
  }
  return rows;
}

/** Internal only: reached through refresh.now (admin-checked) and the cron. */
export const refreshStatbotics = internalAction({
  args: { eventId: v.id("events"), eventKey: v.string() },
  handler: async (ctx, args): Promise<{ stored: number }> => {
    const rows = await fetchStatbotics(args.eventKey);
    return await ctx.runMutation(internal.predictions.store, {
      eventId: args.eventId, source: "statbotics", rows,
    });
  },
});

export const refreshMatch13 = internalAction({
  args: { eventId: v.id("events"), eventKey: v.string() },
  handler: async (ctx, args): Promise<{ stored: number }> => {
    const rows = await fetchMatch13(args.eventKey);
    return await ctx.runMutation(internal.predictions.store, {
      eventId: args.eventId, source: "match13", rows,
    });
  },
});
