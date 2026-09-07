import { v } from "convex/values";
import {
  internalMutation, internalQuery, mutation, query,
} from "./_generated/server";
import type { MutationCtx } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import {
  currentProfile, managesTeam, requireAdmin, requireTeamAdmin, requireUser,
} from "./lib/guards";

/**
 * Admin bootstrap: the first profile created in an empty deployment becomes an
 * admin. Everyone after is a scout until promoted.
 */
export const me = query({
  args: {},
  handler: async (ctx) => await currentProfile(ctx),
});

export const list = query({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
    const all = await ctx.db.query("profiles").collect();
    const scoped = me.role === "admin"
      ? all
      : all.filter((p) => p.teamNumber === me.teamNumber);

    return await Promise.all(scoped.map(async (profile) => {
      const pending = (
        await ctx.db
          .query("teamJoins")
          .withIndex("by_profile", (q) => q.eq("profileId", profile._id))
          .collect()
      ).find((row) => row.status === "pending");
      return {
        ...profile,
        pendingJoin: pending
          ? {
              joinId: pending._id,
              teamNumber: pending.teamNumber,
              previousTeamNumber: pending.previousTeamNumber,
              at: pending.at,
            }
          : null,
      };
    }));
  },
});

/**
 * One pending row per profile. A scout who mistypes their number twice should
 * leave one thing to decide, not a queue.
 */
async function recordJoin(
  ctx: MutationCtx,
  profileId: Id<"profiles">,
  userId: Id<"users">,
  displayName: string,
  teamNumber: number,
  previousTeamNumber: number | null,
) {
  const prior = await ctx.db
    .query("teamJoins")
    .withIndex("by_profile", (q) => q.eq("profileId", profileId))
    .collect();
  for (const row of prior) {
    if (row.status === "pending") await ctx.db.delete(row._id);
  }
  await ctx.db.insert("teamJoins", {
    profileId, userId, displayName, teamNumber, previousTeamNumber,
    at: Date.now(),
    status: "pending",
  });

  // The team being left is told too — they lose a scout without being asked.
  if (previousTeamNumber !== null && previousTeamNumber !== teamNumber) {
    await ctx.db.insert("teamDepartures", {
      profileId,
      displayName,
      fromTeamNumber: previousTeamNumber,
      toTeamNumber: teamNumber,
      at: Date.now(),
      dismissed: false,
    });
  }
}

function validate(args: {
  firstName: string;
  lastInitial: string;
  teamNumber: number;
}) {
  const firstName = args.firstName.trim();
  const lastInitial = args.lastInitial.trim().toUpperCase().slice(0, 1);

  if (firstName.length === 0) throw new Error("First name is required.");
  if (firstName.length > 30) throw new Error("First name is too long.");
  if (!/^[A-Z]$/.test(lastInitial)) {
    throw new Error("Last initial must be a single letter.");
  }
  if (!Number.isInteger(args.teamNumber) || args.teamNumber <= 0) {
    throw new Error("Team number must be a whole number.");
  }

  return {
    firstName,
    lastInitial,
    teamNumber: args.teamNumber,
    // One display name, derived once, so every surface agrees.
    displayName: `${firstName} ${lastInitial}. (${args.teamNumber})`,
  };
}

/**
 * Creates or completes the caller's profile. The first profile in an empty
 * deployment becomes an admin; everyone after is a scout until promoted.
 */
/**
 * Internal on purpose: the only caller is tba.claimProfile, which has already
 * confirmed the team exists. A public mutation here would be a way around the
 * check.
 */
export const ensureInternal = internalMutation({
  args: {
    userId: v.id("users"),
    firstName: v.string(),
    lastInitial: v.string(),
    teamNumber: v.number(),
  },
  handler: async (ctx, args) => {
    const userId = args.userId;
    const fields = validate(args);

    const existing = await ctx.db
      .query("profiles")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .unique();

    if (existing) {
      const changedTeam = existing.teamNumber !== fields.teamNumber;
      await ctx.db.patch(existing._id, fields);
      if (changedTeam) {
        await recordJoin(ctx, existing._id, userId, fields.displayName,
          fields.teamNumber, existing.teamNumber ?? null);
      }
      return existing._id;
    }

    const anyProfile = await ctx.db.query("profiles").first();
    const profileId = await ctx.db.insert("profiles", {
      userId,
      ...fields,
      role: anyProfile === null ? "admin" : "scout",
      weightTier: "normal",
      createdAt: Date.now(),
    });
    // The very first account has nobody to approve it, so it is not pending.
    if (anyProfile !== null) {
      await recordJoin(ctx, profileId, userId, fields.displayName, fields.teamNumber, null);
    }
    return profileId;
  },
});

