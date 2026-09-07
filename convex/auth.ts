import { convexAuth } from "@convex-dev/auth/server";
import { Password } from "@convex-dev/auth/providers/Password";
import { ConvexCredentials } from "@convex-dev/auth/providers/ConvexCredentials";
import { modifyAccountCredentials, retrieveAccount } from "@convex-dev/auth/server";
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

export const { auth, signIn, signOut, store } = convexAuth({
  providers: [Password, PasswordChange],
});
