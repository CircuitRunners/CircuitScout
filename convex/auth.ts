import { convexAuth } from "@convex-dev/auth/server";
import { Password } from "@convex-dev/auth/providers/Password";

// Auth runs inside Convex — no separate auth service, no API routes.
// Add OAuth/magic-link providers to this array as needed.
export const { auth, signIn, signOut, store } = convexAuth({
  providers: [Password],
});
