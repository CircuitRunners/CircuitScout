/**
 * The cached-login decision (offline plan, section 5.1). Pure, so it can be
 * reasoned about and tested without React or Convex.
 *
 *   live           the server confirmed the session: the app, exactly as before
 *   offline        no connection, but this device holds a sign-in token and the
 *                  offline store holds that same user's data: the app, from cache
 *   signed-out     there is a connection and no session: /sign-in
 *   connect-first  no connection and nothing usable on the device
 *   loading        there is a connection and the server has not answered yet
 *
 * Nothing here grants anything. "offline" only decides what the UI shows;
 * every write is still checked by Convex when it reaches the server.
 */
export type Gate = "live" | "offline" | "signed-out" | "connect-first" | "loading";

export function decideGate(input: {
  /** useConvexAuth(): the server has confirmed the session. */
  isAuthenticated: boolean;
  /** useConvexAuth(): the server has not answered yet. */
  isLoading: boolean;
  online: boolean;
  /** The user id inside the stored sign-in token, or null when there is none. */
  tokenUserId: string | null;
  /** Whose data the offline store holds, or null when it holds nobody's. */
  cachedUserId: string | null;
}): Gate {
  if (input.isAuthenticated) return "live";
  if (input.online) return input.isLoading ? "loading" : "signed-out";
  // The token and the cache must be the same person's. A token alone shows
  // nothing; a cache alone could be the previous user's.
  if (input.tokenUserId !== null && input.tokenUserId === input.cachedUserId) return "offline";
  return "connect-first";
}

/**
 * Reads the user id out of a Convex Auth token without verifying it. Convex
 * Auth sets the subject to "<userId>|<sessionId>". The result is only ever
 * compared with the cached user id, to decide whose cached data to show; an
 * unreadable token simply means no offline entry.
 */
export function userIdFromToken(token: string | null): string | null {
  if (!token) return null;
  try {
    const payload = token.split(".")[1];
    if (!payload) return null;
    const base64 = payload.replace(/-/g, "+").replace(/_/g, "/");
    const json = atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "="));
    const subject: unknown = (JSON.parse(json) as { sub?: unknown }).sub;
    if (typeof subject !== "string") return null;
    const id = subject.split("|")[0];
    return id ? id : null;
  } catch {
    return null;
  }
}

/**
 * Removes Convex Auth's tokens from this device. Only for signing out with no
 * connection: Convex Auth's own signOut() erases them after a server call,
 * and offline that call never returns. The session on the server stays valid
 * until it expires, but nothing on this device can use it any more.
 *
 * Convex Auth keeps its keys in localStorage under the "__convexAuth" prefix
 * (@convex-dev/auth 0.0.95). If a future version moves them, signing out
 * offline stops clearing the token and the app still shows no cached data,
 * because clearOfflineData() has already emptied the store.
 */
export function forgetAuthTokens() {
  try {
    const doomed: string[] = [];
    for (let i = 0; i < localStorage.length; i += 1) {
      const key = localStorage.key(i);
      if (key?.startsWith("__convexAuth")) doomed.push(key);
    }
    for (const key of doomed) localStorage.removeItem(key);
  } catch {
    // Storage is unavailable; there is nothing to forget.
  }
}
