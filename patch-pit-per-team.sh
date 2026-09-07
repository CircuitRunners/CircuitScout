#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-pit-per-team.sh — pit reports belong to the scouting team.
#
# Match reports stay pooled: several scouts covering one robot is a
# cross-check. Pit reports are one-per-robot by design, so pooling them across
# teams meant the second team to visit a pit silently overwrote the first.
#
# SCHEMA CHANGE: pitReports.scoutingTeamNumber (optional, so rows written
# before this stay valid — they show as belonging to no team until re-saved).
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/pit.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema"
cat > /tmp/p1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("scoutingTeamNumber")) { console.log("already patched"); process.exit(0); }
const anchor = `  pitReports: defineTable({
    eventId: v.id("events"),
    teamId: v.id("teams"),
    scoutId: v.id("users"),`;
if (!s.includes(anchor)) fail("could not find pitReports");
s = s.replace(anchor, `${anchor}
    /** Which FRC team scouted this pit. Optional for rows written before
     *  pit reports were scoped per team. */
    scoutingTeamNumber: v.optional(v.number()),`);
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/p1.mjs

say "Guards: the caller's team number"
cat > /tmp/p2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/lib/guards.ts";
let s = readFileSync(p, "utf8");
if (s.includes("currentTeamNumber")) { console.log("already patched"); process.exit(0); }
s = s.replace("export async function activeEvent(",
`/** The FRC team the caller scouts for. */
export async function currentTeamNumber(
  ctx: QueryCtx | MutationCtx,
): Promise<number | undefined> {
  return effectiveTeamNumber(await currentProfile(ctx));
}

export async function activeEvent(`);
writeFileSync(p, s);
console.log("convex/lib/guards.ts patched");
MJS
bun /tmp/p2.mjs

say "Pit functions (full rewrite)"
cat > convex/pit.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent, currentTeamNumber, requireUser } from "./lib/guards";
import type { Doc, Id } from "./_generated/dataModel";
import type { QueryCtx, MutationCtx } from "./_generated/server";

const scoringInput = v.object({
  turret: v.boolean(),
  drumNonFullWidth: v.boolean(),
  drumFullWidth: v.boolean(),
  fixed: v.boolean(),
  kitbot: v.boolean(),
  other: v.boolean(),
  otherText: v.string(),
});

const climbInput = v.object({
  low: v.boolean(),
  mid: v.boolean(),
  high: v.boolean(),
  duringAuto: v.boolean(),
});

/**
 * One pit report per robot PER SCOUTING TEAM. Two teams at the same
 * competition each keep their own; without this the second team to visit a pit
 * silently overwrote the first.
 */
async function mine(
  ctx: QueryCtx | MutationCtx,
  eventId: Id<"events">,
  teamId: Id<"teams">,
): Promise<Doc<"pitReports"> | null> {
  const scoutingTeamNumber = await currentTeamNumber(ctx);
  if (scoutingTeamNumber === undefined) return null;

  const rows = await ctx.db
    .query("pitReports")
    .withIndex("by_event_team", (q) =>
      q.eq("eventId", eventId).eq("teamId", teamId))
    .collect();
  return rows.find((r) => r.scoutingTeamNumber === scoutingTeamNumber) ?? null;
}

export const get = query({
  args: { teamId: v.id("teams") },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    return await mine(ctx, event._id, args.teamId);
  },
});

/** Resolves a team by number for the /pit/:teamNumber route. */
export const forTeamNumber = query({
  args: { teamNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;

    const team = await ctx.db
      .query("teams")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("number", args.teamNumber))
      .unique();
    if (!team) return null;

    const report = await mine(ctx, event._id, team._id);
    const photoUrl = report?.photoId ? await ctx.storage.getUrl(report.photoId) : null;

    return { team, report, photoUrl };
  },
});

export const generateUploadUrl = mutation({
  args: {},
  handler: async (ctx) => {
    await requireUser(ctx);
    return await ctx.storage.generateUploadUrl();
  },
});

/**
 * A second scout from the same team visiting the same pit updates their team's
 * report rather than creating a duplicate — pits get revisited, and two
 * conflicting reports for one robot is worse than one that changed.
 */
export const upsert = mutation({
  args: {
    teamId: v.id("teams"),
    scoring: scoringInput,
    climb: climbInput,
    drivetrain: v.string(),
    underTrench: v.boolean(),
    overBump: v.boolean(),
    robotNotes: v.string(),
    otherNotes: v.string(),
    photoId: v.union(v.id("_storage"), v.null()),
  },
  handler: async (ctx, args) => {
    const scoutId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const scoutingTeamNumber = await currentTeamNumber(ctx);
    if (scoutingTeamNumber === undefined) {
      throw new Error("Set your team number on your profile first.");
    }

    const team = await ctx.db.get(args.teamId);
    if (!team || team.eventId !== event._id) {
      throw new Error("That team is not part of the active event.");
    }

    const existing = await mine(ctx, event._id, args.teamId);

    const fields = {
      scoring: args.scoring,
      climb: args.climb,
      drivetrain: args.drivetrain,
      underTrench: args.underTrench,
      overBump: args.overBump,
      robotNotes: args.robotNotes,
      otherNotes: args.otherNotes,
      // Keep the old photo when this save did not include a new one.
      photoId: args.photoId ?? existing?.photoId ?? null,
      scoutId,
      scoutingTeamNumber,
      updatedAt: Date.now(),
    };

    if (existing) {
      await ctx.db.patch(existing._id, fields);
      return existing._id;
    }
    return await ctx.db.insert("pitReports", {
      eventId: event._id,
      teamId: args.teamId,
      ...fields,
    });
  },
});
EOF

