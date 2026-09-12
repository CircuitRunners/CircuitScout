import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import type { MutationCtx } from "./_generated/server";
import {
  activeEvent, currentProfile, managesTeam, requireTeamAdmin, requireUser,
} from "./lib/guards";
import type { Doc, Id } from "./_generated/dataModel";

export const listMine = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    const userId = await requireUser(ctx);

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", userId))
      .collect();

    return await Promise.all(
      lists.map(async (list) => {
        const entries = await ctx.db
          .query("pickListEntries")
          .withIndex("by_list", (q) => q.eq("pickListId", list._id))
          .collect();
        return {
          ...list,
          ranked: entries.filter((e) => e.tier !== "uncategorized").length,
          total: entries.length,
        };
      }),
    );
  },
});

/** The primary list belongs to an FRC team, not to the event. */
export const primary = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    const profile = await currentProfile(ctx);
    const myTeamNumber = profile?.teamNumber;
    if (myTeamNumber === undefined) return null;

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", null))
      .collect();
    const list = lists.find((l) => l.teamNumber === myTeamNumber) ?? null;
    if (!list) return null;

    const entries = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", list._id))
      .collect();
    return {
      ...list,
      ranked: entries.filter((e) => e.tier !== "uncategorized").length,
      total: entries.length,
      canEdit: managesTeam(profile, myTeamNumber),
    };
  },
});

/** Everyone's submitted lists, for the merge and for seeing who has finished. */
export const submitted = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    const me = await requireTeamAdmin(ctx);

    const all = await ctx.db
      .query("pickLists")
      .withIndex("by_event_submitted", (q) =>
        q.eq("eventId", event._id).eq("isSubmitted", true))
      .collect();

    const profiles = await ctx.db.query("profiles").collect();
    const byUser = new Map(profiles.map((p) => [p.userId, p]));

    return all.flatMap((list) => {
      if (list.ownerId === null) return [];
      const profile = byUser.get(list.ownerId);
      if (!managesTeam(me, profile?.teamNumber)) return [];
      return [{
        ...list,
        ownerName: profile?.displayName ?? "Unknown scout",
        weightTier: profile?.weightTier ?? "normal",
      }];
    });
  },
});

async function assertCanEdit(
  ctx: MutationCtx,
  listId: Id<"pickLists">,
  userId: Id<"users">,
  isAdmin: boolean,
): Promise<Doc<"pickLists">> {
  const list = await ctx.db.get(listId);
  if (!list) throw new Error("That list no longer exists.");
  // The primary list is the team's, so only an admin edits it. Personal lists
  // are the scout's own working notes and nobody else touches them.
  if (list.ownerId === null) {
    if (!isAdmin) throw new Error("Only your team's admin can edit the primary list.");
  } else if (list.ownerId !== userId) {
    throw new Error("That is someone else's list.");
  }
  return list;
}

export const get = query({
  args: { listId: v.id("pickLists") },
  handler: async (ctx, args) => {
    const list = await ctx.db.get(args.listId);
    if (!list) return null;
    const profile = await currentProfile(ctx);
    const userId = profile?.userId ?? null;

    const canEdit =
      list.ownerId === null
        ? profile?.role === "admin"
        : list.ownerId === userId;

    return { ...list, canEdit };
  },
});

export const create = mutation({
  args: { name: v.string() },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");
    const name = args.name.trim();
    if (name === "") throw new Error("Give the list a name.");

    const profile = await currentProfile(ctx);
    const listId = await ctx.db.insert("pickLists", {
      eventId: event._id,
      ownerId: userId,
      teamNumber: profile?.teamNumber,
      name,
      isPrimary: false,
      isSubmitted: false,
      createdAt: Date.now(),
    });

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    teams.sort((a, b) => a.number - b.number);

    // Float order, so a later drag inserts between neighbours by halving the
    // gap instead of renumbering the column.
    for (let i = 0; i < teams.length; i++) {
      const team = teams[i];
      if (!team) continue;
      await ctx.db.insert("pickListEntries", {
        pickListId: listId,
        teamId: team._id,
        tier: "uncategorized",
        order: (i + 1) * 1000,
      });
    }

    return listId;
  },
});

