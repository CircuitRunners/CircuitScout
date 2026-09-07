#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# phase0.sh — CircuitScout Phase 0 foundation.
#
# Run from the REPO ROOT in Git Bash.  Safe to re-run.
#
# Creates: schema, roles, scoring constants, stats, typed stubs for every
# function in PLAN.md §4, nav shell with all landing routes, shared scouting
# primitives, connection indicator, fixture seed.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f package.json ]] || { echo "ERROR: run from the folder with package.json" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Dependencies"
bun add @dnd-kit/core @dnd-kit/sortable @dnd-kit/modifiers @dnd-kit/utilities
bunx shadcn@latest add -y badge skeleton switch

say "Shared domain constants"
mkdir -p convex/lib src/lib src/components/scouting src/routes/admin src/routes/teams src/routes/pit src/routes/scout src/routes/picklists src/routes/matches src/stores

cat > convex/lib/scoring.ts <<'EOF'
/**
 * Single source of truth for REBUILT scoring and match timing.
 * Nothing anywhere else may hardcode these numbers.
 */

export const CLIMB_POINTS = {
  /** Any auto climb scores 15. Rules permit L1 only during auto. */
  auto: 15,
  endgame: { none: 0, low: 10, mid: 20, high: 30 },
} as const;

export const SCOUT_WEIGHTS = { lead: 5, trusted: 3, normal: 1 } as const;

export const TIER_BASE = { t1: 100, t2: 70, t3: 40, dnp: -100 } as const;
/** Position inside a column adjusts within this band, never across tiers. */
export const TIER_POSITION_BAND = 25;

/**
 * Match timing, seconds from the start of the match.
 * autoPause is approximate — FMS assesses auto fuel before teleop begins.
 * Tune here if real matches drift.
 */
export const MATCH_TIMING = {
  autoSeconds: 20,
  autoPauseSeconds: 3,
  teleopSeconds: 140,
} as const;

export type ShiftKey = "transition" | "s1" | "s2" | "s3" | "s4";
export type Phase = "pre" | "auto" | "pause" | ShiftKey | "endgame" | "over";

/** Seconds REMAINING in teleop at which each window starts and ends. */
const WINDOWS: ReadonlyArray<{ key: ShiftKey | "endgame"; from: number; to: number }> = [
  { key: "transition", from: 140, to: 130 },
  { key: "s1", from: 130, to: 105 },
  { key: "s2", from: 105, to: 80 },
  { key: "s3", from: 80, to: 55 },
  { key: "s4", from: 55, to: 30 },
  { key: "endgame", from: 30, to: 0 },
];

export function phaseAt(secondsSinceMatchStart: number): Phase {
  const t = secondsSinceMatchStart;
  if (t < 0) return "pre";
  if (t < MATCH_TIMING.autoSeconds) return "auto";
  const teleopStart = MATCH_TIMING.autoSeconds + MATCH_TIMING.autoPauseSeconds;
  if (t < teleopStart) return "pause";

  const remaining = MATCH_TIMING.teleopSeconds - (t - teleopStart);
  if (remaining <= 0) return "over";
  for (const w of WINDOWS) {
    if (remaining <= w.from && remaining > w.to) return w.key;
  }
  return "over";
}

/**
 * The alliance that scores MORE auto fuel goes inactive first, so it is
 * active in shifts 2 and 4. Transition and endgame are active for everyone.
 */
export function activeShifts(isAutoWinner: boolean): ReadonlyArray<ShiftKey> {
  return isAutoWinner ? ["transition", "s2", "s4"] : ["transition", "s1", "s3"];
}

export type ByShift = Record<ShiftKey, number>;

export const EMPTY_BY_SHIFT: ByShift = {
  transition: 0, s1: 0, s2: 0, s3: 0, s4: 0,
};

/** Teleop fuel that actually scored points. */
export function countedTeleopFuel(byShift: ByShift, isAutoWinner: boolean): number {
  return activeShifts(isAutoWinner).reduce((sum, k) => sum + byShift[k], 0);
}

/** Teleop fuel put through a dead hub — worth zero match points. */
export function uncountedTeleopFuel(byShift: ByShift, isAutoWinner: boolean): number {
  const active = new Set<ShiftKey>(activeShifts(isAutoWinner));
  return (Object.keys(byShift) as ShiftKey[])
    .filter((k) => !active.has(k))
    .reduce((sum, k) => sum + byShift[k], 0);
}

export function climbPoints(autoClimbL1: boolean, endgame: keyof typeof CLIMB_POINTS.endgame): number {
  return (autoClimbL1 ? CLIMB_POINTS.auto : 0) + CLIMB_POINTS.endgame[endgame];
}
EOF

cat > convex/lib/types.ts <<'EOF'
/** Domain types shared by the Convex backend and the client. */

/**
 * Lanes through the alliance-zone wall.
 * Left and right are ALWAYS from that alliance's drivers looking out at the
 * field — never the scout's viewpoint, never red-relative. The UI must label
 * this permanently; a mirrored entry is silently wrong.
 */
export type Lane = "trench-left" | "bump-left" | "bump-right" | "trench-right";

export const LANES: ReadonlyArray<Lane> = [
  "trench-left", "bump-left", "bump-right", "trench-right",
];

export type StartPosition = Lane | "hub";

export const START_POSITIONS: ReadonlyArray<StartPosition> = [
  "trench-left", "bump-left", "hub", "bump-right", "trench-right",
];

/** One neutral-zone trip: out through a lane, collect, back through a lane. */
export type AutoCycle = { outbound: Lane; inbound: Lane };

export type AutoPath = {
  start: StartPosition | null;
  cycles: AutoCycle[];
  /** In-zone pickups. No crossing involved, so not part of a cycle. */
  depotPickups: number;
  outpostPickups: number;
};

export const EMPTY_AUTO_PATH: AutoPath = {
  start: null, cycles: [], depotPickups: 0, outpostPickups: 0,
};

export type ClimbLevel = "none" | "low" | "mid" | "high";
export type Tier = "t1" | "t2" | "t3" | "dnp" | "uncategorized";
export type WeightTier = "lead" | "trusted" | "normal";
export type Role = "admin" | "scout";
export type AllianceColor = "red" | "blue";
export type HubStateSource = "timed" | "estimated" | "none";

export const TIERS: ReadonlyArray<Tier> = ["t1", "t2", "t3", "dnp", "uncategorized"];

export const TIER_LABELS: Record<Tier, string> = {
  t1: "Tier 1", t2: "Tier 2", t3: "Tier 3",
  dnp: "Do Not Pick", uncategorized: "Uncategorized",
};

export type TeamStats = {
  reportCount: number;
  avgAutoFuel: number;
  avgTeleopFuel: number;      // counted only
  avgUncountedFuel: number;
  avgEndgameFuel: number;
  avgTotalFuel: number;       // counted only
  avgClimbPoints: number;
  avgDriver: number;
  avgDefense: number;
  avgAccuracy: number;
  minTotalFuel: number;
  maxTotalFuel: number;
};

export const EMPTY_STATS: TeamStats = {
  reportCount: 0, avgAutoFuel: 0, avgTeleopFuel: 0, avgUncountedFuel: 0,
  avgEndgameFuel: 0, avgTotalFuel: 0, avgClimbPoints: 0, avgDriver: 0,
  avgDefense: 0, avgAccuracy: 0, minTotalFuel: 0, maxTotalFuel: 0,
};
EOF

