#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-profile-page.sh — /profile screen, reachable from a person icon in the
# header next to sign out. Reuses profiles.ensure, which already patches an
# existing profile, so there is no new mutation and no schema change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/components/app-nav.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Profile page"
cat > src/routes/profile.tsx <<'EOF'
import { useMutation, useQuery } from "convex/react";
import { LoaderCircle } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { api } from "../../convex/_generated/api";
import { PageShell } from "./page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { SCOUT_WEIGHTS } from "@/lib/scoring";

const TIER_LABEL = {
  lead: "Strategy lead",
  trusted: "Trusted scout",
  normal: "Scout",
} as const;

export default function ProfilePage() {
  const profile = useQuery(api.profiles.me);
  const ensure = useMutation(api.profiles.ensure);

  const [firstName, setFirstName] = useState("");
  const [lastInitial, setLastInitial] = useState("");
  const [teamNumber, setTeamNumber] = useState("");
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);

  // Hydrate once. The query is live, so re-hydrating would overwrite what the
  // person is typing every time anything else on their profile changed.
  useEffect(() => {
    if (loaded || profile === undefined || profile === null) return;
    setFirstName(profile.firstName ?? "");
    setLastInitial(profile.lastInitial ?? "");
    setTeamNumber(profile.teamNumber ? String(profile.teamNumber) : "");
    setLoaded(true);
  }, [profile, loaded]);

  const team = Number.parseInt(teamNumber, 10);
  const ready =
    firstName.trim() !== "" &&
    /^[A-Za-z]$/.test(lastInitial.trim()) &&
    Number.isInteger(team) &&
    team > 0;

  const changed =
    profile != null &&
    (firstName.trim() !== (profile.firstName ?? "") ||
      lastInitial.trim().toUpperCase() !== (profile.lastInitial ?? "") ||
      team !== profile.teamNumber);

  const save = async () => {
    setBusy(true);
    try {
      await ensure({ firstName, lastInitial, teamNumber: team });
      toast.success("Profile updated");
    } catch (error) {
      toast.error("Could not save", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  if (profile === undefined) {
    return <PageShell title="My profile" description="Loading…" />;
  }

  return (
    <PageShell
      title="My profile"
      description="How you appear on every report you submit."
    >
      <Card className="max-w-md">
        <CardHeader>
          <CardTitle>Name and team</CardTitle>
          <CardDescription>
            Changing this updates your name everywhere, including on reports you
            have already submitted — they store who wrote them, not what you
            were called at the time.
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

          {ready ? (
            <p className="text-muted-foreground text-xs">
              You will appear as{" "}
              <span className="text-foreground font-medium">
                {firstName.trim()} {lastInitial.trim().toUpperCase()}. ({team})
              </span>
            </p>
          ) : null}

          <Button className="h-12 w-full" disabled={!ready || !changed || busy}
            onClick={() => void save()}>
            {busy ? <LoaderCircle className="size-4 animate-spin" /> : null}
            {changed ? "Save changes" : "No changes"}
          </Button>
        </CardContent>
      </Card>

      <Card className="max-w-md">
        <CardHeader>
          <CardTitle>Role</CardTitle>
          <CardDescription>
            Only an admin can change these.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap items-center gap-2">
          <Badge variant={profile?.role === "admin" ? "default" : "secondary"}>
            {profile?.role === "admin" ? "Admin" : "Scout"}
          </Badge>
          {profile ? (
            <>
              <Badge variant="outline">{TIER_LABEL[profile.weightTier]}</Badge>
              <span className="text-muted-foreground text-xs">
                counts {SCOUT_WEIGHTS[profile.weightTier]}× in the pick list merge
              </span>
            </>
          ) : null}
        </CardContent>
      </Card>
    </PageShell>
  );
}
EOF

say "Header icon and route"
cat > /tmp/pp.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

// --- nav ---
let n = readFileSync("src/components/app-nav.tsx", "utf8");
if (!n.includes("/profile")) {
  n = n.replace('import { LogOut, Menu } from "lucide-react";',
                'import { LogOut, Menu, User } from "lucide-react";');
  n = n.replace('import { NavLink } from "react-router";',
                'import { Link, NavLink } from "react-router";');
  const anchor = `          <Button
            variant="ghost"
            size="icon"
            aria-label="Sign out"`;
  if (!n.includes(anchor)) fail("could not find the sign out button");
  n = n.replace(anchor, `          <Button
            variant="ghost"
            size="icon"
            aria-label="Edit my profile"
            render={<Link to="/profile" />}
          >
            <User className="size-4" />
          </Button>
          <Button
            variant="ghost"
            size="icon"
            aria-label="Sign out"`);
  writeFileSync("src/components/app-nav.tsx", n);
  console.log("src/components/app-nav.tsx patched");
} else { console.log("nav already patched"); }

// --- route ---
let r = readFileSync("src/routes/router.tsx", "utf8");
if (!r.includes("ProfilePage")) {
  r = r.replace('import DashboardPage from "./dashboard";',
                'import DashboardPage from "./dashboard";\nimport ProfilePage from "./profile";');
  const anchor = `              { index: true, element: <DashboardPage /> },`;
  if (!r.includes(anchor)) fail("could not find the index route");
  r = r.replace(anchor, `${anchor}
              { path: "profile", element: <ProfilePage /> },`);
  writeFileSync("src/routes/router.tsx", r);
  console.log("src/routes/router.tsx patched");
} else { console.log("router already patched"); }
MJS
bun /tmp/pp.mjs
rm -f /tmp/pp.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
