import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import type { QueryCtx } from "./_generated/server";
import { currentProfile, requireAdmin, requireTeamAdmin } from "./lib/guards";

type StatSite = "statbotics" | "match13";

const site = v.union(v.literal("statbotics"), v.literal("match13"));

/** Statbotics until a full admin says otherwise. */
async function siteWideDefault(ctx: QueryCtx): Promise<StatSite> {
  const row = await ctx.db.query("siteSettings").first();
  return row?.defaultStatSite ?? "statbotics";
}

/**
 * Which rating the caller's team sees. `team` is null when the team follows
 * the site-wide default, which is what "Default" in the team admin's toggle
 * means — so changing the default moves every team that never chose.
 */
export const mine = query({
  args: {},
  handler: async (ctx) => {
    const profile = await currentProfile(ctx);
    const siteWide = await siteWideDefault(ctx);
    const teamNumber = profile?.teamNumber;

    let team: StatSite | null = null;
    if (teamNumber !== undefined) {
      const settings = await ctx.db
        .query("teamSettings")
        .withIndex("by_team", (q) => q.eq("teamNumber", teamNumber))
        .unique();
      team = settings?.statSite ?? null;
    }
    return {
      siteWide,
      team,
      effective: team ?? siteWide,
      teamNumber: teamNumber ?? null,
    };
  },
});

/** Full admins only: the site every team on Default follows. */
export const setDefault = mutation({
  args: { site },
  handler: async (ctx, args) => {
    const me = await requireAdmin(ctx);
    const existing = await ctx.db.query("siteSettings").first();
    const fields = { defaultStatSite: args.site, updatedAt: Date.now(), updatedBy: me.userId };
    if (existing) await ctx.db.patch(existing._id, fields);
    else await ctx.db.insert("siteSettings", fields);
  },
});

/**
 * A team admin's choice for their own team. Always the caller's own team —
 * there is no team argument to get wrong. "default" clears the choice.
 */
export const setForTeam = mutation({
  args: { site: v.union(v.literal("default"), site) },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const teamNumber = me.teamNumber;
    if (teamNumber === undefined) {
      throw new Error("Your profile has no team number.");
    }
    const statSite = args.site === "default" ? undefined : args.site;

    const existing = await ctx.db
      .query("teamSettings")
      .withIndex("by_team", (q) => q.eq("teamNumber", teamNumber))
      .unique();
    if (existing) {
      // Patching a field to undefined removes it, which is exactly "Default".
      await ctx.db.patch(existing._id, {
        statSite, updatedAt: Date.now(), updatedBy: me.userId,
      });
      return;
    }
    // A team that has never activated an event still gets a row, with no
    // event, the same state "Stand down" leaves behind.
    await ctx.db.insert("teamSettings", {
      teamNumber,
      activeEventId: null,
      statSite,
      updatedAt: Date.now(),
      updatedBy: me.userId,
    });
  },
});
