import { useQuery } from "convex/react";
import { useMemo } from "react";

import { api } from "../../convex/_generated/api";

export type StatSite = "statbotics" | "match13";

export type Rating = {
  total: number;
  auto: number | null;
  teleop: number | null;
  endgame: number | null;
};

export const STAT_SITE_NAME: Record<StatSite, string> = {
  statbotics: "Statbotics",
  match13: "match13",
};

export const STAT_SITE_METRIC: Record<StatSite, string> = {
  statbotics: "EPA",
  match13: "xP",
};

/**
 * The rating the user's team has chosen, Statbotics EPA or match13 xP, keyed
 * by team number. Only the chosen source is subscribed to; the other query
 * is skipped rather than read and thrown away.
 *
 * The data plot does not use this: it offers both, whatever is chosen.
 */
export function useRatings() {
  const choice = useQuery(api.statSite.mine);
  const site = choice?.effective;
  const epa = useQuery(api.statbotics.forEvent, site === "statbotics" ? {} : "skip");
  const xp = useQuery(api.match13.forEvent, site === "match13" ? {} : "skip");

  const byTeam = useMemo(() => {
    const map = new Map<number, Rating>();
    if (site === "statbotics") {
      for (const r of epa?.rows ?? []) {
        map.set(r.teamNumber, {
          total: r.epa, auto: r.autoEpa, teleop: r.teleopEpa, endgame: r.endgameEpa,
        });
      }
    } else if (site === "match13") {
      for (const r of xp?.rows ?? []) {
        map.set(r.teamNumber, {
          total: r.xp, auto: r.autoXp, teleop: r.teleopXp, endgame: r.endgameXp,
        });
      }
    }
    return map;
  }, [site, epa, xp]);

  const loading =
    site === "statbotics" ? epa === undefined
      : site === "match13" ? xp === undefined
        : true;
  const shown: StatSite = site ?? "statbotics";

  return {
    loading,
    site: shown,
    siteName: STAT_SITE_NAME[shown],
    metric: STAT_SITE_METRIC[shown],
    byTeam,
  };
}
