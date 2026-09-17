import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { requireAdmin, requireUser } from "./lib/guards";
import { validate } from "./profiles";
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

/**
 * Renames a password sign-in. The address lives in two rows — the authAccounts
 * row it is looked up by, and the users row every other surface reads — so
 * both move together or the person is locked out. Convex Auth has no API for
 * this, so the rows are patched directly, as purgeUser above already does.
 *
 * Stored as typed rather than lowercased, because sign-in compares the address
 * exactly as it was entered at sign-up. The clash check is case-insensitive
 * regardless: two accounts differing only in case would be a trap.
 */
async function setEmail(ctx: MutationCtx, userId: Id<"users">, raw: string) {
  const email = raw.trim();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new Error("That does not look like an email address.");
  }

  const accounts = await ctx.db
    .query("authAccounts")
    .filter((q) => q.eq(q.field("provider"), "password"))
    .collect();

  const taken = accounts.find(
    (account) =>
      account.userId !== userId
      && account.providerAccountId.toLowerCase() === email.toLowerCase(),
  );
  if (taken) throw new Error("Another account already uses that email.");

  const mine = accounts.filter((account) => account.userId === userId);
  if (mine.length === 0) throw new Error("That account has no password sign-in.");

  for (const account of mine) {
    await ctx.db.patch(account._id, { providerAccountId: email });
  }
  await ctx.db.patch(userId, { email });
  return email;
}

/**
 * The caller's own email. The client signs in again with the current password
 * immediately before calling this — the same check deleteSelf trusts, and it
 * avoids a second password path to get wrong.
 */
export const changeEmail = mutation({
  args: { email: v.string() },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    return { email: await setEmail(ctx, userId, args.email) };
  },
});

/** One scout's sign-in email, for the admin edit panel. Full admins only. */
export const scoutEmail = query({
  args: { profileId: v.id("profiles") },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const target = await ctx.db.get(args.profileId);
    if (!target) return null;
    const user = await ctx.db.get(target.userId);
    return user?.email ?? null;
  },
});

/**
 * Name, team and email for someone else. Password is not here — that has to go
 * through the admin-password-reset provider, which is the only place the
 * credential helpers can be called.
 *
 * A team number set by an admin applies immediately rather than raising a join
 * request: the person who would approve it is the one typing.
 */
export const adminUpdateScout = mutation({
  args: {
    profileId: v.id("profiles"),
    email: v.optional(v.string()),
    firstName: v.string(),
    lastInitial: v.string(),
    teamNumber: v.number(),
  },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);

    const target = await ctx.db.get(args.profileId);
    if (!target) throw new Error("That scout no longer exists.");

    const fields = validate(args);
    await ctx.db.patch(target._id, fields);

    // Their team was just decided by hand, so a request to join one is moot.
    const joins = await ctx.db
      .query("teamJoins")
      .withIndex("by_profile", (q) => q.eq("profileId", target._id))
      .collect();
    for (const join of joins) {
      if (join.status === "pending") await ctx.db.delete(join._id);
    }

    if (args.email !== undefined && args.email.trim() !== "") {
      await setEmail(ctx, target.userId, args.email);
    }

    return { displayName: fields.displayName };
  },
});