/** The primary list starts blank — the merge fills it. */
export const ensurePrimary = mutation({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");
    if (me.teamNumber === undefined) {
      throw new Error("Set your team number on your profile first.");
    }

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", null))
      .collect();
    const existing = lists.find((l) => l.teamNumber === me.teamNumber);
    if (existing) {
      await seedPrimaryEntries(ctx, event._id, existing._id);
      return existing._id;
    }

    const listId = await ctx.db.insert("pickLists", {
      eventId: event._id,
      ownerId: null,
      teamNumber: me.teamNumber,
      name: `Team ${me.teamNumber} primary list`,
      isPrimary: true,
      isSubmitted: false,
      createdAt: Date.now(),
    });

    await seedPrimaryEntries(ctx, event._id, listId);
    return listId;
  },
});

/**
 * Puts every team on a primary list that is missing them. The primary list has
 * no owner to notice a gap, so it keeps itself in step rather than waiting for
 * an admin to press a button they may not know exists.
 *
 * Idempotent — teams already on the list are skipped, and ordering of existing
 * entries is never disturbed. Safe to call on every open.
 */
export async function seedPrimaryEntries(
  ctx: MutationCtx,
  eventId: Id<"events">,
  listId: Id<"pickLists">,
) {
  const existing = await ctx.db
    .query("pickListEntries")
    .withIndex("by_list", (q) => q.eq("pickListId", listId))
    .collect();
  const have = new Set(existing.map((e) => e.teamId));
  let order = existing.reduce((max, e) => Math.max(max, e.order), 0);

  const teams = await ctx.db
    .query("teams")
    .withIndex("by_event", (q) => q.eq("eventId", eventId))
    .collect();
  teams.sort((a, b) => a.number - b.number);

  let added = 0;
  for (const team of teams) {
    if (have.has(team._id)) continue;
    order += 1000;
    await ctx.db.insert("pickListEntries", {
      pickListId: listId,
      teamId: team._id,
      tier: "uncategorized",
      order,
    });
    added += 1;
  }
  return added;
}

export const rename = mutation({
  args: { listId: v.id("pickLists"), name: v.string() },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);
    await assertCanEdit(ctx, args.listId, userId, profile?.role === "admin");
    const name = args.name.trim();
    if (name === "") throw new Error("Give the list a name.");
    await ctx.db.patch(args.listId, { name });
  },
});

export const remove = mutation({
  args: { listId: v.id("pickLists") },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);
    const list = await assertCanEdit(ctx, args.listId, userId, profile?.role === "admin");
    if (list.isPrimary) throw new Error("The primary list cannot be deleted.");

    const entries = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", args.listId))
      .collect();
    for (const entry of entries) await ctx.db.delete(entry._id);
    await ctx.db.delete(args.listId);
  },
});

/**
 * At most one submitted list per scout per event. The others are cleared in
 * this same mutation, so the rule is transactional rather than a convention
 * the UI is trusted to keep.
 */
export const setSubmitted = mutation({
  args: { listId: v.id("pickLists") },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const list = await ctx.db.get(args.listId);
    if (!list || list.ownerId !== userId) throw new Error("That is not your list.");

    // A first pick is the one choice the whole team has to defend out loud, so
    // it does not go in without a reason. Checked here rather than on the drag:
    // the note is written after the card moves, not before.
    const first = [
      ...(await ctx.db
        .query("pickListEntries")
        .withIndex("by_list_tier", (q) =>
          q.eq("pickListId", args.listId).eq("tier", "t1"))
        .collect()),
      ...(await ctx.db
        .query("pickListEntries")
        .withIndex("by_list_tier", (q) =>
          q.eq("pickListId", args.listId).eq("tier", "dnp"))
        .collect()),
    ];
    const missing = [];
    for (const entry of first) {
      if ((entry.note ?? "").trim() !== "") continue;
      const team = await ctx.db.get(entry.teamId);
      missing.push(team ? String(team.number) : "a team");
    }
    if (missing.length > 0) {
      throw new Error(
        `Every first pick and do-not-pick needs a note before this list can be submitted. Missing: ${missing.join(", ")}.`,
      );
    }

    const mine = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", userId))
      .collect();

    for (const other of mine) {
      const shouldBe = other._id === args.listId;
      if (other.isSubmitted !== shouldBe) {
        await ctx.db.patch(other._id, { isSubmitted: shouldBe });
      }
    }
  },
});