say "Everywhere else that reads pit reports"
cat > /tmp/p3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

// --- teams.ts: pit status and detail follow the caller's team ---
let t = readFileSync("convex/teams.ts", "utf8");
if (!t.includes("currentTeamNumber")) {
  t = t.replace(/import \{([^}]*)\} from "\.\/lib\/guards";/,
                'import {$1, currentTeamNumber } from "./lib/guards";');
  t = t.replace(`    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const scouted = new Set(pit.map((p) => p.teamId));`,
`    const myTeam = await currentTeamNumber(ctx);
    const pit = (
      await ctx.db
        .query("pitReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect()
    ).filter((p) => p.scoutingTeamNumber === myTeam);
    const scouted = new Set(pit.map((p) => p.teamId));`);

  t = t.replace(`    const pitReport = await ctx.db
      .query("pitReports")
      .withIndex("by_event_team", (q) =>
        q.eq("eventId", event._id).eq("teamId", team._id))
      .unique();`,
`    const myTeam = await currentTeamNumber(ctx);
    const pitReport = (
      await ctx.db
        .query("pitReports")
        .withIndex("by_event_team", (q) =>
          q.eq("eventId", event._id).eq("teamId", team._id))
        .collect()
    ).find((p) => p.scoutingTeamNumber === myTeam) ?? null;`);
  writeFileSync("convex/teams.ts", t);
  console.log("convex/teams.ts patched");
}

// --- stats.coverage: "never pit scouted" is per team ---
let s = readFileSync("convex/stats.ts", "utf8");
if (!s.includes("currentTeamNumber")) {
  s = s.replace(/import \{([^}]*)\} from "\.\/lib\/guards";/,
                'import {$1, currentTeamNumber } from "./lib/guards";');
  const old = `    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", loaded.event._id))
      .collect();
    const pitScouted = new Set(pit.map((p) => p.teamId));`;
  if (!s.includes(old)) fail("could not find the coverage pit query");
  s = s.replace(old, `    const myTeam = await currentTeamNumber(ctx);
    const pit = (
      await ctx.db
        .query("pitReports")
        .withIndex("by_event", (q) => q.eq("eventId", loaded.event._id))
        .collect()
    ).filter((p) => p.scoutingTeamNumber === myTeam);
    const pitScouted = new Set(pit.map((p) => p.teamId));`);
  writeFileSync("convex/stats.ts", s);
  console.log("convex/stats.ts patched");
}

// --- stats.compare: same ---
let s2 = readFileSync("convex/stats.ts", "utf8");
if (s2.includes(`    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", loaded.event._id))
      .collect();
    const scouted = new Set(pit.map((p) => p.teamId));`)) {
  s2 = s2.replace(`    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", loaded.event._id))
      .collect();
    const scouted = new Set(pit.map((p) => p.teamId));`,
`    const myTeamForPit = await currentTeamNumber(ctx);
    const pit = (
      await ctx.db
        .query("pitReports")
        .withIndex("by_event", (q) => q.eq("eventId", loaded.event._id))
        .collect()
    ).filter((p) => p.scoutingTeamNumber === myTeamForPit);
    const scouted = new Set(pit.map((p) => p.teamId));`);
  writeFileSync("convex/stats.ts", s2);
  console.log("convex/stats.ts compare scoped");
}

// --- exports.ts: only your team's pit reports ---
let e = readFileSync("convex/exports.ts", "utf8");
if (!e.includes("currentTeamNumber")) {
  e = e.replace(/import \{([^}]*)\} from "\.\/lib\/guards";/,
                'import {$1, currentTeamNumber } from "./lib/guards";');
  e = e.replace(`      const pit = await ctx.db
        .query("pitReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();`,
`      const myTeam = await currentTeamNumber(ctx);
      const pit = (
        await ctx.db
          .query("pitReports")
          .withIndex("by_event", (q) => q.eq("eventId", event._id))
          .collect()
      ).filter((p) => p.scoutingTeamNumber === myTeam);`);
  writeFileSync("convex/exports.ts", e);
  console.log("convex/exports.ts patched");
}

// --- admin.ts: pit report management is already scoped by the writing scout,
//     but scope on the report's own team so a reassigned scout cannot orphan it
let a = readFileSync("convex/admin.ts", "utf8");
if (!a.includes("report.scoutingTeamNumber")) {
  a = a.replace(`      if (!managesTeam(me, profileByUser.get(report.scoutId)?.teamNumber)) continue;
      const team = await ctx.db.get(report.teamId);`,
`      if (!managesTeam(me, report.scoutingTeamNumber)) continue;
      const team = await ctx.db.get(report.teamId);`);
  writeFileSync("convex/admin.ts", a);
  console.log("convex/admin.ts patched");
}
MJS
bun /tmp/p3.mjs
rm -f /tmp/p1.mjs /tmp/p2.mjs /tmp/p3.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Pit reports are now per scouting team. Match reports stay pooled.

  Rows written before this have no scoutingTeamNumber, so they belong to
  nobody and will not appear for any team. Re-save them, or set the field in
  the Convex dashboard.

DONE
