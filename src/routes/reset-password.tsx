import { useState } from "react";
import { useAuthActions } from "@convex-dev/auth/react";
import { Link, useSearchParams } from "react-router";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

const MIN_LENGTH = 8; // Convex Auth's default password rule

export default function ResetPasswordPage() {
  const { signIn } = useAuthActions();
  const [params] = useSearchParams();
  const email = params.get("email") ?? "";
  const token = params.get("token") ?? "";

  const [newPassword, setNewPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [pending, setPending] = useState(false);
  const [linkBroken, setLinkBroken] = useState(!email || !token);

  const tooShort = newPassword.length > 0 && newPassword.length < MIN_LENGTH;
  const mismatch = confirm.length > 0 && confirm !== newPassword;
  const canSubmit =
    newPassword.length >= MIN_LENGTH && confirm === newPassword && !pending;

  const submit = async () => {
    setPending(true);
    try {
      // On success Convex Auth signs the scout in, and AuthLayout sends them home.
      await signIn("password", {
        email,
        code: token,
        newPassword,
        flow: "reset-verification",
      });
      toast.success("Password updated");
    } catch {
      setLinkBroken(true);
    } finally {
      setPending(false);
    }
  };

  if (linkBroken) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>Link expired or invalid</CardTitle>
          <CardDescription>
            Reset links work once and expire after 1 hour. Request a new one.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <Button
            className="w-full"
            render={
              <Link
                to={
                  email
                    ? `/forgot-password?email=${encodeURIComponent(email)}`
                    : "/forgot-password"
                }
              />
            }
          >
            Send a new link
          </Button>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Choose a new password</CardTitle>
        <CardDescription>For {email}</CardDescription>
      </CardHeader>
      <CardContent>
        <form
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            if (canSubmit) void submit();
          }}
        >
          <div className="space-y-2">
            <Label htmlFor="new-password">New password</Label>
            <Input
              id="new-password"
              type="password"
              autoComplete="new-password"
              value={newPassword}
              aria-invalid={tooShort ? true : undefined}
              onChange={(e) => setNewPassword(e.target.value)}
            />
            {tooShort ? (
              <p className="text-sm text-destructive">
                At least {MIN_LENGTH} characters.
              </p>
            ) : null}
          </div>
          <div className="space-y-2">
            <Label htmlFor="confirm-password">Confirm new password</Label>
            <Input
              id="confirm-password"
              type="password"
              autoComplete="new-password"
              value={confirm}
              aria-invalid={mismatch ? true : undefined}
              onChange={(e) => setConfirm(e.target.value)}
            />
            {mismatch ? (
              <p className="text-sm text-destructive">Passwords don&apos;t match.</p>
            ) : null}
          </div>
          <Button type="submit" className="w-full" disabled={!canSubmit}>
            {pending ? "Saving…" : "Reset password"}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
