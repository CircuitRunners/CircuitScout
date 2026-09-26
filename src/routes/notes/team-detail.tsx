import { useQuery } from "convex/react";
import type { ReactNode } from "react";

import { api } from "../../../convex/_generated/api";
import { StatLinks } from "@/components/stat-links";
import { useRatings } from "@/lib/stat-site";
import {
  Dialog, DialogContent, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";

/**
 * A team in a notes-only season: its rating from the chosen stat site, your
 * team's pit notes, and every match note written about it. No averages,
 * because nothing here is counted.
 */
export function NotesTeamDetail({
  teamNumber, onClose, footer,
}: {
  teamNumber: number | null;
  onClose: () => void;
  /** Rendered at the bottom. The pick list passes its note editor. */
  footer?: ReactNode;
}) {
  const data = useQuery(api.notes.forTeam, teamNumber === null ? "skip" : { teamNumber });
  const ratings = useRatings();
  const rating = teamNumber === null ? null : (ratings.byTeam.get(teamNumber) ?? null);

  return (
    <Dialog open={teamNumber !== null} onOpenChange={(open) => { if (!open) onClose(); }}>
      <DialogContent className="max-h-[85vh] max-w-3xl overflow-y-auto">
        {data === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) : data === null ? (
          <p className="text-muted-foreground text-sm">Team not found.</p>
        ) : (
          <>
            <DialogHeader>
              <DialogTitle className="flex flex-wrap items-center gap-2">
                <span className="tabular-nums">{data.team.number}</span>
                <span>{data.team.nickname}</span>
                <StatLinks kind="team" eventKey={data.eventKey} teamNumber={data.team.number} />
              </DialogTitle>
            </DialogHeader>

            <p className="text-muted-foreground text-sm">
              {[data.team.city, data.team.stateProv, data.team.country].filter(Boolean).join(", ")}
            </p>

            {rating ? (
              <div className="w-fit rounded-lg border p-3">
                <p className="text-muted-foreground text-xs">{ratings.metric}</p>
                <p className="text-xl font-semibold tabular-nums">{rating.total.toFixed(1)}</p>
                <p className="text-muted-foreground text-[10px]">
                  {ratings.siteName}, not your scouting
                </p>
              </div>
            ) : null}

            <div className="space-y-2">
              <h3 className="font-medium">Pit notes</h3>
              {data.pit ? (
                <div className="space-y-1 rounded-lg border p-3">
                  <p className="text-sm whitespace-pre-wrap">{data.pit.notes}</p>
                  <p className="text-muted-foreground text-xs">
                    {data.pit.scoutName} · {new Date(data.pit.updatedAt).toLocaleString()}
                  </p>
                </div>
              ) : (
                <p className="text-muted-foreground text-sm">Your team has no pit notes on them yet.</p>
              )}
            </div>

            <div className="space-y-2">
              <h3 className="font-medium">Match notes</h3>
              {data.matches.length === 0 ? (
                <p className="text-muted-foreground rounded-lg border border-dashed p-6 text-center text-sm">
                  No match notes yet.
                </p>
              ) : (
                <div className="space-y-2">
                  {data.matches.map((n) => (
                    <div key={n.id} className="space-y-1 rounded-lg border p-3">
                      <p className="text-xs font-medium">
                        {n.matchNumber === null ? "Unknown match" : `Qual ${n.matchNumber}`}
                        <span className="text-muted-foreground font-normal"> · {n.scoutName}</span>
                      </p>
                      <p className="text-sm whitespace-pre-wrap">{n.notes}</p>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {footer}
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}