say "Convex schema"
cat > convex/schema.ts <<'EOF'
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";
import { authTables } from "@convex-dev/auth/server";

const lane = v.union(
  v.literal("trench-left"), v.literal("bump-left"),
  v.literal("bump-right"), v.literal("trench-right"),
);

const startPosition = v.union(lane, v.literal("hub"));

const autoPath = v.object({
  start: v.union(startPosition, v.null()),
  cycles: v.array(v.object({ outbound: lane, inbound: lane })),
  depotPickups: v.number(),
  outpostPickups: v.number(),
});

const byShift = v.object({
  transition: v.number(),
  s1: v.number(), s2: v.number(), s3: v.number(), s4: v.number(),
});

const tier = v.union(
  v.literal("t1"), v.literal("t2"), v.literal("t3"),
  v.literal("dnp"), v.literal("uncategorized"),
);

export default defineSchema({
  ...authTables,

  profiles: defineTable({
    userId: v.id("users"),
    displayName: v.string(),
    role: v.union(v.literal("admin"), v.literal("scout")),
    weightTier: v.union(v.literal("lead"), v.literal("trusted"), v.literal("normal")),
    createdAt: v.number(),
  }).index("by_user", ["userId"]),

  events: defineTable({
    tbaEventKey: v.string(),
    name: v.string(),
    isActive: v.boolean(),
    importedAt: v.union(v.number(), v.null()),
    importedBy: v.union(v.id("users"), v.null()),
  })
    .index("by_key", ["tbaEventKey"])
    .index("by_active", ["isActive"]),

  teams: defineTable({
    eventId: v.id("events"),
    tbaTeamKey: v.string(),
    number: v.number(),
    nickname: v.string(),
    city: v.string(),
    stateProv: v.string(),
    country: v.string(),
  })
    .index("by_event", ["eventId"])
    .index("by_event_number", ["eventId", "number"]),

  matches: defineTable({
    eventId: v.id("events"),
    tbaMatchKey: v.string(),
    matchNumber: v.number(),
    redTeamNumbers: v.array(v.number()),
    blueTeamNumbers: v.array(v.number()),
    scheduledTime: v.union(v.number(), v.null()),
  })
    .index("by_event", ["eventId"])
    .index("by_event_number", ["eventId", "matchNumber"]),

  matchClaims: defineTable({
    eventId: v.id("events"),
    matchId: v.id("matches"),
    teamId: v.id("teams"),
    scoutId: v.id("users"),
    claimedAt: v.number(),
    expiresAt: v.number(),
  })
    .index("by_match_team", ["matchId", "teamId"])
    .index("by_scout", ["scoutId"]),

  pitReports: defineTable({
    eventId: v.id("events"),
    teamId: v.id("teams"),
    scoutId: v.id("users"),
    updatedAt: v.number(),
    scoring: v.object({
      turret: v.boolean(),
      drumNonFullWidth: v.boolean(),
      drumFullWidth: v.boolean(),
      fixed: v.boolean(),
      kitbot: v.boolean(),
      other: v.boolean(),
      otherText: v.string(),
    }),
    climb: v.object({
      low: v.boolean(), mid: v.boolean(), high: v.boolean(),
      duringAuto: v.boolean(),
    }),
    drivetrain: v.string(),
    underTrench: v.boolean(),
    overBump: v.boolean(),
    robotNotes: v.string(),
    otherNotes: v.string(),
    photoId: v.union(v.id("_storage"), v.null()),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"]),

  matchReports: defineTable({
    eventId: v.id("events"),
    matchId: v.id("matches"),
    teamId: v.id("teams"),
    scoutId: v.id("users"),
    submittedAt: v.number(),
    updatedAt: v.number(),

    auto: v.object({
      path: autoPath,
      climbL1: v.boolean(),
      fuel: v.number(),
      fouls: v.number(),
      notes: v.string(),
    }),
    teleop: v.object({
      byShift,                       // raw, reclassifiable
      passedNeutral: v.number(),
      passedFullField: v.number(),
      stoleFuel: v.number(),
      defended: v.boolean(),
      notes: v.string(),
    }),
    endgame: v.object({
      climb: v.union(v.literal("none"), v.literal("low"),
                     v.literal("mid"), v.literal("high")),
      fuel: v.number(),
      passedNeutral: v.number(),
      passedFullField: v.number(),
      notes: v.string(),
    }),
    ratings: v.object({
      driver: v.number(), defense: v.number(), accuracy: v.number(),
      shootsOnMove: v.boolean(),
      broke: v.boolean(), brokeNotes: v.string(),
      inconsistent: v.boolean(), inconsistentNotes: v.string(),
    }),

    matchStartedAt: v.union(v.number(), v.null()),
    autoWinner: v.union(v.literal("red"), v.literal("blue"), v.null()),
    autoWinnerFlagged: v.boolean(),
    hubStateSource: v.union(v.literal("timed"), v.literal("estimated"), v.literal("none")),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"])
    .index("by_match", ["matchId"])
    .index("by_scout", ["scoutId"]),

  reportEdits: defineTable({
    reportId: v.id("matchReports"),
    editedBy: v.id("users"),
    editedAt: v.number(),
    reason: v.string(),
  }).index("by_report", ["reportId"]),

  pickLists: defineTable({
    eventId: v.id("events"),
    ownerId: v.union(v.id("users"), v.null()),   // null = team primary
    name: v.string(),
    isPrimary: v.boolean(),
    isSubmitted: v.boolean(),                    // max one per scout per event
    createdAt: v.number(),
  })
    .index("by_event", ["eventId"])
    .index("by_event_owner", ["eventId", "ownerId"])
    .index("by_event_submitted", ["eventId", "isSubmitted"]),

  pickListEntries: defineTable({
    pickListId: v.id("pickLists"),
    teamId: v.id("teams"),
    tier,
    order: v.number(),
  })
    .index("by_list", ["pickListId"])
    .index("by_list_tier", ["pickListId", "tier"]),
});
EOF

say "Auth helpers and profiles"
cat > convex/lib/guards.ts <<'EOF'
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

export async function requireAdmin(ctx: QueryCtx | MutationCtx): Promise<Doc<"profiles">> {
  const profile = await currentProfile(ctx);
  if (!profile) throw new Error("No profile for this user.");
  if (profile.role !== "admin") throw new Error("Admins only.");
  return profile;
}

/** The single active event. Returns null before an event has been set up. */
export async function activeEvent(
  ctx: QueryCtx | MutationCtx,
): Promise<Doc<"events"> | null> {
  return await ctx.db
    .query("events")
    .withIndex("by_active", (q) => q.eq("isActive", true))
    .first();
}

export async function requireActiveEvent(
  ctx: QueryCtx | MutationCtx,
): Promise<Doc<"events">> {
  const event = await activeEvent(ctx);
  if (!event) throw new Error("No active event. An admin must set one up first.");
  return event;
}
EOF

cat > convex/profiles.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { currentProfile, requireAdmin, requireUser } from "./lib/guards";

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
    await requireAdmin(ctx);
    return await ctx.db.query("profiles").collect();
  },
});

export const ensure = mutation({
  args: { displayName: v.string() },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const existing = await ctx.db
      .query("profiles")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .unique();
    if (existing) return existing._id;

    const anyProfile = await ctx.db.query("profiles").first();
    return await ctx.db.insert("profiles", {
      userId,
      displayName: args.displayName,
      role: anyProfile === null ? "admin" : "scout",
      weightTier: "normal",
      createdAt: Date.now(),
    });
  },
});

