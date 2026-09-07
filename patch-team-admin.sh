#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-team-admin.sh — split admin into admin and team admin.
#
#   admin       full control, including granting roles and running the event
#   teamAdmin   their own FRC team's data only
#   scout       unchanged
#
# Each FRC team now gets its own primary pick list, and the merge is scoped to
# the acting person's team.
#
# SCHEMA CHANGE: profiles.role gains "teamAdmin"; pickLists.teamNumber and
# deletionLog.teamNumber added (both optional).
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/lib/guards.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema"
cat > /tmp/t1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes('v.literal("teamAdmin")')) { console.log("already patched"); process.exit(0); }

const role = `    role: v.union(v.literal("admin"), v.literal("scout")),`;
if (!s.includes(role)) fail("could not find profiles.role");
s = s.replace(role,
`    role: v.union(v.literal("admin"), v.literal("teamAdmin"), v.literal("scout")),`);

const lists = `  pickLists: defineTable({
    eventId: v.id("events"),
    ownerId: v.union(v.id("users"), v.null()),   // null = team primary`;
if (!s.includes(lists)) fail("could not find pickLists");
s = s.replace(lists, `  pickLists: defineTable({
    eventId: v.id("events"),
    ownerId: v.union(v.id("users"), v.null()),   // null = a team's primary
    // Which FRC team this list belongs to. Optional so lists created before
    // multi-team support still validate.
    teamNumber: v.optional(v.number()),`);

s = s.replace("    reason: v.string(),\n    snapshot: v.string(),",
              "    reason: v.string(),\n    snapshot: v.string(),\n    teamNumber: v.optional(v.number()),");

writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/t1.mjs

say "Guards"
cat > /tmp/t2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/lib/guards.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("requireTeamAdmin")) { console.log("already patched"); process.exit(0); }

const old = `export async function requireAdmin(ctx: QueryCtx | MutationCtx): Promise<Doc<"profiles">> {
  const profile = await currentProfile(ctx);
  if (!profile) throw new Error("No profile for this user.");
  if (profile.role !== "admin") throw new Error("Admins only.");
  return profile;
}`;
if (!s.includes(old)) fail("could not find requireAdmin");
s = s.replace(old, `/** Full admin. Roles, events, and anything spanning more than one team. */
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
}`);
writeFileSync(p, s);
console.log("convex/lib/guards.ts patched");
MJS
bun /tmp/t2.mjs

say "Profiles"
cat > /tmp/t3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/profiles.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("requireTeamAdmin")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { currentProfile, requireAdmin, requireUser } from "./lib/guards";',
  'import {\n  currentProfile, managesTeam, requireAdmin, requireTeamAdmin, requireUser,\n} from "./lib/guards";');

const oldList = `export const list = query({
  args: {},
  handler: async (ctx) => {
    await requireAdmin(ctx);
    return await ctx.db.query("profiles").collect();
  },
});`;
if (!s.includes(oldList)) fail("could not find profiles.list");
s = s.replace(oldList, `export const list = query({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
    const all = await ctx.db.query("profiles").collect();
    if (me.role === "admin") return all;
    // A team admin sees only their own scouts.
    return all.filter((p) => p.teamNumber === me.teamNumber);
  },
});`);

const oldRole = `export const setRole = mutation({
  args: {
    profileId: v.id("profiles"),
    role: v.union(v.literal("admin"), v.literal("scout")),
  },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    await ctx.db.patch(args.profileId, { role: args.role });
  },
});`;
if (!s.includes(oldRole)) fail("could not find setRole");
s = s.replace(oldRole, `/** Roles are a full-admin decision. A team admin cannot mint another. */
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
});`);

const oldTier = `export const setWeightTier = mutation({
  args: {
    profileId: v.id("profiles"),
    weightTier: v.union(v.literal("lead"), v.literal("trusted"), v.literal("normal")),
  },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    await ctx.db.patch(args.profileId, { weightTier: args.weightTier });
  },
});`;
if (!s.includes(oldTier)) fail("could not find setWeightTier");
s = s.replace(oldTier, `/** Trust level is a team admin's call for their own scouts. */
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
});`);

