import { getAuthUserId } from "@convex-dev/auth/server";
import type { QueryCtx, MutationCtx } from "../_generated/server";
import type { Doc, Id } from "../_generated/dataModel";

export async function currentUserId(
  ctx: QueryCtx | MutationCtx,
): Promise<Id<"users"> | null> {
  return await getAuthUserId(ctx);
}

export async function requireUser(ctx: QueryCtx | MutationCtx): Promise<Id<"users">> {
  const userId = await getAuthUserId(ctx);
  if (userId === null) throw new Error("Not signed in.");
  return userId;
}

export async function currentProfile(
  ctx: QueryCtx | MutationCtx,
): Promise<Doc<"profiles"> | null> {
  const userId = await getAuthUserId(ctx);
  if (userId === null) return null;
  return await ctx.db
    .query("profiles")
    .withIndex("by_user", (q) => q.eq("userId", userId))
    .unique();
}

/** Full admin. Roles, events, and anything spanning more than one team. */
export async function requireAdmin(ctx: QueryCtx | MutationCtx): Promise<Doc<"profiles">> {
  const profile = await currentProfile(ctx);
  if (!profile) throw new Error("No profile for this user.");
  if (profile.role !== "admin") throw new Error("Admins only.");
  return profile;
}

/** Admin or team admin. The caller must still check scope with managesTeam. */
export async function requireTeamAdmin(
  ctx: QueryCtx | MutationCtx,
): Promise<Doc<"profiles">> {
  const profile = await currentProfile(ctx);
  if (!profile) throw new Error("No profile for this user.");
  if (profile.role !== "admin" && profile.role !== "teamAdmin") {
    throw new Error("Admins only.");
  }
  return profile;
}

/**
 * A full admin manages everyone. A team admin manages only their own FRC team,
 * and a team admin with no team number on their profile manages nobody — that
 * is the safe direction to fail.
 */
export function managesTeam(
  profile: Doc<"profiles"> | null,
  teamNumber: number | undefined,
): boolean {
  if (!profile) return false;
  if (profile.role === "admin") return true;
  if (profile.role !== "teamAdmin") return false;
  if (profile.teamNumber === undefined || teamNumber === undefined) return false;
  return profile.teamNumber === teamNumber;
}

/** The team whose data the caller is working with. */
export function effectiveTeamNumber(
  profile: Doc<"profiles"> | null,
): number | undefined {
  return profile?.teamNumber;
}

/**
 * The caller's team's active event. Every read in the app funnels through
 * here, so scoping it once scopes everything — there is no query that can
 * accidentally reach another team's competition.
 */
/** The FRC team the caller scouts for. */
export async function currentTeamNumber(
  ctx: QueryCtx | MutationCtx,
): Promise<number | undefined> {
  return effectiveTeamNumber(await currentProfile(ctx));
}

export async function activeEvent(
  ctx: QueryCtx | MutationCtx,
): Promise<Doc<"events"> | null> {
  const profile = await currentProfile(ctx);
  const teamNumber = effectiveTeamNumber(profile);
  if (teamNumber === undefined) return null;
  return await activeEventForTeam(ctx, teamNumber);
}

export async function activeEventForTeam(
  ctx: QueryCtx | MutationCtx,
  teamNumber: number,
): Promise<Doc<"events"> | null> {
  const settings = await ctx.db
    .query("teamSettings")
    .withIndex("by_team", (q) => q.eq("teamNumber", teamNumber))
    .unique();
  if (!settings || settings.activeEventId === null) return null;
  const event = await ctx.db.get(settings.activeEventId);
  // A deleted event reads as no event. The pointer is left alone so recovery
  // puts the team straight back where they were.
  if (!event || event.deletedAt) return null;
  return event;
}

export async function requireActiveEvent(
  ctx: QueryCtx | MutationCtx,
): Promise<Doc<"events">> {
  const event = await activeEvent(ctx);
  if (!event) throw new Error("No active event. An admin must set one up first.");
  return event;
}
