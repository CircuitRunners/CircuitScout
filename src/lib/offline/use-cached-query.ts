import { useQuery, type OptionalRestArgsOrSkip } from "convex/react";
import {
  getFunctionName, type FunctionReference, type FunctionReturnType,
} from "convex/server";
import { useEffect, useSyncExternalStore } from "react";

import { useOnline } from "./status";
import {
  cacheKey, markServed, readCached, saveResult, storeEpoch, subscribeStore,
} from "./store";

/**
 * Drop-in for useQuery that also keeps the latest result on the device.
 *
 *   online, result arrived   the live result (and it is saved)
 *   online, still loading    undefined, exactly as useQuery
 *   offline, copy on device  the copy; its age shows in <OfflineBanner>
 *   offline, no copy         undefined
 *
 * A live result always wins, so nothing changes while there is a connection.
 * Use it only for queries on the offline plan's list (section 6.3), and bump
 * CACHE_VERSION in store.ts when one of them changes its return shape.
 */
export function useCachedQuery<Query extends FunctionReference<"query">>(
  query: Query,
  ...args: OptionalRestArgsOrSkip<Query>
): FunctionReturnType<Query> | undefined {
  const live = useQuery(query, ...args);
  const online = useOnline();
  // Re-run the save below when the store has dropped rows (new user, new event).
  const epoch = useSyncExternalStore(subscribeStore, storeEpoch);

  // `api.x.y` is a new object on every access; the name is the stable part.
  const name = getFunctionName(query);
  const first: unknown = args[0];
  const key = first === "skip" ? null : cacheKey(name, first);

  useEffect(() => {
    if (key !== null && live !== undefined) saveResult(name, key, live);
  }, [name, key, live, epoch]);

  const cached = key !== null && live === undefined && !online ? readCached(key) : undefined;
  const servedAt = cached?.savedAt;
  useEffect(() => {
    if (servedAt === undefined) return;
    return markServed(servedAt);
  }, [servedAt]);

  if (live !== undefined || cached === undefined) return live;
  return cached.result as FunctionReturnType<Query>;
}
