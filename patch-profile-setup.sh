#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-profile-setup.sh
#   New accounts must supply first name, last initial and team number before
#   they can use the app. Existing accounts are prompted too, so nobody is
#   left as "Scout".
#
# SCHEMA CHANGE: profiles gains firstName, lastInitial, teamNumber (optional,
# so accounts created before this stay valid until they fill the form in).
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/profiles.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema"
cat > /tmp/ps1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
if (s.includes("lastInitial")) { console.log("already present"); process.exit(0); }
const anchor = "    displayName: v.string(),";
if (!s.includes(anchor)) { console.error("could not find profiles.displayName"); process.exit(1); }
s = s.replace(anchor, `    displayName: v.string(),   // derived: "Sandy A. (1002)"
    firstName: v.optional(v.string()),
    lastInitial: v.optional(v.string()),
    teamNumber: v.optional(v.number()),`);
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/ps1.mjs

say "Convex: profile creation"
cat > /tmp/ps2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/profiles.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("lastInitial")) { console.log("already patched"); process.exit(0); }

const start = s.indexOf("export const ensure = mutation({");
const end = s.indexOf("export const setRole = mutation({");
if (start === -1 || end === -1) fail("could not find profiles.ensure");

s = s.slice(0, start) + `function validate(args: {
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
    displayName: \`\${firstName} \${lastInitial}. (\${args.teamNumber})\`,
  };
}

/**
 * Creates or completes the caller's profile. The first profile in an empty
 * deployment becomes an admin; everyone after is a scout until promoted.
 */
export const ensure = mutation({
  args: {
    firstName: v.string(),
    lastInitial: v.string(),
    teamNumber: v.number(),
  },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const fields = validate(args);

    const existing = await ctx.db
      .query("profiles")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .unique();

    if (existing) {
      await ctx.db.patch(existing._id, fields);
      return existing._id;
    }

    const anyProfile = await ctx.db.query("profiles").first();
    return await ctx.db.insert("profiles", {
      userId,
      ...fields,
      role: anyProfile === null ? "admin" : "scout",
      weightTier: "normal",
      createdAt: Date.now(),
    });
  },
});

` + s.slice(end);

writeFileSync(p, s);
console.log("convex/profiles.ts patched");
MJS
bun /tmp/ps2.mjs

say "Client: profile setup gate"
cat > src/routes/require-auth.tsx <<'EOF'
import { useConvexAuth, useMutation, useQuery } from "convex/react";
import { LoaderCircle } from "lucide-react";
import { useState } from "react";
import { Navigate, Outlet, useLocation } from "react-router";
import { toast } from "sonner";

import { api } from "../../convex/_generated/api";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

function FullPageSpinner() {
  return (
    <div className="flex min-h-svh items-center justify-center">
      <LoaderCircle className="text-muted-foreground size-5 animate-spin" />
    </div>
  );
}

/**
 * Reports are attributed by name across the whole app — the flagged list, the
 * per-scout coverage table, the edit trail. An anonymous account makes all of
 * that useless, so this is a gate rather than a prompt.
 */
function ProfileSetup({ existingName }: { existingName: string | null }) {
  const ensure = useMutation(api.profiles.ensure);
  const [firstName, setFirstName] = useState("");
  const [lastInitial, setLastInitial] = useState("");
  const [teamNumber, setTeamNumber] = useState("");
  const [busy, setBusy] = useState(false);

  const team = Number.parseInt(teamNumber, 10);
  const ready =
    firstName.trim() !== "" &&
    /^[A-Za-z]$/.test(lastInitial.trim()) &&
    Number.isInteger(team) &&
    team > 0;

  const save = async () => {
    setBusy(true);
    try {
      await ensure({ firstName, lastInitial, teamNumber: team });
    } catch (error) {
      toast.error("Could not save", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="flex min-h-svh items-center justify-center p-6">
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle>Who are you?</CardTitle>
          <CardDescription>
            {existingName
              ? "Your account predates this step — fill it in once and you are done."
              : "Every report you submit is attributed to this, so your strategy lead knows who saw what."}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="first-name">First name</Label>
            <Input id="first-name" autoComplete="given-name" value={firstName}
              onChange={(e) => setFirstName(e.target.value)} />
          </div>
          <div className="space-y-2">
            <Label htmlFor="last-initial">Last initial</Label>
            <Input id="last-initial" maxLength={1} className="w-20"
              value={lastInitial}
              onChange={(e) => setLastInitial(e.target.value)} />
          </div>
          <div className="space-y-2">
            <Label htmlFor="team-number">Your team number</Label>
            <Input id="team-number" inputMode="numeric" placeholder="1002"
              value={teamNumber}
              onChange={(e) => setTeamNumber(e.target.value)} />
          </div>
          <Button className="h-12 w-full" disabled={!ready || busy}
            onClick={() => void save()}>
            {busy ? <LoaderCircle className="size-4 animate-spin" /> : null}
            Continue
          </Button>
          {firstName.trim() && /^[A-Za-z]$/.test(lastInitial.trim()) ? (
            <p className="text-muted-foreground text-center text-xs">
              You will appear as{" "}
              <span className="font-medium">
                {firstName.trim()} {lastInitial.trim().toUpperCase()}.
                {teamNumber ? ` (${teamNumber})` : ""}
              </span>
            </p>
          ) : null}
        </CardContent>
      </Card>
    </div>
  );
}

function RequireProfile() {
  const profile = useQuery(api.profiles.me);

  if (profile === undefined) return <FullPageSpinner />;
  // Accounts created before this gate existed have no firstName; prompt them
  // too rather than leaving their reports signed "Scout".
  if (profile === null || !profile.firstName) {
    return <ProfileSetup existingName={profile?.displayName ?? null} />;
  }
  return <Outlet />;
}

export function RequireAuth() {
  const { isLoading, isAuthenticated } = useConvexAuth();
  const location = useLocation();

  if (isLoading) return <FullPageSpinner />;
  if (!isAuthenticated) {
    return <Navigate to="/sign-in" replace state={{ from: location.pathname }} />;
  }
  return <RequireProfile />;
}

export function RequireAdmin() {
  const profile = useQuery(api.profiles.me);
  if (profile === undefined) return <FullPageSpinner />;
  if (profile?.role !== "admin") return <Navigate to="/" replace />;
  return <Outlet />;
}
EOF

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
