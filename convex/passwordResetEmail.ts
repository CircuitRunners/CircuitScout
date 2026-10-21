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
