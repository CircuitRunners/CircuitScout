import { useState } from "react";
import { useAuthActions } from "@convex-dev/auth/react";
import { ConvexError } from "convex/values";
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

export default function ForgotPasswordPage() {
  const { signIn } = useAuthActions();
  const [params] = useSearchParams();
  const [email, setEmail] = useState(params.get("email") ?? "");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sentTo, setSentTo] = useState<string | null>(null);

  const submit = async () => {
    const trimmed = email.trim();
    setPending(true);
    setError(null);
    try {
      await signIn("password", { email: trimmed, flow: "reset" });
      setSentTo(trimmed);
    } catch (e) {
      // ConvexError = the email failed to send; anything else is the
      // Password provider refusing an email it has no account for.
      if (e instanceof ConvexError) {
        toast.error(String(e.data));
      } else {
        setError("No account was found with that email.");
      }
    } finally {
      setPending(false);
    }
  };

  if (sentTo) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>Check your email</CardTitle>
          <CardDescription>
            We sent a reset link to {sentTo}. It expires in 1 hour.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          <p className="text-sm text-muted-foreground">
            Nothing after a few minutes? Check spam, or send it again.
          </p>
          <Button
            variant="outline"
            className="w-full"
            disabled={pending}
            onClick={() => void submit()}
          >
            Send again
          </Button>
          <Button variant="link" className="w-full" render={<Link to="/sign-in" />}>
            Back to sign in
          </Button>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Forgot password</CardTitle>
        <CardDescription>
          Enter your account email and we&apos;ll send you a reset link.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            void submit();
          }}
        >
          <div className="space-y-2">
            <Label htmlFor="email">Email</Label>
            <Input
              id="email"
              type="email"
              autoComplete="email"
              value={email}
              aria-invalid={error ? true : undefined}
              onChange={(e) => {
                setEmail(e.target.value);
                setError(null);
              }}
            />
            {error ? <p className="text-sm text-destructive">{error}</p> : null}
          </div>
          <Button type="submit" className="w-full" disabled={pending || !email.trim()}>
            {pending ? "Sending…" : "Send reset link"}
          </Button>
          <Button variant="link" className="w-full" render={<Link to="/sign-in" />}>
            Back to sign in
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
