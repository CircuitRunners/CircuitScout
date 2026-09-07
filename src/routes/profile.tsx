import { useAction, useMutation, useQuery } from "convex/react";
import { useAuthActions } from "@convex-dev/auth/react";
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
import {
  Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { SCOUT_WEIGHTS } from "@/lib/scoring";

const TIER_LABEL = {
  lead: "Strategy lead",
  trusted: "Trusted scout",
  normal: "Scout",
} as const;

function AccountSecurity({ email }: { email: string }) {
  const { signIn, signOut } = useAuthActions();
  const deleteSelf = useMutation(api.account.deleteSelf);

  const [mode, setMode] = useState<"none" | "password" | "delete">("none");
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [confirm, setConfirm] = useState("");
  const [deletePassword, setDeletePassword] = useState("");
  const [deleteConfirmed, setDeleteConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);

  const close = () => {
    setMode("none");
    setCurrent(""); setNext(""); setConfirm("");
    setDeletePassword(""); setDeleteConfirmed(false);
  };

  const changePassword = async () => {
    if (next !== confirm) {
      toast.error("The new passwords do not match.");
      return;
    }
    setBusy(true);
    try {
      await signIn("password-change", {
        email, currentPassword: current, newPassword: next,
      });
      toast.success("Password changed");
      close();
    } catch (error) {
      toast.error("Could not change it", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  const removeAccount = async () => {
    setBusy(true);
    try {
      // Verifying by signing in again is the same check the auth system
      // already trusts, and avoids a second password path to get wrong.
      await signIn("password", {
        email, password: deletePassword, flow: "signIn",
      });
      await deleteSelf({});
      toast.success("Account deleted");
      await signOut();
    } catch (error) {
      toast.error("Could not delete the account", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <Card className="max-w-md">
        <CardHeader>
          <CardTitle>Account</CardTitle>
          <CardDescription>
            Deleting your account removes your sign-in. Reports and pit scouting
            you wrote stay where they are — removing them would change every
            average you contributed to.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap gap-2">
          <Button variant="outline" onClick={() => setMode("password")}>
            Change password
          </Button>
          <Button variant="destructive" onClick={() => setMode("delete")}>
            Delete account
          </Button>
        </CardContent>
      </Card>

      <Dialog open={mode === "password"} onOpenChange={(o) => { if (!o) close(); }}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Change password</DialogTitle>
            <DialogDescription>
              At least 8 characters.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-2">
              <Label htmlFor="current-pw">Current password</Label>
              <Input id="current-pw" type="password" autoComplete="current-password"
                value={current} onChange={(e) => setCurrent(e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="new-pw">New password</Label>
              <Input id="new-pw" type="password" autoComplete="new-password"
                value={next} onChange={(e) => setNext(e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label htmlFor="confirm-pw">Confirm new password</Label>
              <Input id="confirm-pw" type="password" autoComplete="new-password"
                value={confirm} onChange={(e) => setConfirm(e.target.value)} />
            </div>
            {next !== "" && confirm !== "" && next !== confirm ? (
              <p className="text-destructive text-xs">They do not match.</p>
            ) : null}
            <Button className="w-full"
              disabled={busy || current === "" || next.length < 8 || next !== confirm}
              onClick={() => void changePassword()}>
              Change password
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      <Dialog open={mode === "delete"} onOpenChange={(o) => { if (!o) close(); }}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Delete your account</DialogTitle>
            <DialogDescription>
              This cannot be undone.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <div className="space-y-2">
              <Label htmlFor="del-pw">Your password</Label>
              <Input id="del-pw" type="password" autoComplete="current-password"
                value={deletePassword}
                onChange={(e) => setDeletePassword(e.target.value)} />
            </div>
            {!deleteConfirmed ? (
              <Button variant="outline" className="w-full"
                disabled={deletePassword === ""}
                onClick={() => setDeleteConfirmed(true)}>
                Continue
              </Button>
            ) : (
              <>
                <p className="text-destructive text-sm">
                  Your sign-in will be removed and you will be signed out.
                  Everything you scouted stays.
                </p>
                <Button variant="destructive" className="w-full" disabled={busy}
                  onClick={() => void removeAccount()}>
                  Delete my account permanently
                </Button>
              </>
            )}
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}

export default function ProfilePage() {
  const profile = useQuery(api.profiles.me);
  const email = useQuery(api.account.myEmail);
  const ensure = useAction(api.tba.claimProfile);

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
      const result = await ensure({ firstName, lastInitial, teamNumber: team });
      toast.success(`Joined ${result.nickname}`);
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

      {email ? <AccountSecurity email={email} /> : null}

      <Card className="max-w-md">
        <CardHeader>
          <CardTitle>Role</CardTitle>
          <CardDescription>
            Only an admin can change these.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap items-center gap-2">
          {profile && profile.weightTier !== "normal" ? (
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
