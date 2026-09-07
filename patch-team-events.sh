#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-team-events.sh — per-team active events (items 1-4).
#
#   1. Team admins can import events.
#   2. Each FRC team has its own active event.
#   3. Team admins set their own team's active event.
#   4. Full admins set any team's.
#
# SCHEMA CHANGE: teamSettings table. events.isActive stays in the schema but is
# no longer read — one global flag cannot express "active for team 1002".
#
# MIGRATION: after this, every team must pick an active event before the app
# shows them anything. There is no way to infer it from the old global flag,
# because it never recorded whose event it was.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/lib/guards.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema"
cat > /tmp/e1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("teamSettings")) { console.log("already patched"); process.exit(0); }
const anchor = "  teams: defineTable({";
if (!s.includes(anchor)) fail("could not find the teams table");
s = s.replace(anchor, `  /**
   * Which event each FRC team is currently scouting. Teams share the pool of
   * imported events but choose independently — two teams at different
   * competitions use one deployment without stepping on each other.
   */
  teamSettings: defineTable({
    teamNumber: v.number(),
    activeEventId: v.union(v.id("events"), v.null()),
    updatedAt: v.number(),
    updatedBy: v.id("users"),
  }).index("by_team", ["teamNumber"]),

${anchor}`);
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/e1.mjs

say "Guards: active event follows the caller's team"
cat > /tmp/e2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/lib/guards.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("effectiveTeamNumber")) { console.log("already patched"); process.exit(0); }

const old = s.slice(
  s.indexOf('/** The single active event. Returns null before an event has been set up. */'),
  s.indexOf("export async function requireActiveEvent("),
);
const fallback = s.slice(
  s.indexOf("export async function activeEvent("),
  s.indexOf("export async function requireActiveEvent("),
);
const target = old || fallback;
if (!target) fail("could not find activeEvent");

s = s.replace(target, `/** The team whose data the caller is working with. */
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
  return await ctx.db.get(settings.activeEventId);
}

`);
writeFileSync(p, s);
console.log("convex/lib/guards.ts patched");
MJS
bun /tmp/e2.mjs

say "Events: per-team activation, team admins may import"
cat > /tmp/e3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

let s = readFileSync("convex/events.ts", "utf8");
if (s.includes("setActiveForTeam")) { console.log("events.ts already patched"); process.exit(0); }

s = s.replace(/import \{[^}]*\} from "\.\/lib\/guards";/,
  'import {\n  activeEvent, activeEventForTeam, currentProfile, managesTeam,\n  requireAdmin, requireTeamAdmin,\n} from "./lib/guards";');

// list gains which teams have each event active
s = s.replace(`      withCounts.push({
        ...event,`,
`      const settings = (await ctx.db.query("teamSettings").collect())
        .filter((t) => t.activeEventId === event._id)
        .map((t) => t.teamNumber)
        .sort((a, b) => a - b);

      withCounts.push({
        ...event,
        activeForTeams: settings,`);