export const setRole = mutation({
  args: {
    profileId: v.id("profiles"),
    role: v.union(v.literal("admin"), v.literal("scout")),
  },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    await ctx.db.patch(args.profileId, { role: args.role });
  },
});

export const setWeightTier = mutation({
  args: {
    profileId: v.id("profiles"),
    weightTier: v.union(v.literal("lead"), v.literal("trusted"), v.literal("normal")),
  },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    await ctx.db.patch(args.profileId, { weightTier: args.weightTier });
  },
});
EOF

say "Stats and events"
cat > convex/stats.ts <<'EOF'
import { v } from "convex/values";
import { query } from "./_generated/server";
import { activeEvent } from "./lib/guards";
import { climbPoints, countedTeleopFuel, uncountedTeleopFuel } from "./lib/scoring";
import type { Doc, Id } from "./_generated/dataModel";

type Stats = {
  reportCount: number;
  avgAutoFuel: number;
  avgTeleopFuel: number;
  avgUncountedFuel: number;
  avgEndgameFuel: number;
  avgTotalFuel: number;
  avgClimbPoints: number;
  avgDriver: number;
  avgDefense: number;
  avgAccuracy: number;
  minTotalFuel: number;
  maxTotalFuel: number;
};

const mean = (xs: number[]): number =>
  xs.length === 0 ? 0 : xs.reduce((a, b) => a + b, 0) / xs.length;

export function summarise(
  reports: Doc<"matchReports">[],
  autoWinnerByReport: Map<Id<"matchReports">, boolean | null>,
): Stats {
  if (reports.length === 0) {
    return {
      reportCount: 0, avgAutoFuel: 0, avgTeleopFuel: 0, avgUncountedFuel: 0,
      avgEndgameFuel: 0, avgTotalFuel: 0, avgClimbPoints: 0, avgDriver: 0,
      avgDefense: 0, avgAccuracy: 0, minTotalFuel: 0, maxTotalFuel: 0,
    };
  }

  const auto: number[] = [];
  const teleop: number[] = [];
  const uncounted: number[] = [];
  const endgame: number[] = [];
  const totals: number[] = [];
  const climb: number[] = [];
  const driver: number[] = [];
  const defense: number[] = [];
  const accuracy: number[] = [];

  for (const r of reports) {
    const isWinner = autoWinnerByReport.get(r._id) ?? null;
    // Unknown hub state: count everything, and surface it as unknown elsewhere.
    const counted = isWinner === null
      ? Object.values(r.teleop.byShift).reduce((a, b) => a + b, 0)
      : countedTeleopFuel(r.teleop.byShift, isWinner);
    const dead = isWinner === null
      ? 0
      : uncountedTeleopFuel(r.teleop.byShift, isWinner);

    auto.push(r.auto.fuel);
    teleop.push(counted);
    uncounted.push(dead);
    endgame.push(r.endgame.fuel);
    totals.push(r.auto.fuel + counted + r.endgame.fuel);
    climb.push(climbPoints(r.auto.climbL1, r.endgame.climb));
    driver.push(r.ratings.driver);
    defense.push(r.ratings.defense);
    accuracy.push(r.ratings.accuracy);
  }

  return {
    reportCount: reports.length,
    avgAutoFuel: mean(auto),
    avgTeleopFuel: mean(teleop),
    avgUncountedFuel: mean(uncounted),
    avgEndgameFuel: mean(endgame),
    avgTotalFuel: mean(totals),
    avgClimbPoints: mean(climb),
    avgDriver: mean(driver),
    avgDefense: mean(defense),
    avgAccuracy: mean(accuracy),
    minTotalFuel: Math.min(...totals),
    maxTotalFuel: Math.max(...totals),
  };
}

/**
 * Averages for every team at the active event, keyed by team id.
 * Consumed by the team list, compare view, pick list board and merge.
 */
export const forEvent = query({
  args: {},
  handler: async (ctx): Promise<Record<string, Stats>> => {
    const event = await activeEvent(ctx);
    if (!event) return {};

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();

    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const matchById = new Map(matches.map((m) => [m._id, m]));

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const teamById = new Map(teams.map((t) => [t._id, t]));

    const winnerFlag = new Map<Id<"matchReports">, boolean | null>();
    for (const r of reports) {
      const match = matchById.get(r.matchId) ?? null;
      const team = teamById.get(r.teamId) ?? null;
      if (r.autoWinner === null || match === null || team === null) {
        winnerFlag.set(r._id, null);
        continue;
      }
      const onRed = match.redTeamNumbers.includes(team.number);
      winnerFlag.set(r._id, r.autoWinner === (onRed ? "red" : "blue"));
    }

    const byTeam = new Map<Id<"teams">, Doc<"matchReports">[]>();
    for (const r of reports) {
      const list = byTeam.get(r.teamId) ?? [];
      list.push(r);
      byTeam.set(r.teamId, list);
    }

    const out: Record<string, Stats> = {};
    for (const team of teams) {
      out[team._id] = summarise(byTeam.get(team._id) ?? [], winnerFlag);
    }
    return out;
  },
});

/** Per-match series for one team. Track H. */
export const forTeam = query({
  args: { teamId: v.id("teams") },
  handler: async (_ctx, _args) => [],
});

/** Aligned metric rows for 2-4 teams. Track H. */
export const compare = query({
  args: { teamIds: v.array(v.id("teams")) },
  handler: async (_ctx, _args) => [],
});

/** Missing reports, flagged reports, per-scout counts. Track H. */
export const coverage = query({
  args: {},
  handler: async (_ctx) => ({ missingReports: [], flagged: [], byScout: [] }),
});
EOF

cat > convex/events.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent, requireAdmin } from "./lib/guards";

export const active = query({
  args: {},
  handler: async (ctx) => await activeEvent(ctx),
});

export const list = query({
  args: {},
  handler: async (ctx) => await ctx.db.query("events").collect(),
});

export const setActive = mutation({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const all = await ctx.db.query("events").collect();
    for (const e of all) {
      await ctx.db.patch(e._id, { isActive: e._id === args.eventId });
    }
  },
});

/** Track A. Creates the event row; the TBA action populates it. */
export const create = mutation({
  args: { tbaEventKey: v.string(), name: v.string() },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const existing = await ctx.db
      .query("events")
      .withIndex("by_key", (q) => q.eq("tbaEventKey", args.tbaEventKey))
      .unique();
    if (existing) return existing._id;
    return await ctx.db.insert("events", {
      tbaEventKey: args.tbaEventKey,
      name: args.name,
      isActive: false,
      importedAt: null,
      importedBy: null,
    });
  },
});
EOF

say "Typed stubs for Phase 1 tracks"
cat > convex/teams.ts <<'EOF'
import { v } from "convex/values";
import { query } from "./_generated/server";
import { activeEvent } from "./lib/guards";

