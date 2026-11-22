import { useQuery } from "convex/react";
import type { ReactNode } from "react";

import { api } from "../../../convex/_generated/api";
import { StatLinks } from "@/components/stat-links";
import { useRatings } from "@/lib/stat-site";
import { useRanks } from "@/lib/ranks";
import { RankCard } from "@/components/team-rank";
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
  const ranks = useRanks();
  const rank = teamNumber === null ? null : (ranks.byTeam.get(teamNumber) ?? null);

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

            {rating || rank !== null ? (
              <div className="flex flex-wrap gap-2">
              {rating ? (
                <div className="rounded-lg border p-3">
                  <p className="text-muted-foreground text-xs">{ratings.metric}</p>
                  <p className="text-xl font-semibold tabular-nums">{rating.total.toFixed(1)}</p>
                  <p className="text-muted-foreground text-[10px]">
                    {ratings.siteName}, not your scouting
                  </p>
                </div>
              ) : null}
                <RankCard rank={rank} total={ranks.total} />
              </div>
            ) : null}

            <div className="space-y-2">
              <h3 className="font-medium">Pit report</h3>
              {data.pit && data.pit.status !== "none" ? (
                <div className="space-y-2 rounded-lg border p-3">
                  {data.pit.status === "partial" ? (
                    <p className="text-muted-foreground text-xs">
                      Partially scouted. Still needed: {data.pit.missing.join(", ")}.
                    </p>
                  ) : null}
                  {data.pit.photoUrl ? (
                    <img src={data.pit.photoUrl} alt={`Team ${data.team.number} robot`}
                      className="max-h-56 w-full rounded-md object-contain" />
                  ) : null}
                  <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-sm">
                    {([
                      ["Scoring", data.pit.scoringText],
                      ["Drivetrain", data.pit.drivetrain],
                      ["Gearing", data.pit.drivetrainGearing],
                      ["Weight", data.pit.robotWeight === null ? "" : `${data.pit.robotWeight} lbs`],
                      ["Spares", data.pit.spares.join(" · ")],
                      ["Batteries (good)", data.pit.batteries.join(" · ")],
                    ] as const).filter(([, value]) => value !== "").map(([label, value]) => (
                      <div key={label} className="contents">
                        <dt className="text-muted-foreground">{label}</dt>
                        <dd className="whitespace-pre-wrap break-words">{value}</dd>
                      </div>
                    ))}
                  </dl>
                  {data.pit.notes ? <p className="text-sm whitespace-pre-wrap">{data.pit.notes}</p> : null}
                  {data.pit.otherNotes ? (
                    <p className="text-muted-foreground text-sm whitespace-pre-wrap">{data.pit.otherNotes}</p>
                  ) : null}
                  <p className="text-muted-foreground text-xs">
                    {data.pit.scoutName} · {new Date(data.pit.updatedAt).toLocaleString()}
                  </p>
                </div>
              ) : (
                <p className="text-muted-foreground text-sm">Your team has not pit scouted them yet.</p>
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
                      {n.sections.length > 0 ? (
                        <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-0.5 text-sm">
                          {n.sections.map(([label, value]) => (
                            <div key={label} className="contents">
                              <dt className="text-muted-foreground">{label}</dt>
                              <dd className="break-words whitespace-pre-wrap">{value}</dd>
                            </div>
                          ))}
                        </dl>
                      ) : null}
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
