import { useConvex, useConvexAuth, useQuery } from "convex/react";
import { useEffect, useMemo, useState, useSyncExternalStore, type ReactNode } from "react";

import { api } from "../../../convex/_generated/api";
import { startSending, stopSending, type Sender } from "./held";
import { OnlineContext, createConnectionMonitor } from "./status";
import {
  confirmUser, isStoreReady, openStore, setActiveEvent, subscribeStore,
} from "./store";

/**
 * Mounted once, inside the Convex provider. Does four things:
 *  1. answers "is there a connection" for the whole app (useOnline);
 *  2. opens the offline store and holds the first render until the cached
 *     rows are in memory, so no page flashes a spinner before its cached copy;
 *  3. tells the store who is signed in and which event is active, as the
 *     server reports them. Both queries are already subscribed elsewhere
 *     (AppNav, SeasonProvider), and Convex shares one subscription between
 *     identical calls, so this adds no function calls;
 *  4. sends the reports held on this device (held.ts) while there is a
 *     connection and the server has confirmed who is signed in.
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

  const sender = useMemo<Sender>(() => ({
    receipts: (ids) => convex.query(api.transfer.receipts, { ids }),
    send: (report) => convex.mutation(api.transfer.send, { report }),
  }), [convex]);
  useEffect(() => {
    // Held reports are sent as their author: only once the server has said
    // who this is, and only with a connection.
    if (online && isAuthenticated && userId !== undefined) startSending(sender, userId);
    else stopSending();
    return stopSending;
  }, [online, isAuthenticated, userId, sender]);

  // IndexedDB opens in a few milliseconds, and openStore() gives up after 1.5 s.
  if (!ready) return null;
  return <OnlineContext.Provider value={online}>{children}</OnlineContext.Provider>;
}
