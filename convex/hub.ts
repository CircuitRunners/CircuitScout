import { v } from "convex/values";
import { query } from "./_generated/server";

/**
 * The alliance scoring MORE auto fuel goes inactive first. When all six robots
 * have reports the winner is derivable, and the scout's entry becomes a
 * cross-check rather than the source of truth.
 */
export const reconcile = query({
  args: { matchId: v.id("matches") },
  handler: async (ctx, args) => {
    const match = await ctx.db.get(args.matchId);
    if (!match) return { derived: null, coverage: 0, entries: [], disagree: false };

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_match", (q) => q.eq("matchId", args.matchId))
      .collect();

    let red = 0;
    let blue = 0;
    let counted = 0;
    for (const report of reports) {
      const team = await ctx.db.get(report.teamId);
      if (!team) continue;
      if (match.redTeamNumbers.includes(team.number)) {
        red += report.auto.fuel;
        counted++;
      } else if (match.blueTeamNumbers.includes(team.number)) {
        blue += report.auto.fuel;
        counted++;
      }
    }

    // Only trust the derivation with full coverage; a partial alliance total
    // is not a comparison, it is a guess.
    const derived =
      counted === 6 ? (red === blue ? null : red > blue ? "red" : "blue") : null;

    const entries = reports
      .map((r) => r.autoWinner)
      .filter((w): w is "red" | "blue" => w !== null);

    const disagree =
      new Set(entries).size > 1 ||
      (derived !== null && entries.length > 0 && entries.some((e) => e !== derived));

    return { derived, coverage: counted, entries, disagree };
  },
});