/** Team list with pit status and report counts. Track E extends this. */
export const listWithStatus = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return [];

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();

    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const scouted = new Set(pit.map((p) => p.teamId));

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const counts = new Map<string, number>();
    for (const r of reports) {
      counts.set(r.teamId, (counts.get(r.teamId) ?? 0) + 1);
    }

    return teams
      .sort((a, b) => a.number - b.number)
      .map((t) => ({
        ...t,
        pitScouted: scouted.has(t._id),
        reportCount: counts.get(t._id) ?? 0,
      }));
  },
});

/** Track E. */
export const detail = query({
  args: { teamId: v.id("teams") },
  handler: async (ctx, args) => await ctx.db.get(args.teamId),
});
EOF

cat > convex/matches.ts <<'EOF'
import { v } from "convex/values";
import { query } from "./_generated/server";
import { activeEvent } from "./lib/guards";

export const listForEvent = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    return matches.sort((a, b) => a.matchNumber - b.matchNumber);
  },
});

/** The six robots in a match, red then blue. Track C. */
export const teamsInMatch = query({
  args: { matchNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    const match = await ctx.db
      .query("matches")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("matchNumber", args.matchNumber))
      .unique();
    if (!match) return null;

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const byNumber = new Map(teams.map((t) => [t.number, t]));

    return {
      match,
      red: match.redTeamNumbers.map((n) => byNumber.get(n) ?? null),
      blue: match.blueTeamNumbers.map((n) => byNumber.get(n) ?? null),
    };
  },
});
EOF

cat > convex/pit.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent } from "./lib/guards";

/** Track B. */
export const get = query({
  args: { teamId: v.id("teams") },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    return await ctx.db
      .query("pitReports")
      .withIndex("by_event_team", (q) =>
        q.eq("eventId", event._id).eq("teamId", args.teamId))
      .unique();
  },
});

export const upsert = mutation({
  args: { teamId: v.id("teams") },
  handler: async (_ctx, _args) => {
    throw new Error("Not implemented — Track B owns convex/pit.ts");
  },
});

export const generateUploadUrl = mutation({
  args: {},
  handler: async (ctx) => await ctx.storage.generateUploadUrl(),
});
EOF

cat > convex/claims.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { requireUser } from "./lib/guards";

/** Claims expire so an abandoned form does not lock a robot for the event. */
export const CLAIM_TTL_MS = 20 * 60 * 1000;

/** Track C. */
export const mine = query({
  args: {},
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const now = Date.now();
    const claims = await ctx.db
      .query("matchClaims")
      .withIndex("by_scout", (q) => q.eq("scoutId", userId))
      .collect();
    return claims.filter((c) => c.expiresAt > now);
  },
});

export const claim = mutation({
  args: { matchId: v.id("matches"), teamId: v.id("teams") },
  handler: async (_ctx, _args) => {
    throw new Error("Not implemented — Track C owns convex/claims.ts");
  },
});

export const release = mutation({
  args: { matchId: v.id("matches"), teamId: v.id("teams") },
  handler: async (_ctx, _args) => {
    throw new Error("Not implemented — Track C owns convex/claims.ts");
  },
});
EOF

cat > convex/matchReports.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent } from "./lib/guards";

/** Track C. */
export const listForTeam = query({
  args: { teamId: v.id("teams") },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    return await ctx.db
      .query("matchReports")
      .withIndex("by_event_team", (q) =>
        q.eq("eventId", event._id).eq("teamId", args.teamId))
      .collect();
  },
});

export const editHistory = query({
  args: { reportId: v.id("matchReports") },
  handler: async (ctx, args) =>
    await ctx.db
      .query("reportEdits")
      .withIndex("by_report", (q) => q.eq("reportId", args.reportId))
      .collect(),
});

export const submit = mutation({
  args: { matchId: v.id("matches"), teamId: v.id("teams") },
  handler: async (_ctx, _args) => {
    throw new Error("Not implemented — Track C owns convex/matchReports.ts");
  },
});

/** `reason` is required and must be non-empty. See PLAN.md RESOLVED 2. */
export const update = mutation({
  args: { reportId: v.id("matchReports"), reason: v.string() },
  handler: async (_ctx, args) => {
    if (args.reason.trim() === "") throw new Error("An edit reason is required.");
    throw new Error("Not implemented — Track C owns convex/matchReports.ts");
  },
});
EOF

cat > convex/hub.ts <<'EOF'
import { v } from "convex/values";
import { query } from "./_generated/server";

/**
 * Track C. The alliance scoring more auto fuel goes inactive first.
 * When all six robots in a match have reports, this is derivable and the
 * scout's entry becomes a cross-check rather than the source of truth.
 */
export const deriveAutoWinner = query({
  args: { matchId: v.id("matches") },
  handler: async (_ctx, _args): Promise<"red" | "blue" | null> => null,
});

/** Cross-scout reconciliation. Returns disagreements, never blocks. */
export const reconcile = query({
  args: { matchId: v.id("matches") },
  handler: async (_ctx, _args) => ({ derived: null, entries: [], disagreements: [] }),
});
EOF

cat > convex/pickLists.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent, requireUser } from "./lib/guards";

/** Track F. */
export const listMine = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    const userId = await requireUser(ctx);
    return await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", userId))
      .collect();
  },
});

export const primary = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    return await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", null))
      .first();
  },
});

export const create = mutation({
  args: { name: v.string() },
  handler: async (_ctx, _args) => {
    throw new Error("Not implemented — Track F owns convex/pickLists.ts");
  },
});

export const rename = mutation({
  args: { listId: v.id("pickLists"), name: v.string() },
  handler: async (_ctx, _args) => {
    throw new Error("Not implemented — Track F owns convex/pickLists.ts");
  },
});

export const remove = mutation({
  args: { listId: v.id("pickLists") },
  handler: async (_ctx, _args) => {
    throw new Error("Not implemented — Track F owns convex/pickLists.ts");
  },
});

/**
 * At most one submitted list per scout per event. Clearing the others must
 * happen in this same mutation so the rule is transactional, not conventional.
 */
export const setSubmitted = mutation({
  args: { listId: v.id("pickLists") },
  handler: async (_ctx, _args) => {
    throw new Error("Not implemented — Track F owns convex/pickLists.ts");
  },
});
EOF

cat > convex/entries.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";

/** Track F. */
export const forList = query({
  args: { listId: v.id("pickLists") },
  handler: async (ctx, args) =>
    await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", args.listId))
      .collect(),
});

/**
 * `order` is a float. Insert between neighbours by halving the gap; renormalise
 * the column only when the gap gets too small to represent.
 */
export const move = mutation({
  args: {
    entryId: v.id("pickListEntries"),
    tier: v.union(v.literal("t1"), v.literal("t2"), v.literal("t3"),
                  v.literal("dnp"), v.literal("uncategorized")),
    order: v.number(),
  },
  handler: async (_ctx, _args) => {
    throw new Error("Not implemented — Track F owns convex/entries.ts");
  },
});
EOF

cat > convex/merge.ts <<'EOF'
import { mutation, query } from "./_generated/server";

/**
 * Track G. Pure computation — writes nothing. Returns the ranked table with
 * weighted consensus score, UNWEIGHTED spread, voter count and dnpCount.
 * The spread stays unweighted deliberately: it exists to surface disagreement
 * and weighting it would hide exactly what it is for.
 */
export const preview = query({
  args: {},
  handler: async (_ctx) => ({ rows: [], submitters: [], missing: [] }),
});

