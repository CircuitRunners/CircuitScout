import { create } from "zustand";
import type { Tier } from "@/lib/types";

/**
 * Ephemeral, client-only UI state.
 *
 * Allowed: selection, active tab, panel/sidebar/dialog open, drag state,
 * transient editor state, local view preferences.
 *
 * NOT allowed: anything persisted or owned by Convex. Never mirror a query
 * result into this store — subscribe with useQuery instead.
 */
export type SortKey = "totalFuel" | "climbPoints" | "defense" | "driver";
export type SortDirection = "asc" | "desc";

type UIState = {
  navOpen: boolean;
  draggingTeamId: string | null;
  /** Sorting Uncategorized is a VIEW, never a rewrite of stored order. */
  uncategorizedSort: { key: SortKey; direction: SortDirection } | null;
  activeTier: Tier;
  matchFormPeriod: "auto" | "teleop" | "endgame" | "conclusion";
  /** Which auto-path input the scout prefers. Buttons are the fallback. */
  autoInputMode: "map" | "buttons";
};

type UIActions = {
  setNavOpen: (open: boolean) => void;
  toggleNav: () => void;
  setDraggingTeamId: (id: string | null) => void;
  setUncategorizedSort: (sort: UIState["uncategorizedSort"]) => void;
  setActiveTier: (tier: Tier) => void;
  setMatchFormPeriod: (period: UIState["matchFormPeriod"]) => void;
  setAutoInputMode: (mode: UIState["autoInputMode"]) => void;
  reset: () => void;
};

const initial: UIState = {
  navOpen: false,
  draggingTeamId: null,
  uncategorizedSort: null,
  activeTier: "uncategorized",
  matchFormPeriod: "auto",
  autoInputMode: "map",
};

export const useUIStore = create<UIState & UIActions>()((set) => ({
  ...initial,
  setNavOpen: (navOpen) => set({ navOpen }),
  toggleNav: () => set((s) => ({ navOpen: !s.navOpen })),
  setDraggingTeamId: (draggingTeamId) => set({ draggingTeamId }),
  setUncategorizedSort: (uncategorizedSort) => set({ uncategorizedSort }),
  setActiveTier: (activeTier) => set({ activeTier }),
  setMatchFormPeriod: (matchFormPeriod) => set({ matchFormPeriod }),
  setAutoInputMode: (autoInputMode) => set({ autoInputMode }),
  reset: () => set(initial),
}));
