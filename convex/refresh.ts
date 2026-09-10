import { action, internalAction } from "./_generated/server";
import { internal, api } from "./_generated/api";

/**
 * Statbotics EPA and TBA scores together — they go stale at the same rate and
 * for the same reason, so refreshing them separately just means one of them is
 * always older than the other.
 */
export const now = action({
  args: {},
  handler: async (ctx): Promise<{ epaTeams: number; matchesUpdated: number }> => {
    await ctx.runQuery(internal.statbotics.requireAdminCheck, {});
    const event = await ctx.runQuery(internal.statbotics.activeEventKey, {});
    if (!event) throw new Error("No active event.");

    // Independent failures: Statbotics having no data for a new event should
    // not stop scores coming through, and vice versa.
    let epaTeams = 0;
    let matchesUpdated = 0;
    const problems: string[] = [];

    try {
      const result = await ctx.runAction(api.statbotics.refresh, {});
      epaTeams = result.stored;
    } catch (error) {
      problems.push(error instanceof Error ? error.message : String(error));
    }

    try {
      const result = await ctx.runAction(api.tba.refreshScores, {
        eventKey: event.eventKey,
      });
      matchesUpdated = result.updated;
    } catch (error) {
      problems.push(error instanceof Error ? error.message : String(error));
    }

    if (epaTeams === 0 && matchesUpdated === 0 && problems.length > 0) {
      throw new Error(problems.join(" · "));
    }
    return { epaTeams, matchesUpdated };
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
    }
    const epa = await ctx.runAction(api.statbotics.refreshAll, {});
    return { events: epa.events };
  },
});