/** Writes the previewed ranking into the primary list. Admin only. */
export const apply = mutation({
  args: {},
  handler: async (_ctx) => {
    throw new Error("Not implemented — Track G owns convex/merge.ts");
  },
});
EOF

cat > convex/exports.ts <<'EOF'
import { v } from "convex/values";
import { query } from "./_generated/server";

/** Track H. Escape hatch for when the app is unavailable at the worst moment. */
export const csv = query({
  args: {
    kind: v.union(v.literal("teams"), v.literal("matchReports"), v.literal("pitReports")),
  },
  handler: async (_ctx, _args): Promise<string> => "",
});
EOF

cat > convex/tba.ts <<'EOF'
"use node";

import { v } from "convex/values";
import { action } from "./_generated/server";

export const TBA_BASE = "https://www.thebluealliance.com/api/v3";

/**
 * Track A. Fetches /event/{key}/teams/simple and /event/{key}/matches/simple,
 * filters matches to comp_level === "qm", and upserts by tbaTeamKey /
 * tbaMatchKey so a re-import after a schedule change updates rather than
 * duplicates. Schedules do change mid-event; re-import must stay safe.
 *
 * The API key lives in the Convex environment as TBA_API_KEY and must never
 * reach the client:  bunx convex env set TBA_API_KEY <key>
 */
export const importEvent = action({
  args: { tbaEventKey: v.string() },
  handler: async (_ctx, _args) => {
    throw new Error("Not implemented — Track A owns convex/tba.ts");
  },
});
EOF

say "Fixture seed"
cat > convex/seed.ts <<'EOF'
import { mutation } from "./_generated/server";
import { EMPTY_BY_SHIFT } from "./lib/scoring";
import { requireUser } from "./lib/guards";

/**
 * Fixture data so every Phase 1 track can develop before the TBA import lands.
 * Idempotent: re-running replaces the fixture event.
 * Reports are attributed to the signed-in caller, so sign in first, then:
 *
 *   bunx convex run seed:fixtures
 */
const TEAM_SEED: ReadonlyArray<[number, string, string, string]> = [
  [1002, "CircuitRunners", "Marietta", "GA"],
  [254, "The Cheesy Poofs", "San Jose", "CA"],
  [1678, "Citrus Circuits", "Davis", "CA"],
  [118, "Robonauts", "League City", "TX"],
  [2056, "OP Robotics", "Stoney Creek", "ON"],
  [33, "Killer Bees", "Auburn Hills", "MI"],
  [971, "Spartan Robotics", "Mountain View", "CA"],
  [1323, "MadTown Robotics", "Madera", "CA"],
  [3538, "RoboJackets", "Waterford", "MI"],
  [4613, "Barker Redbacks", "Sydney", "NSW"],
  [6800, "Mustang Robotics", "Cumming", "GA"],
  [4026, "Nighthawks", "Alpharetta", "GA"],
];

function rng(seed: number): () => number {
  let s = seed;
  return () => {
    s = (s * 1664525 + 1013904223) % 4294967296;
    return s / 4294967296;
  };
}

export const fixtures = mutation({
  args: {},
  handler: async (ctx) => {
    const scoutId = await requireUser(ctx);
    const key = "2026fixture";

    const old = await ctx.db
      .query("events")
      .withIndex("by_key", (q) => q.eq("tbaEventKey", key))
      .unique();
    if (old) {
      for (const table of ["teams", "matches", "matchReports", "pitReports"] as const) {
        const rows = await ctx.db
          .query(table)
          .withIndex("by_event", (q) => q.eq("eventId", old._id))
          .collect();
        for (const r of rows) await ctx.db.delete(r._id);
      }
      await ctx.db.delete(old._id);
    }

    const eventId = await ctx.db.insert("events", {
      tbaEventKey: key,
      name: "Fixture Event (local development)",
      isActive: true,
      importedAt: Date.now(),
      importedBy: null,
    });

    const teamIds = [];
    for (const [number, nickname, city, stateProv] of TEAM_SEED) {
      teamIds.push(
        await ctx.db.insert("teams", {
          eventId,
          tbaTeamKey: `frc${number}`,
          number,
          nickname,
          city,
          stateProv,
          country: "USA",
        }),
      );
    }

    const numbers = TEAM_SEED.map(([n]) => n);
    const rand = rng(42);

    for (let i = 1; i <= 24; i++) {
      const shuffled = [...numbers].sort(() => rand() - 0.5);
      await ctx.db.insert("matches", {
        eventId,
        tbaMatchKey: `${key}_qm${i}`,
        matchNumber: i,
        redTeamNumbers: shuffled.slice(0, 3),
        blueTeamNumbers: shuffled.slice(3, 6),
        scheduledTime: Date.now() + i * 8 * 60 * 1000,
      });
    }

    // A few match reports so stats and the pick list have something to show.
    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", eventId))
      .collect();
    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", eventId))
      .collect();
    const byNumber = new Map(teams.map((t) => [t.number, t]));
    const climbs = ["none", "low", "mid", "high"] as const;

    for (const match of matches.slice(0, 12)) {
      const all = [...match.redTeamNumbers, ...match.blueTeamNumbers];
      for (const n of all) {
        const team = byNumber.get(n);
        if (!team) continue;
        const scale = 0.4 + rand();
        await ctx.db.insert("matchReports", {
          eventId,
          matchId: match._id,
          teamId: team._id,
          scoutId,
          submittedAt: Date.now(),
          updatedAt: Date.now(),
          auto: {
            path: { start: "hub", cycles: [], depotPickups: 1, outpostPickups: 0 },
            climbL1: rand() > 0.7,
            fuel: Math.round(rand() * 12 * scale),
            fouls: rand() > 0.9 ? 1 : 0,
            notes: "",
          },
          teleop: {
            byShift: {
              ...EMPTY_BY_SHIFT,
              transition: Math.round(rand() * 6 * scale),
              s1: Math.round(rand() * 14 * scale),
              s2: Math.round(rand() * 14 * scale),
              s3: Math.round(rand() * 12 * scale),
              s4: Math.round(rand() * 12 * scale),
            },
            passedNeutral: Math.round(rand() * 8),
            passedFullField: Math.round(rand() * 4),
            stoleFuel: Math.round(rand() * 3),
            defended: rand() > 0.75,
            notes: "",
          },
          endgame: {
            climb: climbs[Math.floor(rand() * climbs.length)] ?? "none",
            fuel: Math.round(rand() * 8 * scale),
            passedNeutral: 0,
            passedFullField: 0,
            notes: "",
          },
          ratings: {
            driver: 1 + Math.floor(rand() * 10),
            defense: 1 + Math.floor(rand() * 10),
            accuracy: 1 + Math.floor(rand() * 10),
            shootsOnMove: rand() > 0.5,
            broke: rand() > 0.92,
            brokeNotes: "",
            inconsistent: rand() > 0.85,
            inconsistentNotes: "",
          },
          matchStartedAt: null,
          autoWinner: rand() > 0.5 ? "red" : "blue",
          autoWinnerFlagged: false,
          hubStateSource: "estimated",
        });
      }
    }

    return { eventId, teams: teamIds.length, matches: matches.length };
  },
});
EOF

say "Client shared modules"
cat > src/lib/scoring.ts <<'EOF'
// Re-exported so the client and the Convex backend share one definition.
export * from "../../convex/lib/scoring";
EOF

