import { useConvexAuth, useAction, useQuery } from "convex/react";
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
  const ensure = useAction(api.tba.claimProfile);
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
      const result = await ensure({ firstName, lastInitial, teamNumber: team });
      toast.success(`Joined ${result.nickname}`);
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
  if (profile?.role !== "admin" && profile?.role !== "teamAdmin") {
    return <Navigate to="/" replace />;
  }
  return <Outlet />;
}
