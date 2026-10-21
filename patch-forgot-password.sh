#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-forgot-password.sh  (Gmail version — replaces the Resend version)
#   1. "Forgot password?" link on the sign-in card
#   2. /forgot-password — asks for the email; unknown email shows an error
#   3. Reset email sent from the CircuitScout Google Workspace account over
#      Gmail SMTP with an app password — no DNS changes needed
#   4. /reset-password — new password + confirm, from the emailed link
#
# Uses the Password provider's built-in "reset" / "reset-verification" flows,
# so tokens, expiry and the password write are all Convex Auth's own code.
#
# SMTP needs Node, and "use node" files may only hold actions, so the send
# lives in convex/mailer.ts and the auth hook calls it with ctx.runAction.
#
# The link carries ?email=&token=, NOT ?code=: ConvexAuthProvider consumes any
# ?code= on page load and tries to sign in with it, which would eat the token
# before the reset page ever saw it.
#
# Safe to run whether or not the Resend version was applied first.
#
# Convex env vars needed (dev, then again with --prod):
#   bunx convex env set GMAIL_USER          circuitscout-address@your-domain
#   bunx convex env set GMAIL_APP_PASSWORD  "abcd efgh ijkl mnop"
#   SITE_URL — already required by Convex Auth; must be the app's public URL
#   (RESEND_API_KEY / AUTH_EMAIL_FROM are no longer used and can be removed)
#
# No schema change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/auth.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Dependencies: nodemailer"
bun add nodemailer
bun add -d @types/nodemailer

say "Convex: Gmail sender (Node action)"
cat > convex/mailer.ts <<'EOF'
"use node";

import nodemailer from "nodemailer";
import { v } from "convex/values";
import { internalAction } from "./_generated/server";

/**
 * Sends the reset email through Gmail SMTP as the CircuitScout Workspace
 * account. Returns a result instead of throwing so the caller can turn a
 * failure into a message the client is allowed to see.
 *
 * GMAIL_APP_PASSWORD is the 16-character app password, not the account's
 * real password. Google revokes it whenever the account password changes.
 */
export const sendPasswordResetEmail = internalAction({
  args: { to: v.string(), link: v.string() },
  handler: async (_ctx, { to, link }): Promise<{ ok: boolean }> => {
    const user = process.env.GMAIL_USER;
    const pass = process.env.GMAIL_APP_PASSWORD?.replace(/\s+/g, "");
    if (!user || !pass) {
      console.error("mailer: GMAIL_USER / GMAIL_APP_PASSWORD not set");
      return { ok: false };
    }

    const transport = nodemailer.createTransport({
      host: "smtp.gmail.com",
      port: 465,
      secure: true,
      auth: { user, pass },
    });

    try {
      await transport.sendMail({
        from: { name: "CircuitScout", address: user },
        to,
        subject: "Reset your CircuitScout password",
        text:
          `Someone asked to reset the CircuitScout password for ${to}.\n\n` +
          `Choose a new password here (the link expires in 1 hour):\n${link}\n\n` +
          `If this wasn't you, you can ignore this email.`,
        html:
          `<p>Someone asked to reset the CircuitScout password for <strong>${to}</strong>.</p>` +
          `<p><a href="${link}">Choose a new password</a> — the link expires in 1 hour.</p>` +
          `<p>If this wasn't you, you can ignore this email.</p>`,
      });
      return { ok: true };
    } catch (error) {
      // Bad/revoked app password shows up here as an auth (535) error.
      console.error("mailer: Gmail send failed", error);
      return { ok: false };
    }
  },
});
EOF

say "Convex: reset email provider"
cat > convex/passwordResetEmail.ts <<'EOF'
import { Email } from "@convex-dev/auth/providers/Email";
import type { GenericActionCtx } from "convex/server";
import { ConvexError } from "convex/values";
import { internal } from "./_generated/api";
import type { DataModel } from "./_generated/dataModel";

const LINK_LIFETIME_S = 60 * 60; // 1 hour

/**
 * Sends the password reset link. Plugged into Password({ reset }) in auth.ts;
 * Convex Auth creates and stores the token, this only delivers it.
 *
 * Failures are ConvexErrors on purpose: their message reaches the client, so
 * the forgot-password page can tell "email didn't send" apart from "no such
 * account" (which arrives as a plain server error).
 *
 * Convex Auth passes the action ctx as a second argument at runtime, but its
 * email-provider typing (inherited from Auth.js) only declares one — hence the
 * optional, explicitly typed ctx.
 */
