import { useConvex } from "convex/react";
import { useEffect, useState } from "react";
import { CloudOff, Cloud } from "lucide-react";

/**
 * Venue wifi is unreliable and Convex is websocket-backed. A scout must be
 * able to see they are offline BEFORE keying in six minutes of match data.
 */
export function ConnectionIndicator() {
  const convex = useConvex();
  const [online, setOnline] = useState(true);

  useEffect(() => {
    const update = () => setOnline(navigator.onLine);
    update();
    window.addEventListener("online", update);
    window.addEventListener("offline", update);
    return () => {
      window.removeEventListener("online", update);
      window.removeEventListener("offline", update);
    };
  }, [convex]);

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
