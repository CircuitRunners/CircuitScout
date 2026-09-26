import { createContext, useContext } from "react";
import type { FunctionReturnType } from "convex/server";

import type { api } from "../../convex/_generated/api";

export type ActiveEvent = NonNullable<FunctionReturnType<typeof api.events.active>>;

export type SeasonState = {
  /** True until the active event has loaded once. */
  loading: boolean;
  event: ActiveEvent | null;
  /** The event's season, from its key. Null with no active event. */
  year: number | null;
};

/** TBA event keys always start with the season: 2026gadal is 2026. */
export function seasonOf(eventKey: string): number | null {
  const year = Number.parseInt(eventKey.slice(0, 4), 10);
  return Number.isNaN(year) ? null : year;
}

export const SeasonContext = createContext<SeasonState>({
  loading: true, event: null, year: null,
});

/** The active event and its season, from the one subscription in the layout. */
export function useSeason(): SeasonState {
  return useContext(SeasonContext);
}
