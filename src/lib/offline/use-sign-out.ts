import { useAuthActions } from "@convex-dev/auth/react";
import { useCallback, useSyncExternalStore } from "react";

import { discardHeld, heldCount } from "./held";
import { forgetAuthTokens } from "./session";
import { useOnline } from "./status";
import { clearOfflineData } from "./store";

/**
 * A sign-out that is waiting for an answer: this scout has reports on the
 * device that have not been sent, and signing out discards them.
 */
export type SignOutQuestion = { count: number; proceed: () => void };

let question: SignOutQuestion | null = null;
const listeners = new Set<() => void>();
function ask(next: SignOutQuestion | null) {
  question = next;
  for (const listener of listeners) listener();
}
function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** For SignOutDialog, which is mounted once in the app layout. */
export function useSignOutQuestion(): SignOutQuestion | null {
  return useSyncExternalStore(subscribe, () => question);
}
export function cancelSignOut() {
  ask(null);
}

/**
 * The only way the app signs out. Empties the offline store first, so the
 * next person on a shared tablet never sees the previous scout's data, then
 * signs out.
 *
 * Reports held on the device and not sent yet would be lost, so with any
 * waiting the scout is asked first (SignOutDialog) and nothing happens until
 * they answer. Pass force to skip the question, for an account that has
 * just been deleted.
 *
 * With no connection, Convex Auth's signOut() would wait forever on a server
 * call, so the tokens are removed from the device directly and the page is
 * reloaded onto the sign-in screen.
 */
export function useSignOutAndClear(): (options?: { force?: boolean }) => Promise<void> {
  const { signOut } = useAuthActions();
  const online = useOnline();
  return useCallback(async (options) => {
    const finish = async () => {
      ask(null);
      // First, and awaited: it reads whose reports these are from the store.
      await discardHeld();
      clearOfflineData();
      if (online) {
        await signOut();
        return;
      }
      forgetAuthTokens();
      window.location.assign("/sign-in");
    };
    const count = heldCount();
    if (count === 0 || options?.force) {
      await finish();
      return;
    }
    ask({ count, proceed: () => void finish() });
  }, [online, signOut]);
}