/** Roles are a full-admin decision. A team admin cannot mint another. */
export const setRole = mutation({
  args: {
    profileId: v.id("profiles"),
    role: v.union(v.literal("admin"), v.literal("teamAdmin"), v.literal("scout")),
  },
  handler: async (ctx, args) => {
    const me = await requireAdmin(ctx);

    const target = await ctx.db.get(args.profileId);
    if (!target) throw new Error("That profile no longer exists.");

    // Removing the last full admin locks everyone out of role management, and
    // the only way back is the CLI.
    if (target.role === "admin" && args.role !== "admin") {
      const admins = (await ctx.db.query("profiles").collect())
        .filter((p) => p.role === "admin");
      if (admins.length <= 1) {
        throw new Error("That is the only admin. Promote someone else first.");
      }
    }
    void me;
    await ctx.db.patch(args.profileId, { role: args.role });
  },
});

/** Trust level is a team admin's call for their own scouts. */
export const setWeightTier = mutation({
  args: {
    profileId: v.id("profiles"),
    weightTier: v.union(v.literal("lead"), v.literal("trusted"), v.literal("normal")),
  },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const target = await ctx.db.get(args.profileId);
    if (!target) throw new Error("That profile no longer exists.");
    if (!managesTeam(me, target.teamNumber)) {
      throw new Error("That scout is not on your team.");
    }
    await ctx.db.patch(args.profileId, { weightTier: args.weightTier });
  },
});

/**
 * Resolves the calling admin's user id. Actions cannot touch the database, so
 * the TBA import calls through here to authorise before fetching.
 */
export const adminUserId = internalQuery({
  args: {},
  handler: async (ctx) => {
    // Importing an event is a team admin's job now, so this no longer demands
    // a full admin. Named as it was to avoid churning tba.ts.
    const profile = await requireTeamAdmin(ctx);
    return profile.userId;
  },
});


/**
 * Accept the scout onto this team, or send them back where they came from.
 * Sending back with no previous team clears their team number, which drops
 * them at the profile screen to enter one again — no account is destroyed.
 */
export const resolveJoin = mutation({
  args: {
    joinId: v.id("teamJoins"),
    action: v.union(v.literal("accept"), v.literal("sendBack")),
  },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const join = await ctx.db.get(args.joinId);
    if (!join) throw new Error("That request no longer exists.");
    if (!managesTeam(me, join.teamNumber)) {
      throw new Error("That request is for another team.");
    }

    if (args.action === "accept") {
      await ctx.db.patch(args.joinId, { status: "accepted" });
      return { accepted: true };
    }

    await ctx.db.patch(join.profileId, {
      teamNumber: join.previousTeamNumber ?? undefined,
    });
    await ctx.db.patch(args.joinId, { status: "rejected" });
    return { accepted: false, sentBackTo: join.previousTeamNumber };
  },
});

/** Scouts who left this team and have not been acknowledged. */
export const departures = query({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
    const rows = (await ctx.db.query("teamDepartures").collect())
      .filter((row) => !row.dismissed);
    return rows
      .filter((row) => managesTeam(me, row.fromTeamNumber))
      .sort((a, b) => b.at - a.at);
  },
});

export const dismissDeparture = mutation({
  args: { departureId: v.id("teamDepartures") },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const row = await ctx.db.get(args.departureId);
    if (!row) return;
    if (!managesTeam(me, row.fromTeamNumber)) {
      throw new Error("That notice is for another team.");
    }
    await ctx.db.patch(args.departureId, { dismissed: true });
  },
});

/** Used by the verifying action to find the caller. */
export const myUserId = internalQuery({
  args: {},
  handler: async (ctx) => await requireUser(ctx),
});