export const PasswordResetEmail = Email({
  id: "password-reset",
  maxAge: LINK_LIFETIME_S,
  async sendVerificationRequest(
    { identifier: email, token },
    ctx?: GenericActionCtx<DataModel>,
  ) {
    if (!ctx) throw new Error("Convex Auth did not pass an action context");
    const siteUrl = process.env.SITE_URL;
    if (!siteUrl) {
      throw new ConvexError(
        "Password reset email is not configured. Ask an admin to set SITE_URL.",
      );
    }

    const link = new URL("/reset-password", siteUrl);
    link.searchParams.set("email", email);
    link.searchParams.set("token", token);

    const result: { ok: boolean } = await ctx.runAction(
      internal.mailer.sendPasswordResetEmail,
      { to: email, link: link.toString() },
    );
    if (!result.ok) {
      throw new ConvexError("Could not send the reset email. Try again in a minute.");
    }
  },
});
EOF

say "Convex: enable reset on the Password provider"
cat > /tmp/fp-auth.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/auth.ts";
let s = readFileSync(p, "utf8");

if (s.includes("PasswordResetEmail")) {
  console.log("convex/auth.ts already patched");
  process.exit(0);
}

const importAnchor = `import type { DataModel } from "./_generated/dataModel";`;
if (!s.includes(importAnchor)) throw new Error("auth.ts: DataModel import not found");
s = s.replace(
  importAnchor,
  `${importAnchor}\nimport { PasswordResetEmail } from "./passwordResetEmail";`,
);

const providersRe = /providers:\s*\[\s*Password\s*,/;
if (!providersRe.test(s)) throw new Error("auth.ts: providers list not found");
s = s.replace(
  providersRe,
  "providers: [Password<DataModel>({ reset: PasswordResetEmail }),",
);

writeFileSync(p, s);
console.log("convex/auth.ts patched");
MJS
bun /tmp/fp-auth.mjs
rm -f /tmp/fp-auth.mjs

say "UI: /forgot-password"
cat > src/routes/forgot-password.tsx <<'EOF'
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
EOF

say "UI: /reset-password"
cat > src/routes/reset-password.tsx <<'EOF'
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
EOF

say "UI: routes + sign-in link"
cat > /tmp/fp-ui.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";

// --- router.tsx -----------------------------------------------------------
{
  const p = "src/routes/router.tsx";
  let s = readFileSync(p, "utf8");
  if (s.includes("ForgotPasswordPage")) {
    console.log("router.tsx already patched");
  } else {
    const imp = `import SignInPage from "./sign-in";`;
    if (!s.includes(imp)) throw new Error("router.tsx: SignInPage import not found");
    s = s.replace(
      imp,
      `${imp}\nimport ForgotPasswordPage from "./forgot-password";\nimport ResetPasswordPage from "./reset-password";`,
    );
    const route = `children: [{ path: "sign-in", element: <SignInPage /> }],`;
    if (!s.includes(route)) throw new Error("router.tsx: sign-in route not found");
    s = s.replace(
      route,
      `children: [
          { path: "sign-in", element: <SignInPage /> },
          { path: "forgot-password", element: <ForgotPasswordPage /> },
          { path: "reset-password", element: <ResetPasswordPage /> },
        ],`,
    );
    writeFileSync(p, s);
    console.log("router.tsx patched");
  }
}

// --- sign-in.tsx ----------------------------------------------------------
{
  const p = "src/routes/sign-in.tsx";
  let s = readFileSync(p, "utf8");
  if (s.includes("/forgot-password")) {
    console.log("sign-in.tsx already patched");
  } else {
    const imp = `import { toast } from "sonner";`;
    if (!s.includes(imp)) throw new Error("sign-in.tsx: sonner import not found");
    s = s.replace(imp, `import { Link } from "react-router";\n${imp}`);

    // Slot the link under the password field, sign-in mode only.
    const anchor = `            onChange={(e) => setPassword(e.target.value)}
          />
        </div>`;
    if (!s.includes(anchor)) throw new Error("sign-in.tsx: password field not found");
    s = s.replace(
      anchor,
      `            onChange={(e) => setPassword(e.target.value)}
          />
          {flow === "signIn" ? (
            <div className="flex justify-end">
              <Link
                to={
                  email
                    ? \`/forgot-password?email=\${encodeURIComponent(email)}\`
                    : "/forgot-password"
                }
                className="text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
              >
                Forgot password?
              </Link>
            </div>
          ) : null}
        </div>`,
    );
    writeFileSync(p, s);
    console.log("sign-in.tsx patched");
  }
}
MJS
bun /tmp/fp-ui.mjs
rm -f /tmp/fp-ui.mjs

say "Done"
cat <<'TXT'
Next:
  1. CircuitScout Google account: 2-Step Verification on, then create an
     app password at https://myaccount.google.com/apppasswords
  2. bunx convex env set GMAIL_USER         circuitscout-address@your-domain
  3. bunx convex env set GMAIL_APP_PASSWORD "abcd efgh ijkl mnop"
     (repeat 2-3 with --prod)
  4. bunx convex env get SITE_URL   (must be the deployed app URL in prod)
  5. bun run go   (regenerates convex/_generated so internal.mailer exists)
  6. bun run typecheck
TXT