// replace the old global setActive / setInactive
const oldSet = s.slice(s.indexOf("export const setActive = mutation({"), s.indexOf("const teamInput = v.object({"));
if (!oldSet) fail("could not find setActive");
s = s.replace(oldSet, `/**
 * Points one team at one event. A full admin can do this for any team; a team
 * admin only for their own.
 */
export const setActiveForTeam = mutation({
  args: { eventId: v.union(v.id("events"), v.null()), teamNumber: v.number() },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    if (!managesTeam(me, args.teamNumber)) {
      throw new Error("That is not your team.");
    }

    const existing = await ctx.db
      .query("teamSettings")
      .withIndex("by_team", (q) => q.eq("teamNumber", args.teamNumber))
      .unique();

    if (existing) {
      await ctx.db.patch(existing._id, {
        activeEventId: args.eventId,
        updatedAt: Date.now(),
        updatedBy: me.userId,
      });
      return existing._id;
    }
    return await ctx.db.insert("teamSettings", {
      teamNumber: args.teamNumber,
      activeEventId: args.eventId,
      updatedAt: Date.now(),
      updatedBy: me.userId,
    });
  },
});

/** Every team's current choice. Scoped for team admins, full for admins. */
export const teamSettings = query({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
    const rows = await ctx.db.query("teamSettings").collect();
    const events = await ctx.db.query("events").collect();
    const byId = new Map(events.map((e) => [e._id, e]));

    return rows
      .filter((row) => managesTeam(me, row.teamNumber))
      .map((row) => ({
        teamNumber: row.teamNumber,
        eventName: row.activeEventId ? (byId.get(row.activeEventId)?.name ?? null) : null,
        eventKey: row.activeEventId ? (byId.get(row.activeEventId)?.tbaEventKey ?? null) : null,
        activeEventId: row.activeEventId,
      }))
      .sort((a, b) => a.teamNumber - b.teamNumber);
  },
});

/** My team's current event, for the header and the dashboard. */
export const myTeamActive = query({
  args: {},
  handler: async (ctx) => {
    const profile = await currentProfile(ctx);
    if (!profile?.teamNumber) return null;
    const event = await activeEventForTeam(ctx, profile.teamNumber);
    return event ? { ...event, teamNumber: profile.teamNumber } : null;
  },
});

`);

// event creation opens up to team admins
s = s.replace(`  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const existing = await ctx.db
      .query("events")
      .withIndex("by_key", (q) => q.eq("tbaEventKey", args.tbaEventKey))`,
`  handler: async (ctx, args) => {
    await requireTeamAdmin(ctx);
    const existing = await ctx.db
      .query("events")
      .withIndex("by_key", (q) => q.eq("tbaEventKey", args.tbaEventKey))`);

// removal stays a full-admin action, and must not yank an event out from
// under another team
s = s.replace(`    await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) throw new Error("That event no longer exists.");

    const reports = await ctx.db`,
`    await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) throw new Error("That event no longer exists.");

    const usedBy = (await ctx.db.query("teamSettings").collect())
      .filter((t) => t.activeEventId === args.eventId)
      .map((t) => t.teamNumber);
    if (usedBy.length > 0) {
      throw new Error(
        \`Team \${usedBy.join(", ")} still has that event active. They have to switch first.\`,
      );
    }

    const reports = await ctx.db`);

writeFileSync("convex/events.ts", s);
console.log("convex/events.ts patched");
MJS
bun /tmp/e3.mjs

say "TBA import: team admins"
cat > /tmp/e4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
let s = readFileSync("convex/profiles.ts", "utf8");
if (s.includes("a team admin's job now")) { console.log("already patched"); process.exit(0); }
s = s.replace(`export const adminUserId = internalQuery({
  args: {},
  handler: async (ctx) => {
    const profile = await requireAdmin(ctx);
    return profile.userId;
  },
});`,
`export const adminUserId = internalQuery({
  args: {},
  handler: async (ctx) => {
    // Importing an event is a team admin's job now, so this no longer demands
    // a full admin. Named as it was to avoid churning tba.ts.
    const profile = await requireTeamAdmin(ctx);
    return profile.userId;
  },
});
`);
writeFileSync("convex/profiles.ts", s);
console.log("convex/profiles.ts patched");
MJS
bun /tmp/e4.mjs
rm -f /tmp/e1.mjs /tmp/e2.mjs /tmp/e3.mjs /tmp/e4.mjs

say "Admin UI: per-team active event"
cat > /tmp/e5.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/index.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("setActiveForTeam")) { console.log("already patched"); process.exit(0); }

s = s.replace("  const setActive = useMutation(api.events.setActive);",
`  const setActiveForTeam = useMutation(api.events.setActiveForTeam);
  const settings = useQuery(api.events.teamSettings);`);
s = s.replace("  const setInactive = useMutation(api.events.setInactive);\n", "");

