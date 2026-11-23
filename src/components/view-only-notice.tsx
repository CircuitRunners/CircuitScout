import { Eye } from "lucide-react";
import { useLocation } from "react-router";

import { useOnline } from "@/lib/offline/status";

/** Pages that can be read offline but not changed (offline plan, O-7). */
const VIEW_ONLY = /^\/(picklists|admin)(\/|$)/;

/**
 * Under the offline banner on pick lists and Admin: what is on screen is the
 * last copy this device loaded, and every control that would change it is
 * turned off until the connection returns.
 */
export function ViewOnlyNotice() {
  const online = useOnline();
  const { pathname } = useLocation();
  if (online || !VIEW_ONLY.test(pathname)) return null;
  return (
    <div
      role="status"
      className="bg-muted text-muted-foreground flex items-center justify-center gap-2 border-b px-4 py-1.5 text-center text-xs"
    >
      <Eye className="size-3.5 shrink-0" aria-hidden />
      <span>View only while offline. Changes are turned off until you reconnect.</span>
    </div>
  );
}
