import { useQuery } from "convex/react";
import { useMemo } from "react";

import { api } from "../../convex/_generated/api";

/**
 * TBA rank by team number for the active event, and how many teams are
 * ranked. Rank 1 is best; a team missing from the map is unranked (quals not
 * started, or TBA has not caught up).
 */
export function useRanks() {
  const data = useQuery(api.ranks.forEvent);
  return useMemo(() => {
    const byTeam = new Map<number, number>();
    for (const row of data ?? []) byTeam.set(row.teamNumber, row.rank);
    return { loading: data === undefined, byTeam, total: byTeam.size };
  }, [data]);
}

/** Sorts rank 1 first and unranked teams last, in either direction. */
export function compareRanks(a: number | undefined, b: number | undefined, bestFirst = true): number {
  if (a === b) return 0;
  if (a === undefined) return 1;
  if (b === undefined) return -1;
  return bestFirst ? a - b : b - a;
}
