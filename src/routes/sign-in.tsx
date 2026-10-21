import { useState } from "react";
import { useAuthActions } from "@convex-dev/auth/react";
import { Link } from "react-router";
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

type Flow = "signIn" | "signUp";

export default function SignInPage() {
  const { signIn } = useAuthActions();
  const [flow, setFlow] = useState<Flow>("signIn");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [pending, setPending] = useState(false);

  const submit = async () => {
    setPending(true);
    try {
      const form = new FormData();
      form.set("email", email);
      form.set("password", password);
      form.set("flow", flow);
      await signIn("password", form);
    } catch {
      toast.error(
        flow === "signIn"
          ? "Could not sign in. Check your email and password."
          : "Could not create that account.",
      );
    } finally {
      setPending(false);
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>{flow === "signIn" ? "Sign in" : "Create account"}</CardTitle>
        <CardDescription>Authentication is handled by Convex.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="space-y-2">
          <Label htmlFor="email">Email</Label>
          <Input
            id="email"
            type="email"
            autoComplete="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        </div>
        <div className="space-y-2">
          <Label htmlFor="password">Password</Label>
          <Input
            id="password"
            type="password"
            autoComplete={
              flow === "signIn" ? "current-password" : "new-password"
            }
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
          {flow === "signIn" ? (
            <div className="flex justify-end">
              <Link
                to={
                  email
                    ? `/forgot-password?email=${encodeURIComponent(email)}`
                    : "/forgot-password"
                }
                className="text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
              >
                Forgot password?
              </Link>
            </div>
          ) : null}
        </div>
        <Button
          className="w-full"
          disabled={pending || !email || !password}
          onClick={() => void submit()}
        >
          {flow === "signIn" ? "Sign in" : "Sign up"}
        </Button>
        <Button
          variant="link"
          className="w-full"
          onClick={() => setFlow(flow === "signIn" ? "signUp" : "signIn")}
        >
          {flow === "signIn"
            ? "Need an account? Sign up"
            : "Already have an account? Sign in"}
        </Button>
      </CardContent>
    </Card>
  );
}
