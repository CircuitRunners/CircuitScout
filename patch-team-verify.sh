#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-team-verify.sh
#   1. The team someone LEAVES gets a dismissable notice in their Scouts list.
#   2. Team numbers are checked against The Blue Alliance before they stick.
#
# SCHEMA CHANGE: teamDepartures table.
#
# Profile creation moves behind an action, because a Convex mutation cannot
# call out to TBA. Verifying on the client alone would be a suggestion, not a
# rule.
#
# REQUIRES: TBA_API_KEY set on the deployment. Without it, nobody can complete
# a profile — the failure is loud on purpose rather than silently letting any
# number through.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/profiles.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema"
cat > /tmp/v1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("teamDepartures")) { console.log("already patched"); process.exit(0); }
const anchor = "  events: defineTable({";
if (!s.includes(anchor)) fail("could not find the events table");
s = s.replace(anchor, `  /** Someone leaving a team, for the team they left. */
  teamDepartures: defineTable({
    profileId: v.id("profiles"),
    displayName: v.string(),
    fromTeamNumber: v.number(),
    toTeamNumber: v.number(),
    at: v.number(),
    dismissed: v.boolean(),
  }).index("by_team_dismissed", ["fromTeamNumber", "dismissed"]),

${anchor}`);
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/v1.mjs

say "Profiles: departures, and ensure becomes internal"
cat > /tmp/v2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/profiles.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("teamDepartures")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { internalQuery, mutation, query } from "./_generated/server";',
  'import {\n  internalMutation, internalQuery, mutation, query,\n} from "./_generated/server";');

// record the departure alongside the join
s = s.replace(`  await ctx.db.insert("teamJoins", {
    profileId, userId, displayName, teamNumber, previousTeamNumber,
    at: Date.now(),
    status: "pending",
  });
}`,
`  await ctx.db.insert("teamJoins", {
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
}`);

// ensure becomes internal; only the verifying action may call it
const oldEnsure = `export const ensure = mutation({
  args: {
    firstName: v.string(),
    lastInitial: v.string(),
    teamNumber: v.number(),
  },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);`;
if (!s.includes(oldEnsure)) fail("could not find profiles.ensure");
s = s.replace(oldEnsure, `/**
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
    const userId = args.userId;`);

s += `
/** Scouts who left this team and have not been acknowledged. */
export const departures = query({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
    const rows = await ctx.db
      .query("teamDepartures")
      .withIndex("by_team_dismissed", (q) => q.eq("dismissed", false))
      .collect();
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
`;
writeFileSync(p, s);
console.log("convex/profiles.ts patched");
MJS
bun /tmp/v2.mjs

say "TBA: verify the team, then write the profile"
cat > /tmp/v3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/tba.ts";
let s = readFileSync(p, "utf8");
if (s.includes("claimProfile")) { console.log("already patched"); process.exit(0); }
s += `
type TbaTeamLookup = { key: string; team_number: number; nickname: string | null };

/**
 * Confirms the team exists on The Blue Alliance, then writes the profile.
 * An action rather than a mutation because a mutation cannot reach the
 * network, and a client-side check would be a suggestion rather than a rule.
 */
export const claimProfile = action({
  args: {
    firstName: v.string(),
    lastInitial: v.string(),
    teamNumber: v.number(),
  },
  handler: async (ctx, args): Promise<{ nickname: string }> => {
    if (!Number.isInteger(args.teamNumber) || args.teamNumber <= 0) {
      throw new Error("Team number must be a whole number.");
    }

    const apiKey = process.env.TBA_API_KEY;
    if (!apiKey) {
      throw new Error(
        "TBA_API_KEY is not set on this deployment, so team numbers cannot be checked. An admin needs to set it.",
      );
    }

    const response = await fetch(\`\${TBA_BASE}/team/frc\${args.teamNumber}\`, {
      headers: { "X-TBA-Auth-Key": apiKey, Accept: "application/json" },
    });
    if (response.status === 404) {
      throw new Error(\`Team \${args.teamNumber} does not exist on The Blue Alliance.\`);
    }
    if (!response.ok) {
      throw new Error(\`Could not check that team number (\${response.status}). Try again.\`);
    }
    const team = (await response.json()) as TbaTeamLookup;

    const userId = await ctx.runQuery(internal.profiles.myUserId, {});
    await ctx.runMutation(internal.profiles.ensureInternal, {
      userId,
      firstName: args.firstName,
      lastInitial: args.lastInitial,
      teamNumber: args.teamNumber,
    });

    return { nickname: team.nickname ?? \`Team \${args.teamNumber}\` };
  },
});
`;
writeFileSync(p, s);
console.log("convex/tba.ts patched");
MJS
bun /tmp/v3.mjs

