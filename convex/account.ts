import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { requireAdmin, requireUser } from "./lib/guards";
import type { Id } from "./_generated/dataModel";
import type { MutationCtx } from "./_generated/server";

/**
 * Removes a user and everything that identifies them, leaving their scouting
 * data in place. Reports keep pointing at a user id that no longer resolves,
 * and every surface already renders that as "Unknown scout" — deleting the
 * observations would quietly change every average the person contributed to.
 *
 * Convex Auth exposes no deletion API, so the auth rows are cleared directly.
 * Sessions and refresh tokens go first: a live session outliving the account
 * would be a signed-in ghost.
 */
async function purgeUser(ctx: MutationCtx, userId: Id<"users">) {
  const sessions = await ctx.db
    .query("authSessions")
    .filter((q) => q.eq(q.field("userId"), userId))
    .collect();
  for (const session of sessions) {
    const tokens = await ctx.db
      .query("authRefreshTokens")
      .filter((q) => q.eq(q.field("sessionId"), session._id))
      .collect();
    for (const token of tokens) await ctx.db.delete(token._id);
    await ctx.db.delete(session._id);
  }

  const accounts = await ctx.db
    .query("authAccounts")
    .filter((q) => q.eq(q.field("userId"), userId))
    .collect();
  for (const account of accounts) await ctx.db.delete(account._id);

  const profile = await ctx.db
    .query("profiles")
    .withIndex("by_user", (q) => q.eq("userId", userId))
    .unique();
  if (profile) {
    const joins = await ctx.db
      .query("teamJoins")
      .withIndex("by_profile", (q) => q.eq("profileId", profile._id))
      .collect();
    for (const join of joins) await ctx.db.delete(join._id);
    await ctx.db.delete(profile._id);
  }

  await ctx.db.delete(userId);
}

/**
 * The caller's own account. The client verifies the password by signing in
 * again immediately before calling this — the same check the auth system
 * already trusts, and it avoids a second password path to get wrong.
 */
export const deleteSelf = mutation({
  args: {},
  handler: async (ctx) => {
    const userId = await requireUser(ctx);

    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .unique();

    // Losing the last admin locks everyone out of role management.
    if (profile?.role === "admin") {
      const admins = (await ctx.db.query("profiles").collect())
        .filter((p) => p.role === "admin");
      if (admins.length <= 1) {
        throw new Error(
          "You are the only admin. Promote someone else before deleting your account.",
        );
      }
    }

    await purgeUser(ctx, userId);
  },
});

/** The signed-in user's email, needed to re-verify a password. */
export const myEmail = query({
  args: {},
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const user = await ctx.db.get(userId);
    return user?.email ?? null;
  },
});

/** Full admins only — deleting someone else's account is not a team matter. */
export const deleteScout = mutation({
  args: { profileId: v.id("profiles") },
  handler: async (ctx, args) => {
    const me = await requireAdmin(ctx);

    const target = await ctx.db.get(args.profileId);
    if (!target) throw new Error("That scout no longer exists.");
    if (target.userId === me.userId) {
      throw new Error("Delete your own account from your profile page.");
    }
    if (target.role === "admin") {
      throw new Error("Demote them first — an admin cannot be deleted outright.");
    }

    await purgeUser(ctx, target.userId);
    return { displayName: target.displayName };
  },
});
