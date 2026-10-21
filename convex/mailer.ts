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