writeFileSync(p, s);
console.log("convex/profiles.ts patched");
MJS
bun /tmp/t3.mjs

say "Pick lists: one primary per team"
cat > /tmp/t4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/pickLists.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("myTeamNumber")) { console.log("already patched"); process.exit(0); }

s = s.replace(/import \{[\s\S]*?\} from "\.\/lib\/guards";/,
  'import {\n  activeEvent, currentProfile, managesTeam, requireTeamAdmin, requireUser,\n} from "./lib/guards";');

// primary: the caller's own team's list
const oldPrimary = s.slice(s.indexOf("export const primary = query({"), s.indexOf("/** Everyone's submitted lists"));
if (!oldPrimary) fail("could not find pickLists.primary");
s = s.replace(oldPrimary, `/** The primary list belongs to an FRC team, not to the event. */
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

`);

// submitted: scope to the caller's team
s = s.replace(`    await requireAdmin(ctx);

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event_submitted", (q) =>
        q.eq("eventId", event._id).eq("isSubmitted", true))
      .collect();`,
`    const me = await requireTeamAdmin(ctx);

    const all = await ctx.db
      .query("pickLists")
      .withIndex("by_event_submitted", (q) =>
        q.eq("eventId", event._id).eq("isSubmitted", true))
      .collect();`);
s = s.replace(`    return lists.flatMap((list) => {
      if (list.ownerId === null) return [];
      const profile = byUser.get(list.ownerId);
      return [{`,
`    return all.flatMap((list) => {
      if (list.ownerId === null) return [];
      const profile = byUser.get(list.ownerId);
      if (!managesTeam(me, profile?.teamNumber)) return [];
      return [{`);

// personal lists carry the owner's team so the merge can scope them
s = s.replace(`    const listId = await ctx.db.insert("pickLists", {
      eventId: event._id,
      ownerId: userId,
      name,`,
`    const profile = await currentProfile(ctx);
    const listId = await ctx.db.insert("pickLists", {
      eventId: event._id,
      ownerId: userId,
      teamNumber: profile?.teamNumber,
      name,`);

// ensurePrimary / populatePrimary are per team
s = s.replace(`export const ensurePrimary = mutation({
  args: {},
  handler: async (ctx) => {
    await requireAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const existing = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", null))
      .first();
    if (existing) return existing._id;

    return await ctx.db.insert("pickLists", {
      eventId: event._id,
      ownerId: null,
      name: "Team primary list",`,
`export const ensurePrimary = mutation({
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
    if (existing) return existing._id;

    return await ctx.db.insert("pickLists", {
      eventId: event._id,
      ownerId: null,
      teamNumber: me.teamNumber,
      name: \`Team \${me.teamNumber} primary list\`,`);

s = s.replace(`export const populatePrimary = mutation({
  args: {},
  handler: async (ctx) => {
    await requireAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const list = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", null))
      .first();
    if (!list) throw new Error("There is no primary list yet.");`,
`export const populatePrimary = mutation({
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
    if (!list) throw new Error("There is no primary list for your team yet.");`);

// editing a primary list is now a team-scoped question
s = s.replace(`  if (list.ownerId === null) {
    if (!isAdmin) throw new Error("Only an admin can edit the primary list.");
  } else if (list.ownerId !== userId) {`,
`  if (list.ownerId === null) {
    if (!isAdmin) throw new Error("Only your team's admin can edit the primary list.");
  } else if (list.ownerId !== userId) {`);

if (s.includes("requireAdmin")) {
  s = s.replace(/requireAdmin\(ctx\)/g, "requireTeamAdmin(ctx)");
}

writeFileSync(p, s);
console.log("convex/pickLists.ts patched");
MJS
bun /tmp/t4.mjs

