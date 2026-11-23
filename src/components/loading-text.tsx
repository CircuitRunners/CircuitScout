import { useOnline } from "@/lib/offline/status";

export const NOT_SAVED = "Not saved on this device. Reconnect to load it.";

/**
 * "Loading…" while there is a connection. Without one, nothing is on its way:
 * a page that reaches this has no saved copy to show, and says so instead of
 * looking like it is still trying.
 */
export function LoadingText() {
  const online = useOnline();
  return <>{online ? "Loading…" : NOT_SAVED}</>;
}
