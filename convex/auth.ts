import { convexAuth } from "@convex-dev/auth/server";
import { Password } from "@convex-dev/auth/providers/Password";
import { ConvexCredentials } from "@convex-dev/auth/providers/ConvexCredentials";
import { modifyAccountCredentials, retrieveAccount } from "@convex-dev/auth/server";
import { internal } from "./_generated/api";
import type { DataModel } from "./_generated/dataModel";

/**
 * Changing a password is not part of the Password provider's flows, and the
 * credential helpers can only be called with the auth-aware context a provider
 * gets. So it is a provider of its own, invoked as
 * signIn("password-change", { email, currentPassword, newPassword }).
 */
const PasswordChange = ConvexCredentials<DataModel>({
  id: "password-change",
  authorize: async (params, ctx) => {
    const email = String(params.email ?? "");
    const currentPassword = String(params.currentPassword ?? "");
    const newPassword = String(params.newPassword ?? "");

    if (newPassword.length < 8) {
      throw new Error("The new password must be at least 8 characters.");
    }

    // Re-checking the old password is the whole point: a stolen open session
    // should not be enough to lock the owner out of their own account.
    const existing = await retrieveAccount(ctx, {
      provider: "password",
      account: { id: email, secret: currentPassword },
    });
    if (!existing) throw new Error("Current password is incorrect.");

    await modifyAccountCredentials(ctx, {
      provider: "password",
      account: { id: email, secret: newPassword },
    });

    return { userId: existing.user._id };
  },
});

/**
 * An admin setting someone else's password. The admin proves their OWN
 * password, and the provider returns the ADMIN's user id — returning the
 * target's would sign the admin in as the scout they were trying to help.
 */
const AdminPasswordReset = ConvexCredentials<DataModel>({
  id: "admin-password-reset",
  authorize: async (params, ctx) => {
    const adminEmail = String(params.adminEmail ?? "");
    const adminPassword = String(params.adminPassword ?? "");
    const targetEmail = String(params.targetEmail ?? "");
    const newPassword = String(params.newPassword ?? "");

    if (newPassword.length < 8) {
      throw new Error("The new password must be at least 8 characters.");
    }

    const admin = await retrieveAccount(ctx, {
      provider: "password",
      account: { id: adminEmail, secret: adminPassword },
    });
    if (!admin) throw new Error("Your password is incorrect.");

    // Role and target are checked in the database: a valid password alone is
    // any signed-up scout, not an admin.
    const check = await ctx.runQuery(internal.profiles.adminResetTarget, {
      adminUserId: admin.user._id,
      targetEmail,
    });
    if (!check.ok) throw new Error(check.reason);

    await modifyAccountCredentials(ctx, {
      provider: "password",
      account: { id: targetEmail, secret: newPassword },
    });

    return { userId: admin.user._id };
  },
});

export const { auth, signIn, signOut, store } = convexAuth({
  providers: [Password, PasswordChange, AdminPasswordReset],
});