say "Merge: scoped to the acting team"
cat > /tmp/t5.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/merge.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("requireTeamAdmin")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { activeEvent, requireAdmin } from "./lib/guards";',
  'import { activeEvent, managesTeam, requireTeamAdmin } from "./lib/guards";');

s = s.replace("async function build(ctx: QueryCtx | MutationCtx) {",
`async function build(ctx: QueryCtx | MutationCtx, actor: { role: string; teamNumber?: number }) {`);

// only this team's scouts vote
s = s.replace(`  for (const list of lists) {
    if (list.ownerId === null) continue;
    const profile = byUser.get(list.ownerId);
    const voter = profile?.displayName ?? "Unknown scout";`,
`  for (const list of lists) {
    if (list.ownerId === null) continue;
    const profile = byUser.get(list.ownerId);
    // A team's merge reads its own scouts' lists and nobody else's.
    if (actor.role !== "admin" && profile?.teamNumber !== actor.teamNumber) continue;
    const voter = profile?.displayName ?? "Unknown scout";`);

// and only this team's people count as "not submitted"
s = s.replace(`  const missing = profiles
    .map((p) => p.displayName)
    .filter((name) => !submittedNames.has(name));`,
`  const missing = profiles
    .filter((p) => actor.role === "admin" || p.teamNumber === actor.teamNumber)
    .map((p) => p.displayName)
    .filter((name) => !submittedNames.has(name));`);

s = s.replace(`    await requireAdmin(ctx);
    const built = await build(ctx);
    if (!built) return { rows: [], submitters: [], missing: [], targets: null };`,
`    const me = await requireTeamAdmin(ctx);
    const built = await build(ctx, me);
    if (!built) return { rows: [], submitters: [], missing: [], targets: null };`);

s = s.replace(`    await requireAdmin(ctx);
    const built = await build(ctx);
    if (!built) throw new Error("No active event.");`,
`    const me = await requireTeamAdmin(ctx);
    const built = await build(ctx, me);
    if (!built) throw new Error("No active event.");`);

const oldPrimary = `    const primary = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", built.event._id).eq("ownerId", null))
      .first();
    if (!primary) throw new Error("There is no primary list yet.");`;
if (!s.includes(oldPrimary)) fail("could not find the primary lookup in merge");
s = s.replace(oldPrimary, `    const primaries = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", built.event._id).eq("ownerId", null))
      .collect();
    const primary = primaries.find((l) => managesTeam(me, l.teamNumber));
    if (!primary) throw new Error("There is no primary list for your team yet.");`);

writeFileSync(p, s);
console.log("convex/merge.ts patched");
MJS
bun /tmp/t5.mjs

say "Admin reports: team scope"
cat > /tmp/t6.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/admin.ts";
let s = readFileSync(p, "utf8");
if (s.includes("requireTeamAdmin")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { activeEvent, requireAdmin, requireUser } from "./lib/guards";',
  'import {\n  activeEvent, managesTeam, requireAdmin, requireTeamAdmin, requireUser,\n} from "./lib/guards";');

// every admin-facing read and write becomes team-scoped
// Order matters: park the assigned form first, or the global replace turns
// `const admin = await requireAdmin(ctx)` into `const admin = const me = ...`.
s = s.split("const admin = await requireAdmin(ctx);").join("__ADMIN_CALL__");
s = s.replace(/await requireAdmin\(ctx\);/g, "const me = await requireTeamAdmin(ctx);");
s = s.split("__ADMIN_CALL__").join("const admin = await requireTeamAdmin(ctx);");

// reports: filter to scouts this person manages
s = s.replace(`    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    const allDismissals`,
`    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));
    const profileByUser = new Map(profiles.map((p) => [p.userId, p]));

    const allDismissals`);
s = s.replace(`    const rows: Row[] = [];
    for (const report of all) {`,
`    const rows: Row[] = [];
    for (const report of all) {
      // A team admin only sees what their own scouts wrote.
      if (!managesTeam(me, profileByUser.get(report.scoutId)?.teamNumber)) continue;`);

