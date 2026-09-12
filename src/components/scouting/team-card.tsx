import { Badge } from "@/components/ui/badge";
import { AttentionBadge } from "@/components/attention-items";
import { TIER_LABELS, type Tier } from "@/lib/types";

/**
 * Shared by the team list, the pit grid and the pick list board.
 * `n` is shown next to every average elsewhere for the same reason the report
 * count appears here: an average over two matches is not an average over ten.
 */
export function TeamCard({
  number,
  nickname,
  pitScouted,
  reportCount,
  tier,
  attention = 0,
  onClick,
}: {
  number: number;
  nickname: string;
  pitScouted: boolean;
  reportCount: number;
  tier?: Tier;
  attention?: number;
  onClick?: () => void;
}) {
  const Wrapper = onClick ? "button" : "div";
  return (
    <Wrapper
      onClick={onClick}
      className="hover:bg-accent/50 flex w-full min-h-16 items-center gap-3 rounded-lg border p-3 text-left transition-colors"
    >
      <span className="w-14 shrink-0 text-lg font-semibold tabular-nums">{number}</span>
      <span className="min-w-0 flex-1 truncate text-sm">{nickname}</span>
      <div className="flex shrink-0 items-center gap-1.5">
        <AttentionBadge count={attention} />
        {tier && tier !== "uncategorized" ? (
          <Badge variant="secondary">{TIER_LABELS[tier]}</Badge>
        ) : null}
        <Badge variant={pitScouted ? "default" : "outline"}>
          {pitScouted ? "Pit" : "No pit"}
        </Badge>
        <Badge variant="outline">{reportCount} rpt</Badge>
      </div>
    </Wrapper>
  );
}
