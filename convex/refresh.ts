import { action, internalAction } from "./_generated/server";
import { internal, api } from "./_generated/api";
import type { Id } from "./_generated/dataModel";

const message = (error: unknown) =>
  error instanceof Error ? error.message : String(error);

/**
 * Statbotics EPA, match13 xP and TBA scores together — they go stale at the
 * same rate and for the same reason, so refreshing them separately just means
 * one of them is always older than the others.
 */
export const now = action({
  args: {},
  handler: async (ctx): Promise<{
    epaTeams: number;
    xpTeams: number;
    matchesUpdated: number;
    problems: string[];
  }> => {
    await ctx.runQuery(internal.statbotics.requireAdminCheck, {});
    const event = await ctx.runQuery(internal.statbotics.activeEventKey, {});
    if (!event) throw new Error("No active event.");

    // Independent failures: one source having no data for a new event should
    // not stop the other two. What did fail is returned, not swallowed, so a
    // missing match13 key shows up instead of a quiet "Refreshed".
    let epaTeams = 0;
    let xpTeams = 0;
    let matchesUpdated = 0;
    const problems: string[] = [];

    try {
      const result = await ctx.runAction(api.statbotics.refresh, {});
      epaTeams = result.stored;
    } catch (error) {
      problems.push(message(error));
    }

    try {
      const result = await ctx.runAction(internal.match13.refreshEvent, {
        eventId: event.eventId as Id<"events">,
        eventKey: event.eventKey,
      });
      xpTeams = result.stored;
    } catch (error) {
      problems.push(message(error));
    }

    try {
      const result = await ctx.runAction(api.tba.refreshScores, {
        eventKey: event.eventKey,
      });
      matchesUpdated = result.updated;
    } catch (error) {
      problems.push(message(error));
    }

    if (epaTeams === 0 && xpTeams === 0 && matchesUpdated === 0 && problems.length > 0) {
      throw new Error(problems.join(" · "));
    }
    return { epaTeams, xpTeams, matchesUpdated, problems };
  },
});

/**
 * The cron. Iterates only events some team currently has active, so a
 * deployment sitting idle between competitions makes no outbound calls at all.
 */
export const scheduled = internalAction({
  args: {},
  handler: async (ctx): Promise<{ events: number }> => {
    const events = await ctx.runQuery(internal.statbotics.activeEventKeys, {});
    if (events.length === 0) return { events: 0 };

    for (const event of events) {
      try {
        await ctx.runAction(api.tba.refreshScores, { eventKey: event.eventKey });
      } catch {
        // A single event failing must not stop the rest.
      }
      try {
        await ctx.runAction(internal.match13.refreshEvent, {
          eventId: event.eventId as Id<"events">,
          eventKey: event.eventKey,
        });
      } catch {
        // Nor must match13 having nothing for it yet.
      }
    }
    const epa = await ctx.runAction(internal.statbotics.refreshAllScheduled, {});
    return { events: epa.events };
  },
});