cat > src/lib/types.ts <<'EOF'
export * from "../../convex/lib/types";
EOF

cat > src/stores/ui-store.ts <<'EOF'
import { create } from "zustand";
import type { Tier } from "@/lib/types";

/**
 * Ephemeral, client-only UI state.
 *
 * Allowed: selection, active tab, panel/sidebar/dialog open, drag state,
 * transient editor state, local view preferences.
 *
 * NOT allowed: anything persisted or owned by Convex. Never mirror a query
 * result into this store — subscribe with useQuery instead.
 */
export type SortKey = "totalFuel" | "climbPoints" | "defense" | "driver";
export type SortDirection = "asc" | "desc";

type UIState = {
  navOpen: boolean;
  draggingTeamId: string | null;
  /** Sorting Uncategorized is a VIEW, never a rewrite of stored order. */
  uncategorizedSort: { key: SortKey; direction: SortDirection } | null;
  activeTier: Tier;
  matchFormPeriod: "auto" | "teleop" | "endgame";
};

type UIActions = {
  setNavOpen: (open: boolean) => void;
  toggleNav: () => void;
  setDraggingTeamId: (id: string | null) => void;
  setUncategorizedSort: (sort: UIState["uncategorizedSort"]) => void;
  setActiveTier: (tier: Tier) => void;
  setMatchFormPeriod: (period: UIState["matchFormPeriod"]) => void;
  reset: () => void;
};

const initial: UIState = {
  navOpen: false,
  draggingTeamId: null,
  uncategorizedSort: null,
  activeTier: "uncategorized",
  matchFormPeriod: "auto",
};

export const useUIStore = create<UIState & UIActions>()((set) => ({
  ...initial,
  setNavOpen: (navOpen) => set({ navOpen }),
  toggleNav: () => set((s) => ({ navOpen: !s.navOpen })),
  setDraggingTeamId: (draggingTeamId) => set({ draggingTeamId }),
  setUncategorizedSort: (uncategorizedSort) => set({ uncategorizedSort }),
  setActiveTier: (activeTier) => set({ activeTier }),
  setMatchFormPeriod: (matchFormPeriod) => set({ matchFormPeriod }),
  reset: () => set(initial),
}));
EOF

say "Shared scouting primitives"
cat > src/components/scouting/stepper.tsx <<'EOF'
import { Minus, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";

const STEPS = [10, 5, 1] as const;

/**
 * Large ±10 / ±5 / ±1 counter. Used by every fuel input in the match form.
 * No keyboard entry: this is tapped one-handed while watching a match.
 */
export function Stepper({
  label,
  value,
  onChange,
  min = 0,
}: {
  label: string;
  value: number;
  onChange: (next: number) => void;
  min?: number;
}) {
  const bump = (delta: number) => onChange(Math.max(min, value + delta));

  return (
    <div className="space-y-3">
      <div className="flex items-baseline justify-between">
        <span className="text-sm font-medium">{label}</span>
        <span className="text-3xl font-semibold tabular-nums">{value}</span>
      </div>
      <div className="grid grid-cols-6 gap-2">
        {STEPS.map((step) => (
          <Button
            key={`minus-${step}`}
            variant="outline"
            className="h-14 text-base"
            onClick={() => bump(-step)}
            aria-label={`Subtract ${step} from ${label}`}
          >
            <Minus className="size-3" />
            {step}
          </Button>
        ))}
        {STEPS.map((step) => (
          <Button
            key={`plus-${step}`}
            variant="secondary"
            className="h-14 text-base"
            onClick={() => bump(step)}
            aria-label={`Add ${step} to ${label}`}
          >
            <Plus className="size-3" />
            {step}
          </Button>
        ))}
      </div>
    </div>
  );
}
EOF

cat > src/components/scouting/rating-scale.tsx <<'EOF'
import { Button } from "@/components/ui/button";

const VALUES = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] as const;

export function RatingScale({
  label,
  value,
  onChange,
}: {
  label: string;
  value: number | null;
  onChange: (next: number) => void;
}) {
  return (
    <div className="space-y-2">
      <span className="text-sm font-medium">{label}</span>
      <div className="grid grid-cols-5 gap-2">
        {VALUES.map((n) => (
          <Button
            key={n}
            variant={value === n ? "default" : "outline"}
            className="h-12 text-base"
            onClick={() => onChange(n)}
            aria-label={`${label}: ${n} of 10`}
          >
            {n}
          </Button>
        ))}
      </div>
    </div>
  );
}
EOF

cat > src/components/scouting/segmented-choice.tsx <<'EOF'
import { Button } from "@/components/ui/button";

/**
 * Two to four large exclusive buttons. Lane pickers, climb level, intake
 * source. `hint` is a permanent label, not a tooltip — used to state that
 * left/right are from the drivers' perspective.
 */
export function SegmentedChoice<T extends string>({
  label,
  hint,
  options,
  value,
  onChange,
}: {
  label: string;
  hint?: string;
  options: ReadonlyArray<{ value: T; label: string }>;
  value: T | null;
  onChange: (next: T) => void;
}) {
  return (
    <div className="space-y-2">
      <div className="flex items-baseline justify-between gap-2">
        <span className="text-sm font-medium">{label}</span>
        {hint ? (
          <span className="text-muted-foreground text-xs">{hint}</span>
        ) : null}
      </div>
      <div
        className="grid gap-2"
        style={{ gridTemplateColumns: `repeat(${Math.min(options.length, 2)}, minmax(0, 1fr))` }}
      >
        {options.map((option) => (
          <Button
            key={option.value}
            variant={value === option.value ? "default" : "outline"}
            className="h-14 text-base"
            onClick={() => onChange(option.value)}
          >
            {option.label}
          </Button>
        ))}
      </div>
    </div>
  );
}
EOF

cat > src/components/scouting/capability-check.tsx <<'EOF'
import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";

export function CapabilityCheck({
  id,
  label,
  description,
  checked,
  onChange,
}: {
  id: string;
  label: string;
  description?: string;
  checked: boolean;
  onChange: (next: boolean) => void;
}) {
  return (
    <label
      htmlFor={id}
      className="hover:bg-accent/50 flex min-h-14 cursor-pointer items-center gap-3 rounded-lg border p-3"
    >
      <Checkbox
        id={id}
        checked={checked}
        onCheckedChange={(next: boolean) => onChange(Boolean(next))}
      />
      <div className="space-y-0.5">
        <Label htmlFor={id} className="cursor-pointer text-base">{label}</Label>
        {description ? (
          <p className="text-muted-foreground text-xs">{description}</p>
        ) : null}
      </div>
    </label>
  );
}
EOF

cat > src/components/scouting/team-card.tsx <<'EOF'
import { Badge } from "@/components/ui/badge";
import { TIER_LABELS, type Tier } from "@/lib/types";

/**
 * Shared by the team list, the pit grid and the pick list board.
 * `n` is shown next to every average elsewhere for the same reason the report
 * count appears here: an average over two matches is not an average over ten.
 */
