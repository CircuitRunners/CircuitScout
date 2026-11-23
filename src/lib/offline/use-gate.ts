import { useAuthToken } from "@convex-dev/auth/react";
import { useConvexAuth } from "convex/react";
import { useSyncExternalStore } from "react";

import { decideGate, userIdFromToken, type Gate } from "./session";
import { useOnline } from "./status";
import { cachedUserId, subscribeStore } from "./store";

/** Which of the five gate states the app is in. See session.ts. */
export function useGate(): Gate {
  const { isAuthenticated, isLoading } = useConvexAuth();
  const online = useOnline();
  const token = useAuthToken();
  const cached = useSyncExternalStore(subscribeStore, cachedUserId);
  return decideGate({
    isAuthenticated,
    isLoading,
    online,
    tokenUserId: userIdFromToken(token),
    cachedUserId: cached,
  });
}