// pit reports
s = s.replace(`    const rows = [];
    for (const report of reports) {
      const team = await ctx.db.get(report.teamId);
      if (!team) continue;`,
`    const profileByUser = new Map(profiles.map((p) => [p.userId, p]));
    const rows = [];
    for (const report of reports) {
      if (!managesTeam(me, profileByUser.get(report.scoutId)?.teamNumber)) continue;
      const team = await ctx.db.get(report.teamId);
      if (!team) continue;`);

// deletions carry the team so the log can be scoped
s = s.replace(`      deletedBy: admin.userId,
      deletedAt: Date.now(),
      reason,
      snapshot: JSON.stringify(report),
    });

    const edits`,
`      deletedBy: admin.userId,
      deletedAt: Date.now(),
      reason,
      snapshot: JSON.stringify(report),
      teamNumber: admin.teamNumber,
    });

    const edits`);
s = s.replace(`      deletedBy: admin.userId,
      deletedAt: Date.now(),
      reason,
      snapshot: JSON.stringify(report),
    });

    await ctx.db.delete(args.pitReportId);`,
`      deletedBy: admin.userId,
      deletedAt: Date.now(),
      reason,
      snapshot: JSON.stringify(report),
      teamNumber: admin.teamNumber,
    });

    await ctx.db.delete(args.pitReportId);`);

s = s.replace(`    return rows
      .map((r) => ({ ...r, deletedByName: nameByUser.get(r.deletedBy) ?? "Unknown" }))
      .sort((a, b) => b.deletedAt - a.deletedAt);`,
`    return rows
      .filter((r) => managesTeam(me, r.teamNumber))
      .map((r) => ({ ...r, deletedByName: nameByUser.get(r.deletedBy) ?? "Unknown" }))
      .sort((a, b) => b.deletedAt - a.deletedAt);`);

writeFileSync(p, s);
console.log("convex/admin.ts patched");
MJS
bun /tmp/t6.mjs

say "Client: role types and gates"
cat > /tmp/t7.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

// types
let t = readFileSync("convex/lib/types.ts", "utf8");
if (!t.includes('"teamAdmin"')) {
  t = t.replace('export type Role = "admin" | "scout";',
                'export type Role = "admin" | "teamAdmin" | "scout";');
  writeFileSync("convex/lib/types.ts", t);
  console.log("convex/lib/types.ts patched");
}

// route guard: team admins reach the admin area too
let g = readFileSync("src/routes/require-auth.tsx", "utf8");
if (!g.includes("teamAdmin")) {
  const old = `  if (profile?.role !== "admin") return <Navigate to="/" replace />;`;
  if (!g.includes(old)) fail("could not find the RequireAdmin check");
  g = g.replace(old, `  if (profile?.role !== "admin" && profile?.role !== "teamAdmin") {
    return <Navigate to="/" replace />;
  }`);
  writeFileSync("src/routes/require-auth.tsx", g);
  console.log("src/routes/require-auth.tsx patched");
}

// nav
let n = readFileSync("src/components/app-nav.tsx", "utf8");
if (!n.includes("teamAdmin")) {
  const old = `  const items = NAV.filter((i) => !i.adminOnly || profile?.role === "admin");`;
  if (!n.includes(old)) fail("could not find the nav filter");
  n = n.replace(old, `  const items = NAV.filter(
    (i) => !i.adminOnly || profile?.role === "admin" || profile?.role === "teamAdmin",
  );`);
  writeFileSync("src/components/app-nav.tsx", n);
  console.log("src/components/app-nav.tsx patched");
}

