import {
  getFunctionName, type FunctionReference, type FunctionReturnType, type OptionalRestArgs,
} from "convex/server";
import { useEffect, useSyncExternalStore } from "react";

import { useOnline } from "./status";
import { cacheKey, markServed, readCached, storeEpoch, subscribeStore } from "./store";

/**
 * The saved copy of a query, and only while offline. Never subscribes and
 * never calls Convex, so using it costs nothing. Online it returns undefined.
 *
 * For building an offline page out of lists some OTHER page keeps saved (the
 * schedule and the team list). To read a page's own query, use
 * useCachedQuery instead.
 */
export function useCachedOnly<Query extends FunctionReference<"query">>(
  query: Query,
  ...args: OptionalRestArgs<Query>
): FunctionReturnType<Query> | undefined {
  const online = useOnline();
  // Re-read when the store has dropped rows (new user, new event).
  useSyncExternalStore(subscribeStore, storeEpoch);

  const key = online ? null : cacheKey(getFunctionName(query), args[0]);
  const cached = key === null ? undefined : readCached(key);
  const servedAt = cached?.savedAt;
  useEffect(() => {
    if (servedAt === undefined) return;
    return markServed(servedAt);
  }, [servedAt]);

  return cached?.result as FunctionReturnType<Query> | undefined;
}
