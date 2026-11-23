import { useAuthActions } from "@convex-dev/auth/react";
import { useCallback } from "react";

import { forgetAuthTokens } from "./session";
import { useOnline } from "./status";
import { clearOfflineData } from "./store";

/**
 * The only way the app signs out. Empties the offline store first, so the
 * next person on a shared tablet never sees the previous scout's data, then
 * signs out.
 *
 * With no connection, Convex Auth's signOut() would wait forever on a server
 * call, so the tokens are removed from the device directly and the page is
 * reloaded onto the sign-in screen.
 */
export function useSignOutAndClear(): () => Promise<void> {
  const { signOut } = useAuthActions();
  const online = useOnline();
  return useCallback(async () => {
    clearOfflineData();
    if (online) {
      await signOut();
      return;
    }
    forgetAuthTokens();
    window.location.assign("/sign-in");
  }, [online, signOut]);
}