export function TeamCard({
  number,
  nickname,
  pitScouted,
  reportCount,
  tier,
  onClick,
}: {
  number: number;
  nickname: string;
  pitScouted: boolean;
  reportCount: number;
  tier?: Tier;
  onClick?: () => void;
}) {
  const Wrapper = onClick ? "button" : "div";
  return (
    <Wrapper
      onClick={onClick}
      className="hover:bg-accent/50 flex w-full min-h-16 items-center gap-3 rounded-lg border p-3 text-left transition-colors"
    >
      <span className="w-14 shrink-0 text-lg font-semibold tabular-nums">{number}</span>
      <span className="min-w-0 flex-1 truncate text-sm">{nickname}</span>
      <div className="flex shrink-0 items-center gap-1.5">
        {tier && tier !== "uncategorized" ? (
          <Badge variant="secondary">{TIER_LABELS[tier]}</Badge>
        ) : null}
        <Badge variant={pitScouted ? "default" : "outline"}>
          {pitScouted ? "Pit" : "No pit"}
        </Badge>
        <Badge variant="outline">{reportCount} rpt</Badge>
      </div>
    </Wrapper>
  );
}
EOF

cat > src/components/connection-indicator.tsx <<'EOF'
import { useConvex } from "convex/react";
import { useEffect, useState } from "react";
import { CloudOff, Cloud } from "lucide-react";

/**
 * Venue wifi is unreliable and Convex is websocket-backed. A scout must be
 * able to see they are offline BEFORE keying in six minutes of match data.
 */
export function ConnectionIndicator() {
  const convex = useConvex();
  const [online, setOnline] = useState(true);

  useEffect(() => {
    const update = () => setOnline(navigator.onLine);
    update();
    window.addEventListener("online", update);
    window.addEventListener("offline", update);
    return () => {
      window.removeEventListener("online", update);
      window.removeEventListener("offline", update);
    };
  }, [convex]);

  if (online) {
    return (
      <span className="text-muted-foreground flex items-center gap-1.5 text-xs">
        <Cloud className="size-3.5" />
        <span className="hidden sm:inline">Live</span>
      </span>
    );
  }

  return (
    <span className="flex items-center gap-1.5 rounded-md bg-destructive px-2 py-1 text-xs font-medium text-white">
      <CloudOff className="size-3.5" />
      Offline
    </span>
  );
}
EOF

say "Nav shell and routes"
cat > src/components/app-nav.tsx <<'EOF'
import { useAuthActions } from "@convex-dev/auth/react";
import { useQuery } from "convex/react";
import { LogOut, Menu } from "lucide-react";
import { NavLink } from "react-router";