// pick lists page: any admin type manages the primary list
let pl = readFileSync("src/routes/picklists/index.tsx", "utf8");
if (!pl.includes("isAnyAdmin")) {
  pl = pl.replace("  const [name, setName] = useState(\"\");",
`  const isAnyAdmin = profile?.role === "admin" || profile?.role === "teamAdmin";

  const [name, setName] = useState("");`);
  pl = pl.replace(/profile\?\.role === "admin"/g, "isAnyAdmin");
  pl = pl.replace(/profile\?\.role !== "admin"/g, "!isAnyAdmin");
  writeFileSync("src/routes/picklists/index.tsx", pl);
  console.log("src/routes/picklists/index.tsx patched");
}

// admin page: event setup stays full-admin only
let ap = readFileSync("src/routes/admin/index.tsx", "utf8");
if (!ap.includes("isFullAdmin")) {
  ap = ap.replace("  const [eventKey, setEventKey] = useState(\"\");",
`  const me = useQuery(api.profiles.me);
  const isFullAdmin = me?.role === "admin";

  const [eventKey, setEventKey] = useState("");`);
  const importCard = ap.indexOf("      <Card>\n        <CardHeader>\n          <CardTitle>Import an event</CardTitle>");
  const eventsCard = ap.indexOf("      <RolesTable />");
  if (importCard === -1 || eventsCard === -1) fail("could not find the admin cards");
  const block = ap.slice(importCard, eventsCard);
  ap = ap.slice(0, importCard) +
    "      {isFullAdmin ? (\n        <>\n" + block + "        </>\n      ) : null}\n\n" +
    ap.slice(eventsCard);
  writeFileSync("src/routes/admin/index.tsx", ap);
  console.log("src/routes/admin/index.tsx patched");
}

// roles table
let rt = readFileSync("src/routes/admin/roles-table.tsx", "utf8");
if (!rt.includes("teamAdmin")) {
  rt = rt.replace(`const ROLES: ReadonlyArray<{ value: Role; label: string }> = [
  { value: "scout", label: "Scout" },
  { value: "admin", label: "Admin" },
];`,
`const ROLES: ReadonlyArray<{ value: Role; label: string }> = [
  { value: "scout", label: "Scout" },
  { value: "teamAdmin", label: "Team admin" },
  { value: "admin", label: "Admin" },
];`);
  rt = rt.replace("  const adminCount = profiles?.filter((p) => p.role === \"admin\").length ?? 0;",
`  const adminCount = profiles?.filter((p) => p.role === "admin").length ?? 0;
  // Only a full admin grants roles. A team admin sets trust levels for their
  // own scouts and nothing else.
  const canSetRoles = me?.role === "admin";`);
  rt = rt.replace(`                <div className="flex gap-1">
                  {ROLES.map((r) => (`,
`                {canSetRoles ? (
                <div className="flex gap-1">
                  {ROLES.map((r) => (`);
  rt = rt.replace(`                  ))}
                </div>

                <div className="flex gap-1">
                  {TIERS.map((t) => (`,
`                  ))}
                </div>
                ) : null}

                <div className="flex gap-1">
                  {TIERS.map((t) => (`);
  rt = rt.replace(`          Weighting applies to the pick list merge:`,
`          Trust level is yours to set for your own scouts. Roles are granted by
          a full admin. Weighting applies to the pick list merge:`);
  writeFileSync("src/routes/admin/roles-table.tsx", rt);
  console.log("src/routes/admin/roles-table.tsx patched");
}

// profile page label
let pp = readFileSync("src/routes/profile.tsx", "utf8");
if (!pp.includes("Team admin")) {
  pp = pp.replace(`            {profile?.role === "admin" ? "Admin" : "Scout"}`,
`            {profile?.role === "admin"
              ? "Admin"
              : profile?.role === "teamAdmin"
                ? "Team admin"
                : "Scout"}`);
  writeFileSync("src/routes/profile.tsx", pp);
  console.log("src/routes/profile.tsx patched");
}
MJS
bun /tmp/t7.mjs
rm -f /tmp/t1.mjs /tmp/t2.mjs /tmp/t3.mjs /tmp/t4.mjs /tmp/t5.mjs /tmp/t6.mjs /tmp/t7.mjs

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
