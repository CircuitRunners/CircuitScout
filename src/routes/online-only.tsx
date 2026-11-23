import { Outlet } from "react-router";

import { NeedsConnection } from "@/components/needs-connection";
import { useOnline } from "@/lib/offline/status";

/**
 * Route wrapper for pages that are not cached and cannot do anything useful
 * offline (My profile, Past Events). Offline they say so instead of spinning.
 */
export function OnlineOnly() {
  const online = useOnline();
  return online ? <Outlet /> : <NeedsConnection />;
}
