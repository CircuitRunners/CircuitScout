import { CloudOff, Cloud } from "lucide-react";

import { useOnline } from "@/lib/offline/status";

/**
 * Venue wifi is unreliable and Convex is websocket-backed. A scout must be
 * able to see they are offline BEFORE keying in six minutes of match data.
 *
 * Reads useOnline(), which trusts the Convex socket rather than
 * navigator.onLine alone: wifi that is joined but passes no traffic shows
 * Offline here, where it used to show Live.
 */
export function ConnectionIndicator() {
  const online = useOnline();

  if (online) {
    return (
      <span className="text-muted-foreground flex items-center gap-1.5 text-xs">
        <Cloud className="size-3.5" />
        <span className="hidden sm:inline">Live</span>
      </span>
    );
  }

  return (
    <span className="flex items-center gap-1.5 rounded-md bg-destructive px-2 py-1 text-xs font-medium text-white">
      <CloudOff className="size-3.5" />
      Offline
    </span>
  );
}
