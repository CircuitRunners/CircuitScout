import { useSortable } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import {
  Check, GripVertical, MessageSquare, MessageSquareWarning,
} from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";

export type ChipStats = {
  reportCount: number;
  avgTotalFuel: number;
  avgDriver: number;
  avgDefense: number;
  avgAccuracy: number;
  avgClimbPoints: number;
  avgAdjustedBps: number;
};

export function TeamChip({
  entryId,
  teamNumber,
  nickname,
  pitScouted,
  stats,
  draggable,
  note,
  needsNote,
  picked = false,
  onTogglePicked,
  onOpen,
}: {
  entryId: string;
  teamNumber: number;
  nickname: string;
  pitScouted: boolean;
  stats: ChipStats | null;
  draggable: boolean;
  note: string;
  needsNote: boolean;
  picked?: boolean;
  onTogglePicked?: () => void;
  onOpen: () => void;
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } =
    useSortable({ id: entryId, disabled: !draggable });

  return (
    <div
      ref={setNodeRef}
      style={{ transform: CSS.Translate.toString(transform), transition }}
      className={[
        "bg-background rounded-lg border p-2",
        isDragging ? "opacity-40" : "",
      ].join(" ")}
    >
      <div className="flex items-center gap-1.5">
        {draggable ? (
          // The grip is the only drag handle, so the rest of the card stays
          // tappable and the column stays scrollable.
          <button
            {...attributes}
            {...listeners}
            aria-label={`Reorder team ${teamNumber}`}
            className="text-muted-foreground touch-none p-1"
          >
            <GripVertical className="size-4" />
          </button>
        ) : null}
        <button onClick={onOpen} className="min-w-0 flex-1 text-left">
          <span className="font-semibold tabular-nums">{teamNumber}</span>
          <span className="text-muted-foreground ml-1.5 text-xs">{nickname}</span>
        </button>
        {needsNote ? (
          <MessageSquareWarning className="text-destructive size-4 shrink-0" />
        ) : note ? (
          <MessageSquare className="text-muted-foreground size-4 shrink-0" />
        ) : null}
        {onTogglePicked ? (
          <Button size="icon" variant={picked ? "secondary" : "ghost"}
            className="size-6 shrink-0"
            aria-label={picked ? `Unmark ${teamNumber} as picked` : `Mark ${teamNumber} as picked`}
            onClick={(e) => { e.stopPropagation(); onTogglePicked(); }}>
            <Check className="size-3.5" />
          </Button>
        ) : null}
        <Badge variant={pitScouted ? "secondary" : "outline"} className="shrink-0 text-[10px]">
          {pitScouted ? "Pit" : "No pit"}
        </Badge>
      </div>
      {stats && stats.reportCount > 0 ? (
        <div className="text-muted-foreground mt-1 flex flex-wrap gap-x-2.5 gap-y-0.5 pl-1 text-[11px] tabular-nums">
          <span>fuel {stats.avgTotalFuel.toFixed(0)}</span>
          <span>climb {stats.avgClimbPoints.toFixed(0)}</span>
          <span>drv {stats.avgDriver.toFixed(1)}</span>
          <span>def {stats.avgDefense.toFixed(1)}</span>
          <span>acc {stats.avgAccuracy.toFixed(0)}%</span>
          <span>adj bps {stats.avgAdjustedBps.toFixed(1)}</span>
          <span className="opacity-70">n={stats.reportCount}</span>
        </div>
      ) : (
        <p className="text-muted-foreground mt-1 pl-1 text-[11px]">
          No match data — unscouted is not the same as bad.
        </p>
      )}
      {note ? (
        <p className="mt-1 line-clamp-2 pl-1 text-[11px] italic">{note}</p>
      ) : null}
    </div>
  );
}
