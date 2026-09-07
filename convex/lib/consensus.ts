import { SCOUT_WEIGHTS, TIER_BASE, TIER_POSITION_BAND } from "./scoring";
import type { Tier, WeightTier } from "./types";

export type Vote = {
  voter: string;
  weightTier: WeightTier;
  tier: Exclude<Tier, "uncategorized">;
  /** 0-based position within its column. */
  index: number;
  columnSize: number;
  note: string;
};

/**
 * A vote's score. Position inside a column moves the score within a band that
 * can never reach the next tier's base, so "bottom of first pick" always beats
 * "top of second pick" — which is what a tiered list means.
 *
 * Do-not-pick is flat: ordering within it carries no information.
 */
export function scoreVote(vote: Pick<Vote, "tier" | "index" | "columnSize">): number {
  const base = TIER_BASE[vote.tier];
  if (vote.tier === "dnp") return base;
  const size = Math.max(1, vote.columnSize);
  return base + (TIER_POSITION_BAND * (size - vote.index)) / size;
}

export type Consensus = {
  score: number;
  voters: number;
  /** Unweighted, deliberately — see below. */
  spread: number;
  dnpCount: number;
  highest: number;
  lowest: number;
};

export function consensus(votes: Vote[]): Consensus {
  if (votes.length === 0) {
    return { score: 0, voters: 0, spread: 0, dnpCount: 0, highest: 0, lowest: 0 };
  }

  const scores = votes.map(scoreVote);
  const weights = votes.map((v) => SCOUT_WEIGHTS[v.weightTier]);
  const totalWeight = weights.reduce((a, b) => a + b, 0);

  const score =
    totalWeight === 0
      ? 0
      : scores.reduce((sum, s, i) => sum + s * (weights[i] ?? 1), 0) / totalWeight;

  // Spread stays UNWEIGHTED. It exists to show whether the room disagrees, and
  // weighting it would let one heavy vote hide exactly the disagreement the
  // number is there to surface.
  const mean = scores.reduce((a, b) => a + b, 0) / scores.length;
  const spread = Math.sqrt(
    scores.reduce((sum, s) => sum + (s - mean) ** 2, 0) / scores.length,
  );

  return {
    score,
    voters: votes.length,
    spread,
    dnpCount: votes.filter((v) => v.tier === "dnp").length,
    highest: Math.max(...scores),
    lowest: Math.min(...scores),
  };
}

/**
 * Turns a ranking into tiers by preserving how many teams the contributing
 * scouts put in each tier on average. Thresholding on raw score would let the
 * merge invent twenty first picks out of lists that each named three.
 */
export function assignTiers(
  ranked: { teamId: string; consensus: Consensus }[],
  targets: { t1: number; t2: number; t3: number },
): Map<string, Tier> {
  const out = new Map<string, Tier>();
  let i = 0;

  // Anyone with a do-not-pick vote and a negative consensus is set aside first,
  // so a veto is never silently averaged into a middling rank.
  const vetoed = ranked.filter((r) => r.consensus.dnpCount > 0 && r.consensus.score < 0);
  for (const row of vetoed) out.set(row.teamId, "dnp");

  const rest = ranked.filter((r) => !out.has(r.teamId));
  for (const [tier, count] of [
    ["t1", targets.t1] as const,
    ["t2", targets.t2] as const,
    ["t3", targets.t3] as const,
  ]) {
    for (let n = 0; n < count && i < rest.length; n++, i++) {
      const row = rest[i];
      if (row) out.set(row.teamId, tier);
    }
  }
  for (; i < rest.length; i++) {
    const row = rest[i];
    if (row) out.set(row.teamId, "uncategorized");
  }
  return out;
}
