import { useMutation, useQuery } from "convex/react";
import { AlertTriangle, Check, EyeOff, Wrench } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { api } from "../../convex/_generated/api";
import type { Id } from "../../convex/_generated/dataModel";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export type AttentionRow = {
  reportId: string;
  kind: "broke" | "inconsistent";
  teamNumber: number;
  nickname: string;
  matchNumber: number;
  scoutName: string;
  detail: string;
};

export const KIND_LABEL = {
  broke: "Broke down",
  inconsistent: "Inconsistent",
} as const;

/** Compact marker for a list row. */
export function AttentionBadge({ count }: { count: number }) {
  if (count === 0) return null;
  return (
    <Badge variant="destructive" className="shrink-0 text-[10px]">
      <AlertTriangle className="size-3" />
      {count}
    </Badge>
  );
}

export function AttentionCard({
  row,
  showTeam = false,
}: {
  row: AttentionRow;
  showTeam?: boolean;
}) {
  const settle = useMutation(api.attention.settle);
  const permissions = useQuery(api.attention.permissions);
  const [mode, setMode] = useState<"none" | "dismissed" | "resolved">("none");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [expanded, setExpanded] = useState(false);

  const detail = row.detail.trim();
  const long = detail.length > 90;
  const allowed = permissions?.canSettle ?? false;

  const run = () => {
    if (mode === "none") return;
    setBusy(true);
    void settle({
      reportId: row.reportId as Id<"matchReports">,
      kind: row.kind,
      state: mode,
      note,
    })
      .then(() => toast.success(mode === "resolved" ? "Marked resolved" : "Dismissed"))
      .catch((error: unknown) =>
        toast.error("Failed", {
          description: error instanceof Error ? error.message : String(error),
        }))
      .finally(() => setBusy(false));
  };

  return (
    <div className="border-destructive/60 space-y-2 rounded-lg border p-3">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant="destructive" className="text-xs">
          <AlertTriangle className="size-3" />
          {KIND_LABEL[row.kind]}
        </Badge>
        {showTeam ? (
          <span className="font-semibold tabular-nums">{row.teamNumber}</span>
        ) : null}
        <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
          {showTeam ? `${row.nickname} · ` : ""}Qual {row.matchNumber} · {row.scoutName}
        </span>
      </div>

      {detail ? (
        <p
          className={["text-sm", long && !expanded ? "line-clamp-1 cursor-pointer" : ""].join(" ")}
          title={long ? detail : undefined}
          onClick={() => long && setExpanded(!expanded)}
        >
          {detail}
        </p>
      ) : (
        <p className="text-muted-foreground text-sm italic">
          No reason given — worth asking the scout before acting on it.
        </p>
      )}

      {allowed ? (
        <>
          <div className="flex flex-wrap gap-2">
            <Button size="sm" variant="secondary"
              onClick={() => { setMode(mode === "resolved" ? "none" : "resolved"); setNote(""); }}>
              <Wrench className="size-3" /> Resolve
            </Button>
            <Button size="sm" variant="outline"
              onClick={() => { setMode(mode === "dismissed" ? "none" : "dismissed"); setNote(""); }}>
              <EyeOff className="size-3" /> Dismiss
            </Button>
          </div>

          {mode !== "none" ? (
            <div className="space-y-2 rounded-md border border-dashed p-3">
              <p className="text-muted-foreground text-xs">
                {mode === "resolved"
                  ? "Resolved says the problem was dealt with — a repair, a rematch, a conversation."
                  : "Dismissed says it was not really a problem."}{" "}
                Either way the note is what the next person reads.
              </p>
              <Input placeholder="What happened? (required)" value={note}
                onChange={(e) => setNote(e.target.value)} />
              <Button size="sm" variant={mode === "resolved" ? "secondary" : "default"}
                disabled={busy || note.trim() === ""} onClick={run}>
                <Check className="size-3" /> Confirm
              </Button>
            </div>
          ) : null}
        </>
      ) : null}
    </div>
  );
}