import { api } from "../../convex/_generated/api";
import { ConnectionIndicator } from "@/components/connection-indicator";
import { ThemeToggle } from "@/components/theme-toggle";
import { Button } from "@/components/ui/button";
import { Sheet, SheetContent, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { useUIStore } from "@/stores/ui-store";

type NavItem = { to: string; label: string; adminOnly?: boolean };

const NAV: ReadonlyArray<NavItem> = [
  { to: "/", label: "Dashboard" },
  { to: "/pit", label: "Pit Scouting" },
  { to: "/scout", label: "Match Scouting" },
  { to: "/teams", label: "Teams" },
  { to: "/matches", label: "Matches" },
  { to: "/picklists", label: "Pick Lists" },
  { to: "/admin", label: "Admin", adminOnly: true },
];

function linkClass({ isActive }: { isActive: boolean }): string {
  return [
    "rounded-md px-3 py-2 text-sm transition-colors",
    isActive
      ? "bg-accent text-accent-foreground font-medium"
      : "text-muted-foreground hover:text-foreground",
  ].join(" ");
}

export function AppNav() {
  const { signOut } = useAuthActions();
  const profile = useQuery(api.profiles.me);
  const navOpen = useUIStore((s) => s.navOpen);
  const setNavOpen = useUIStore((s) => s.setNavOpen);

  const items = NAV.filter((i) => !i.adminOnly || profile?.role === "admin");

  return (
    <header className="bg-background sticky top-0 z-40 border-b">
      <div className="mx-auto flex h-14 w-full max-w-6xl items-center gap-2 px-4">
        <Button
          variant="ghost"
          size="icon"
          className="md:hidden"
          aria-label="Open navigation"
          onClick={() => setNavOpen(true)}
        >
          <Menu className="size-5" />
        </Button>

        <NavLink to="/" className="font-semibold tracking-tight">
          CircuitScout
        </NavLink>

        <nav className="ml-4 hidden items-center gap-1 md:flex">
          {items.map((item) => (
            <NavLink key={item.to} to={item.to} end={item.to === "/"} className={linkClass}>
              {item.label}
            </NavLink>
          ))}
        </nav>

        <div className="ml-auto flex items-center gap-2">
          <ConnectionIndicator />
          <ThemeToggle />
          <Button
            variant="ghost"
            size="icon"
            aria-label="Sign out"
            onClick={() => void signOut()}
          >
            <LogOut className="size-4" />
          </Button>
        </div>
      </div>

      <Sheet open={navOpen} onOpenChange={setNavOpen}>
        <SheetContent side="left" className="w-72">
          <SheetHeader>
            <SheetTitle>CircuitScout</SheetTitle>
          </SheetHeader>
          <nav className="flex flex-col gap-1 p-4">
            {items.map((item) => (
              <NavLink
                key={item.to}
                to={item.to}
                end={item.to === "/"}
                className={linkClass}
                onClick={() => setNavOpen(false)}
              >
                {item.label}
              </NavLink>
            ))}
          </nav>
        </SheetContent>
      </Sheet>
    </header>
  );
}
EOF

cat > src/routes/app-layout.tsx <<'EOF'
import { Outlet } from "react-router";
import { AppNav } from "@/components/app-nav";

export function AppLayout() {
  return (
    <div className="flex min-h-svh flex-col">
      <AppNav />
      <main className="mx-auto w-full max-w-6xl flex-1 px-4 py-6">
        <Outlet />
      </main>
    </div>
  );
}
EOF

cat > src/routes/page-shell.tsx <<'EOF'
import type { ReactNode } from "react";

/** Consistent heading block for every landing area. */
export function PageShell({
  title,
  description,
  actions,
  children,
}: {
  title: string;
  description?: string;
  actions?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
          {description ? (
            <p className="text-muted-foreground mt-1 text-sm">{description}</p>
          ) : null}
        </div>
        {actions}
      </div>
      {children}
    </div>
  );
}

export function TrackStub({ track, scope }: { track: string; scope: string }) {
  return (
    <div className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
      <p className="font-medium">Track {track}</p>
      <p className="mt-1">{scope}</p>
    </div>
  );
}
EOF

cat > src/routes/dashboard.tsx <<'EOF'
import { useQuery } from "convex/react";
import { api } from "../../convex/_generated/api";
import { PageShell } from "./page-shell";
import { Card, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

export default function DashboardPage() {
  const event = useQuery(api.events.active);
  const teams = useQuery(api.teams.listWithStatus);
  const matches = useQuery(api.matches.listForEvent);

  const pitDone = teams?.filter((t) => t.pitScouted).length ?? 0;
  const reports = teams?.reduce((sum, t) => sum + t.reportCount, 0) ?? 0;

  return (
    <PageShell
      title={event ? event.name : "No active event"}
      description={
        event
          ? `${event.tbaEventKey} · ${teams?.length ?? 0} teams · ${matches?.length ?? 0} qualification matches`
          : "An admin needs to set up an event before scouting can begin."
      }
    >
      <div className="grid gap-4 sm:grid-cols-3">
        <Card>
          <CardHeader>
            <CardDescription>Pit scouted</CardDescription>
            <CardTitle className="text-3xl tabular-nums">
              {pitDone}/{teams?.length ?? 0}
            </CardTitle>
          </CardHeader>
        </Card>
        <Card>
          <CardHeader>
            <CardDescription>Match reports</CardDescription>
            <CardTitle className="text-3xl tabular-nums">{reports}</CardTitle>
          </CardHeader>
        </Card>
        <Card>
          <CardHeader>
            <CardDescription>Matches</CardDescription>
            <CardTitle className="text-3xl tabular-nums">{matches?.length ?? 0}</CardTitle>
          </CardHeader>
        </Card>
      </div>
    </PageShell>
  );
}
EOF

write_stub () {
  local path="$1" comp="$2" title="$3" desc="$4" track="$5" scope="$6"
  cat > "$path" <<EOF2
import { PageShell, TrackStub } from "@/routes/page-shell";

export default function ${comp}() {
  return (
    <PageShell title="${title}" description="${desc}">
      <TrackStub track="${track}" scope="${scope}" />
    </PageShell>
  );
}
EOF2
}

write_stub src/routes/pit/index.tsx PitLandingPage "Pit Scouting" \
  "Grid of every team, scouted or not. Tap a team to scout it." B \
  "Pit grid landing, pit form, photo upload."
write_stub src/routes/pit/form.tsx PitFormPage "Pit Scouting Form" \
  "Capabilities, drivetrain, notes, robot photo." B \
  "Pit grid landing, pit form, photo upload."
write_stub src/routes/scout/index.tsx ScoutLandingPage "Match Scouting" \
  "Upcoming matches, your claims, and reports you have submitted." C \
  "Match landing, team selector, claims, match form."
write_stub src/routes/scout/form.tsx MatchFormPage "Match Scouting Form" \
  "Auto, teleop and endgame. Tap Match Start when the match begins." C \
  "Match landing, team selector, claims, match form."
write_stub src/routes/teams/index.tsx TeamsPage "Teams" \
  "Every team at the event, with pit status and report counts." E \
  "Team list, detail modal, dashboard."
write_stub src/routes/teams/compare.tsx ComparePage "Compare Teams" \
  "Two to four teams side by side on the same metric rows." H \
  "Compare view, match preview, coverage and QA, CSV export."
write_stub src/routes/matches/index.tsx MatchesPage "Matches" \
  "Qualification schedule." H \
  "Compare view, match preview, coverage and QA, CSV export."
write_stub src/routes/matches/preview.tsx MatchPreviewPage "Match Preview" \
  "All six robots with their key averages, red and blue." H \
  "Compare view, match preview, coverage and QA, CSV export."
write_stub src/routes/picklists/index.tsx PickListsPage "Pick Lists" \
  "The team primary list and your personal lists." F \
  "Pick list landing, Kanban board, drag and drop, sorting."
write_stub src/routes/picklists/board.tsx PickListBoardPage "Pick List" \
  "Tier 1 is highest. Drag teams between columns to rank them." F \
  "Pick list landing, Kanban board, drag and drop, sorting."
write_stub src/routes/admin/index.tsx AdminPage "Admin" \
  "Event setup, scout roles and weighting." A \
  "TBA import, event setup, role management."
write_stub src/routes/admin/data.tsx AdminDataPage "Coverage and Quality" \
  "Missing reports, flagged reports, per-scout counts, CSV export." H \
  "Compare view, match preview, coverage and QA, CSV export."
write_stub src/routes/admin/merge.tsx AdminMergePage "Merge Pick Lists" \
  "Preview the weighted consensus before writing to the primary list." G \
  "Consensus merge algorithm and admin merge UI."

cat > src/routes/router.tsx <<'EOF'
import { createBrowserRouter } from "react-router";

import { AppLayout } from "./app-layout";
import { AuthLayout } from "./auth-layout";
import { RequireAdmin, RequireAuth } from "./require-auth";
import { RootLayout } from "./root-layout";

import DashboardPage from "./dashboard";
import NotFoundPage from "./not-found";
import SignInPage from "./sign-in";
import PitLandingPage from "./pit/index";
import PitFormPage from "./pit/form";
import ScoutLandingPage from "./scout/index";
import MatchFormPage from "./scout/form";
import TeamsPage from "./teams/index";
import ComparePage from "./teams/compare";
import MatchesPage from "./matches/index";
import MatchPreviewPage from "./matches/preview";
import PickListsPage from "./picklists/index";
import PickListBoardPage from "./picklists/board";
import AdminPage from "./admin/index";
import AdminDataPage from "./admin/data";
import AdminMergePage from "./admin/merge";

export const router = createBrowserRouter([
  {
    path: "/",
    element: <RootLayout />,
    children: [
      {
        element: <AuthLayout />,
        children: [{ path: "sign-in", element: <SignInPage /> }],
      },
      {
        element: <RequireAuth />,
        children: [
          {
            element: <AppLayout />,
            children: [
              { index: true, element: <DashboardPage /> },

              { path: "pit", element: <PitLandingPage /> },
              { path: "pit/:teamNumber", element: <PitFormPage /> },

              { path: "scout", element: <ScoutLandingPage /> },
              { path: "scout/:matchNumber/:teamNumber", element: <MatchFormPage /> },

              { path: "teams", element: <TeamsPage /> },
              { path: "teams/compare", element: <ComparePage /> },

              { path: "matches", element: <MatchesPage /> },
              { path: "matches/:matchNumber", element: <MatchPreviewPage /> },

              { path: "picklists", element: <PickListsPage /> },
              { path: "picklists/:listId", element: <PickListBoardPage /> },

              {
                element: <RequireAdmin />,
                children: [
                  { path: "admin", element: <AdminPage /> },
                  { path: "admin/data", element: <AdminDataPage /> },
                  { path: "admin/merge", element: <AdminMergePage /> },
                ],
              },
            ],
          },
        ],
      },
      { path: "*", element: <NotFoundPage /> },
    ],
  },
]);
EOF

cat > src/routes/require-auth.tsx <<'EOF'
import { useConvexAuth, useQuery } from "convex/react";
import { LoaderCircle } from "lucide-react";
import { Navigate, Outlet, useLocation } from "react-router";

import { api } from "../../convex/_generated/api";

function FullPageSpinner() {
  return (
    <div className="flex min-h-svh items-center justify-center">
      <LoaderCircle className="text-muted-foreground size-5 animate-spin" />
    </div>
  );
}

export function RequireAuth() {
  const { isLoading, isAuthenticated } = useConvexAuth();
  const location = useLocation();

  if (isLoading) return <FullPageSpinner />;
  if (!isAuthenticated) {
    return <Navigate to="/sign-in" replace state={{ from: location.pathname }} />;
  }
  return <Outlet />;
}

export function RequireAdmin() {
  const profile = useQuery(api.profiles.me);
  if (profile === undefined) return <FullPageSpinner />;
  if (profile?.role !== "admin") return <Navigate to="/" replace />;
  return <Outlet />;
}
EOF

say "Cleanup"
rm -f src/routes/home.tsx src/routes/settings.tsx convex/users.ts

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Phase 0 written.

    bunx convex dev --once          # push schema + functions
    bun run go                      # start everything
    bunx convex run seed:fixtures   # sign in first, then seed fixture data

  The schema is now FROZEN. Changes go through the coordinator, not a track.

DONE
