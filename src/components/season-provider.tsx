import { useQuery } from "convex/react";
import { useMemo, type ReactNode } from "react";

import { api } from "../../convex/_generated/api";
import { SeasonContext, seasonOf, type SeasonState } from "@/lib/season";

/**
 * The one subscription to the active event, at the top of the app. Every page
 * reads the season from here instead of querying for it, and when an admin
 * activates a different event Convex pushes it to every open phone.
 */
export function SeasonProvider({ children }: { children: ReactNode }) {
  const event = useQuery(api.events.active);
  const value = useMemo<SeasonState>(() => ({
    loading: event === undefined,
    event: event ?? null,
    year: event ? seasonOf(event.tbaEventKey) : null,
  }), [event]);
  return <SeasonContext.Provider value={value}>{children}</SeasonContext.Provider>;
}