// Full admins pick which team they are configuring; team admins have one.
s = s.replace("  const [eventKey, setEventKey] = useState(\"\");",
`  const [teamFor, setTeamFor] = useState<number | null>(null);
  const targetTeam = isFullAdmin ? teamFor : (me?.teamNumber ?? null);

  const [eventKey, setEventKey] = useState("");`);

// `{event.isActive ? (` appears twice — badge and buttons — so match the whole
// button block exactly rather than slicing from the first occurrence.
const oldRow = `                {event.isActive ? (
                  <Button variant="outline" size="sm"
                    onClick={() => void setInactive({ eventId: event._id })}>
                    Set inactive
                  </Button>
                ) : (
                  <Button variant="outline" size="sm"
                    onClick={() => void setActive({ eventId: event._id })}>
                    Set active
                  </Button>
                )}
`;
if (!s.includes(oldRow)) fail("could not find the activation buttons");
s = s.replace(oldRow, `                {targetTeam === null ? (
                  <span className="text-muted-foreground text-xs">
                    Pick a team below
                  </span>
                ) : event.activeForTeams?.includes(targetTeam) ? (
                  <Button variant="outline" size="sm"
                    onClick={() => void setActiveForTeam({
                      eventId: null, teamNumber: targetTeam,
                    })}>
                    Stand down for {targetTeam}
                  </Button>
                ) : (
                  <Button variant="outline" size="sm"
                    onClick={() => void setActiveForTeam({
                      eventId: event._id, teamNumber: targetTeam,
                    })}>
                    Activate for {targetTeam}
                  </Button>
                )}
`);

s = s.replace(`                    {event.isActive ? (
                      <Badge>
                        <CheckCircle2 className="size-3" />
                        Active
                      </Badge>
                    ) : null}`,
`                    {(event.activeForTeams ?? []).length > 0 ? (
                      <Badge>
                        <CheckCircle2 className="size-3" />
                        Active for {(event.activeForTeams ?? []).join(", ")}
                      </Badge>
                    ) : null}`);

s = s.replace(`            One event is active at a time and everything reads from it. Setting
            an event inactive changes nothing about its data — it just stops the
            app pointing at it.`,
`            Every team picks its own event from this shared pool, so two teams
            at different competitions can use one deployment. Standing an event
            down changes nothing about its data.`);

// team selector for full admins
s = s.replace("      <RolesTable />",
`      {isFullAdmin ? (
        <Card>
          <CardHeader>
            <CardTitle>Configuring for</CardTitle>
            <CardDescription>
              Which team the activation buttons above apply to.
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap items-center gap-2">
            {(settings ?? []).map((row) => (
              <Button key={row.teamNumber} size="sm"
                variant={targetTeam === row.teamNumber ? "default" : "outline"}
                onClick={() => setTeamFor(row.teamNumber)}>
                {row.teamNumber}
                <span className="text-muted-foreground ml-1 text-xs">
                  {row.eventKey ?? "none"}
                </span>
              </Button>
            ))}
            {me?.teamNumber !== undefined &&
             !(settings ?? []).some((r) => r.teamNumber === me.teamNumber) ? (
              <Button size="sm"
                variant={targetTeam === me.teamNumber ? "default" : "outline"}
                onClick={() => setTeamFor(me.teamNumber ?? null)}>
                {me.teamNumber} (yours)
              </Button>
            ) : null}
            {(settings ?? []).length === 0 && me?.teamNumber === undefined ? (
              <p className="text-muted-foreground text-sm">
                No team has chosen an event yet.
              </p>
            ) : null}
          </CardContent>
        </Card>
      ) : null}

      <RolesTable />`);

writeFileSync(p, s);
console.log("src/routes/admin/index.tsx patched");
MJS
bun /tmp/e5.mjs
rm -f /tmp/e5.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Done. Every team must now pick an active event before the app shows it
  anything — the old global flag could not say whose event it was.

DONE
