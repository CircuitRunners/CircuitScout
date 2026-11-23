import { useConvex, useConvexAuth, useQuery } from "convex/react";
import { useEffect, useState, useSyncExternalStore, type ReactNode } from "react";

import { api } from "../../../convex/_generated/api";
import { OnlineContext, createConnectionMonitor } from "./status";
import {
  confirmUser, isStoreReady, openStore, setActiveEvent, subscribeStore,
} from "./store";

/**
 * Mounted once, inside the Convex provider. Does three things:
 *  1. answers "is there a connection" for the whole app (useOnline);
 *  2. opens the offline store and holds the first render until the cached
 *     rows are in memory, so no page flashes a spinner before its cached copy;
 *  3. tells the store who is signed in and which event is active, as the
 *     server reports them. Both queries are already subscribed elsewhere
 *     (AppNav, SeasonProvider), and Convex shares one subscription between
 *     identical calls, so this adds no function calls.
 */
export function OfflineProvider({ children }: { children: ReactNode }) {
  const convex = useConvex();
  const [monitor] = useState(() => createConnectionMonitor(convex));
  useEffect(() => monitor.start(), [monitor]);
  const online = useSyncExternalStore(monitor.subscribe, monitor.isOnline);

  useEffect(() => {
    void openStore();
  }, []);
  const ready = useSyncExternalStore(subscribeStore, isStoreReady);

  const { isAuthenticated } = useConvexAuth();
  const profile = useQuery(api.profiles.me, isAuthenticated ? {} : "skip");
  const event = useQuery(api.events.active, isAuthenticated ? {} : "skip");
  const userId = profile?.userId;
  const eventId = event === undefined ? undefined : (event?._id ?? null);

  useEffect(() => {
    if (userId !== undefined) confirmUser(userId);
  }, [userId]);
  useEffect(() => {
    if (userId !== undefined && eventId !== undefined) setActiveEvent(eventId);
  }, [userId, eventId]);

  // IndexedDB opens in a few milliseconds, and openStore() gives up after 1.5 s.
  if (!ready) return null;
  return <OnlineContext.Provider value={online}>{children}</OnlineContext.Provider>;
}