export const unsubmit = mutation({
  args: { listId: v.id("pickLists") },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const list = await ctx.db.get(args.listId);
    if (!list || list.ownerId !== userId) throw new Error("That is not your list.");
    await ctx.db.patch(args.listId, { isSubmitted: false });
  },
});

/**
 * Drops every team into the primary list's Uncategorized column. The primary
 * list is meant to be filled by the merge, but until that exists an admin
 * needs some way to rank by hand. Skips teams already on the list, so it is
 * safe to run again after a re-import adds teams.
 */
export const populatePrimary = mutation({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", null))
      .collect();
    const list = lists.find((l) => l.teamNumber === me.teamNumber);
    if (!list) throw new Error("There is no primary list for your team yet.");

    const existing = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", list._id))
      .collect();
    const already = new Set(existing.map((e) => e.teamId));
    let order = existing.reduce((max, e) => Math.max(max, e.order), 0);

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    teams.sort((a, b) => a.number - b.number);

    let added = 0;
    for (const team of teams) {
      if (already.has(team._id)) continue;
      order += 1000;
      await ctx.db.insert("pickListEntries", {
        pickListId: list._id,
        teamId: team._id,
        tier: "uncategorized",
        order,
      });
      added += 1;
    }
    return { added };
  },
});

/**
 * A primary list on the active event that belongs to no team. Only ever one or
 * two of these exist — they predate lists being owned by a team.
 */
export const orphanPrimary = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return null;

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", null))
      .collect();
    const orphan = lists.find((l) => l.teamNumber === undefined);
    if (!orphan) return null;

    const entries = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", orphan._id))
      .collect();

    return {
      listId: orphan._id,
      name: orphan.name,
      total: entries.length,
      ranked: entries.filter((e) => e.tier !== "uncategorized").length,
    };
  },
});

/**
 * Adopts that list for the caller's team, keeping every entry and note on it.
 * Refuses if the team already has a primary, because two would leave the merge
 * writing to whichever it happened to find first.
 */
export const claimOrphanPrimary = mutation({
  args: { listId: v.id("pickLists") },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");
    if (me.teamNumber === undefined) {
      throw new Error("Set your team number on your profile first.");
    }

    const list = await ctx.db.get(args.listId);
    if (!list) throw new Error("That list no longer exists.");
    if (list.ownerId !== null) throw new Error("That is not a primary list.");
    if (list.teamNumber !== undefined) {
      throw new Error(`That list already belongs to team ${list.teamNumber}.`);
    }

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", null))
      .collect();
    if (lists.some((l) => l.teamNumber === me.teamNumber)) {
      throw new Error("Your team already has a primary list for this event.");
    }

    await ctx.db.patch(args.listId, {
      teamNumber: me.teamNumber,
      name: `Team ${me.teamNumber} primary list`,
    });
    return { teamNumber: me.teamNumber };
  },
});

/**
 * Reconciles the team primary list against the teams currently imported from
 * TBA. Safe for anyone on the team to call, as often as they like: it only
 * ever adds missing teams to Uncategorized, never reorders or removes.
 */
export const syncPrimary = mutation({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return { added: 0 };
    const me = await currentProfile(ctx);
    if (!me) return { added: 0 };

    const list = await ctx.db
      .query("pickLists")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .filter((q) =>
        q.and(
          q.eq(q.field("ownerId"), null),
          q.eq(q.field("teamNumber"), me.teamNumber),
        ),
      )
      .first();
    if (!list) return { added: 0 };

    return { added: await seedPrimaryEntries(ctx, event._id, list._id) };
  },
});