say "Client: profile setup and edit use the action"
cat > /tmp/v4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

for (const p of ["src/routes/require-auth.tsx", "src/routes/profile.tsx"]) {
  let s = readFileSync(p, "utf8");
  if (s.includes("claimProfile")) { console.log(`${p} already patched`); continue; }
  if (!s.includes("api.profiles.ensure")) { console.log(`${p}: no ensure call`); continue; }

  s = s.replace(/useMutation\b/g, "useAction");
  s = s.replace(/import \{ ([^}]*)useAction([^}]*) \} from "convex\/react";/,
                'import { $1useAction$2 } from "convex/react";');
  s = s.replace("const ensure = useAction(api.profiles.ensure);",
                "const ensure = useAction(api.tba.claimProfile);");
  s = s.replace("const ensure = useMutation(api.profiles.ensure);",
                "const ensure = useAction(api.tba.claimProfile);");

  // surface the confirmed nickname so a typo is obvious before it sticks
  s = s.replace("      await ensure({ firstName, lastInitial, teamNumber: team });",
`      const result = await ensure({ firstName, lastInitial, teamNumber: team });
      toast.success(\`Joined \${result.nickname}\`);`);
  s = s.replace(`      await ensure({ firstName, lastInitial, teamNumber: team });
      toast.success("Profile updated");`,
`      const result = await ensure({ firstName, lastInitial, teamNumber: team });
      toast.success(\`Profile updated · \${result.nickname}\`);`);

  writeFileSync(p, s);
  console.log(`${p} patched`);
}

// require-auth.tsx imports useMutation only for ensure; make sure useAction is imported
let ra = readFileSync("src/routes/require-auth.tsx", "utf8");
if (ra.includes("useAction") && !ra.includes('useAction } from "convex/react"') &&
    !ra.includes("useAction,")) {
  fail("useAction not imported in require-auth.tsx — check the import line");
}
MJS
bun /tmp/v4.mjs

say "Roles table: departure notices"
cat > /tmp/v5.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/roles-table.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("departures")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { TriangleAlert } from "lucide-react";',
              'import { TriangleAlert, UserMinus, X } from "lucide-react";');
s = s.replace("  const resolveJoin = useMutation(api.profiles.resolveJoin);",
`  const resolveJoin = useMutation(api.profiles.resolveJoin);
  const departures = useQuery(api.profiles.departures);
  const dismissDeparture = useMutation(api.profiles.dismissDeparture);`);

const anchor = `        <CardContent className="space-y-2">
          {profiles === undefined ? (`;
if (!s.includes(anchor)) fail("could not find the scouts card body");
s = s.replace(anchor, `        <CardContent className="space-y-2">
          {(departures ?? []).map((row) => (
            <div key={row._id}
              className="bg-muted/50 flex flex-wrap items-center gap-2 rounded-lg border p-3 text-sm">
              <UserMinus className="text-muted-foreground size-4 shrink-0" />
              <span className="min-w-0 flex-1">
                <span className="font-medium">{row.displayName}</span> left for
                team {row.toTeamNumber}. Anything they scouted for you stays.
              </span>
              <Button size="icon" variant="ghost" aria-label="Dismiss"
                onClick={() => void dismissDeparture({ departureId: row._id })}>
                <X className="size-4" />
              </Button>
            </div>
          ))}

          {profiles === undefined ? (`);

writeFileSync(p, s);
console.log("src/routes/admin/roles-table.tsx patched");
MJS
bun /tmp/v5.mjs
rm -f /tmp/v1.mjs /tmp/v2.mjs /tmp/v3.mjs /tmp/v4.mjs /tmp/v5.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
