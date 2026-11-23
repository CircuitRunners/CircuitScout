import { createContext, useContext } from "react";

/**
 * The single answer to "is there a connection". Every offline decision in the
 * app reads this, so the badge, the banner and the cache can never disagree.
 */
export const OnlineContext = createContext(true);

/** True while Convex is reachable. Provided by <OfflineProvider>. */
export const useOnline = (): boolean => useContext(OnlineContext);

type ConnectionSource = {
  connectionState(): { isWebSocketConnected: boolean };
  subscribeToConnectionState(cb: (state: { isWebSocketConnected: boolean }) => void): () => void;
};

/** How long a dropped socket is given to come back before the app says Offline. */
export const SOCKET_GRACE_MS = 3000;

/**
 * Watches the browser's online flag and the Convex websocket.
 *
 * `navigator.onLine` only says a network is joined, not that it passes
 * traffic, and venue wifi is often the first without the second. So:
 *  - browser says offline            -> offline, at once
 *  - socket connected                -> online
 *  - browser says online, socket down -> online for a short grace, then offline
 * The grace also covers the first moments after launch, before the socket has
 * had a chance to connect.
 */
export function createConnectionMonitor(source: ConnectionSource, graceMs = SOCKET_GRACE_MS) {
  let browserOnline = typeof navigator === "undefined" ? true : navigator.onLine;
  let socketUp = false;
  let online = browserOnline;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const listeners = new Set<() => void>();

  const set = (next: boolean) => {
    if (next === online) return;
    online = next;
    for (const listener of listeners) listener();
  };

  const settle = () => {
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
    if (!browserOnline) return set(false);
    if (socketUp) return set(true);
    if (!online) return;
    timer = setTimeout(() => {
      timer = undefined;
      set(false);
    }, graceMs);
  };

  return {
    isOnline: () => online,
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    /** Starts watching. Returns the stop function. */
    start() {
      const onBrowser = () => {
        browserOnline = navigator.onLine;
        settle();
      };
      window.addEventListener("online", onBrowser);
      window.addEventListener("offline", onBrowser);
      socketUp = source.connectionState().isWebSocketConnected;
      const unsubscribe = source.subscribeToConnectionState((state) => {
        socketUp = state.isWebSocketConnected;
        settle();
      });
      onBrowser();
      return () => {
        window.removeEventListener("online", onBrowser);
        window.removeEventListener("offline", onBrowser);
        unsubscribe();
        if (timer !== undefined) clearTimeout(timer);
        timer = undefined;
      };
    },
  };
}
