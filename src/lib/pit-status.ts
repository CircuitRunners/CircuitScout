import type { PitStatus } from "../../convex/lib/pitStatus";

export * from "../../convex/lib/pitStatus";

/** Short pit labels for team cards and pick list chips. */
export const PIT_BADGE: Record<PitStatus, { text: string; variant: "default" | "secondary" | "outline" }> = {
  complete: { text: "Pit", variant: "default" },
  partial: { text: "Partial pit", variant: "secondary" },
  none: { text: "No pit", variant: "outline" },
};
