import { Badge } from "@/components/ui/badge";

/** "#4", or nothing for an unranked team. */
export function RankBadge({ rank, className }: { rank: number | null | undefined; className?: string }) {
  if (rank === null || rank === undefined) return null;
  return (
    <Badge variant="outline" title={`TBA rank ${rank}`}
      className={["shrink-0 tabular-nums", className ?? ""].join(" ")}>
      #{rank}
    </Badge>
  );
}

/** The rank beside the EPA/xP card in a team modal. */
export function RankCard({ rank, total }: { rank: number | null | undefined; total: number }) {
  if (rank === null || rank === undefined) return null;
  return (
    <div className="rounded-lg border p-3">
      <p className="text-muted-foreground text-xs">Rank</p>
      <p className="text-xl font-semibold tabular-nums">
        {rank}
        <span className="text-muted-foreground text-sm font-normal"> of {total}</span>
      </p>
      <p className="text-muted-foreground text-[10px]">The Blue Alliance</p>
    </div>
  );
}
