import { useQuery } from "convex/react";
import type { ReactNode } from "react";
import { AlertTriangle, Pencil, Wrench } from "lucide-react";

import { api } from "../../../convex/_generated/api";
import { AttentionCard, type AttentionRow } from "@/components/attention-items";
import { Badge } from "@/components/ui/badge";
import {
  Dialog, DialogContent, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { TIER_LABELS, type Tier } from "@/lib/types";

function Stat({
  label, value, suffix = "",
}: { label: string; value: number; suffix?: string }) {
  return (
    <div className="rounded-lg border p-3">
      <p className="text-muted-foreground text-xs">{label}</p>
      <p className="text-xl font-semibold tabular-nums">
        {value.toFixed(1)}{suffix}
      </p>
    </div>
  );
}

const CLIMB_LABEL: Record<string, string> = {
  none: "—", low: "L1", mid: "L2", high: "L3",
};

function useEpa(teamNumber: number | null) {
  const data = useQuery(api.statbotics.forEvent);
  if (teamNumber === null) return null;
  return data?.rows.find((r) => r.teamNumber === teamNumber) ?? null;
}

export function TeamDetail({
  teamNumber,
  onClose,
  footer,
}: {
  teamNumber: number | null;
  onClose: () => void;
  /** Rendered at the bottom of the modal. The pick list passes its note editor. */
  footer?: ReactNode;
}) {
  const data = useQuery(
    api.teams.detail,
    teamNumber === null ? "skip" : { teamNumber },
  );
  const epa = useEpa(teamNumber);
  const attention = useQuery(api.attention.forEvent);
  const mine = (attention ?? []).filter((row) => row.teamNumber === teamNumber);

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
                {data.tier !== "uncategorized" ? (
                  <Badge>{TIER_LABELS[data.tier as Tier]}</Badge>
                ) : null}
              </DialogTitle>
            </DialogHeader>

            <p className="text-muted-foreground text-sm">
              {[data.team.city, data.team.stateProv, data.team.country]
                .filter(Boolean)
                .join(", ")}
            </p>

            {mine.length > 0 ? (
              <div className="space-y-2">
                {mine.map((row) => (
                  <AttentionCard key={`${row.reportId}-${row.kind}`}
                    row={row as AttentionRow} />
                ))}
              </div>
            ) : null}

            {/* Report count sits next to the averages deliberately: an average
                over two matches and one over eleven are not comparable, and a
                bare number invites treating them as if they were. */}
              {epa ? (
                <div className="rounded-lg border p-3">
                  <p className="text-muted-foreground text-xs">EPA</p>
                  <p className="text-xl font-semibold tabular-nums">
                    {epa.epa.toFixed(1)}
                  </p>
                  <p className="text-muted-foreground text-[10px]">
                    Statbotics, not your scouting
                  </p>
                </div>
              ) : null}
            <div className="flex items-baseline gap-2">
              <h3 className="font-medium">Averages</h3>
              <span className="text-muted-foreground text-xs">
                from {data.stats.reportCount} report
                {data.stats.reportCount === 1 ? "" : "s"}
              </span>
            </div>

            {data.stats.reportCount === 0 ? (
              <p className="text-muted-foreground rounded-lg border border-dashed p-6 text-center text-sm">
                No match reports yet.
              </p>
            ) : (
              <>
                <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
                  <Stat label="Auto fuel" value={data.stats.avgAutoFuel} />
                  <Stat label="Teleop fuel" value={data.stats.avgTeleopFuel} />
                  <Stat label="Endgame fuel" value={data.stats.avgEndgameFuel} />
                  <Stat label="Total fuel" value={data.stats.avgTotalFuel} />
                  <Stat label="Climb points" value={data.stats.avgClimbPoints} />
                  <Stat label="Driver" value={data.stats.avgDriver} />
                  <Stat label="Defense" value={data.stats.avgDefense} />
                  <Stat label="Accuracy" value={data.stats.avgAccuracy} suffix="%" />
                  <Stat label="Dead-hub fuel" value={data.stats.avgUncountedFuel} />
                  {data.stats.bpsReportCount > 0 ? (
                    <>
                      <Stat label="Avg BPS" value={data.stats.avgBps} />
                      <Stat label="Adjusted BPS" value={data.stats.avgAdjustedBps} />
                    </>
                  ) : null}
                </div>

                {/* A mean of 30 could be 30/30/30 or 5/85/0, and consistency
                    is often what decides a second-round pick. */}
                <p className="text-muted-foreground text-xs">
                  Total fuel ranged {data.stats.minTotalFuel}–
                  {data.stats.maxTotalFuel} across those matches. Total fuel
                  counts only fuel scored into a live hub.
                </p>
              </>
            )}

            <h3 className="font-medium">Pit report</h3>
            {data.pitReport === null ? (
              <p className="text-muted-foreground rounded-lg border border-dashed p-6 text-center text-sm">
                Not pit scouted.
              </p>
            ) : (
              <div className="space-y-3 rounded-lg border p-3">
                {data.photoUrl ? (
                  <img src={data.photoUrl} alt={`Team ${data.team.number} robot`}
                    className="max-h-56 w-full rounded-md object-contain" />
                ) : null}
                <div className="flex flex-wrap gap-1">
                  {data.pitReport.scoring.turret ? <Badge variant="secondary">Turret</Badge> : null}
                  {data.pitReport.scoring.drumFullWidth ? <Badge variant="secondary">Full-width drum</Badge> : null}
                  {data.pitReport.scoring.drumNonFullWidth ? <Badge variant="secondary">Drum</Badge> : null}
                  {data.pitReport.scoring.fixed ? <Badge variant="secondary">Fixed shooter</Badge> : null}
                  {data.pitReport.scoring.kitbot ? <Badge variant="secondary">Kitbot</Badge> : null}
                  {data.pitReport.scoring.other ? (
                    <Badge variant="secondary">{data.pitReport.scoring.otherText || "Other"}</Badge>
                  ) : null}
                </div>
                <div className="flex flex-wrap gap-1">
                  {data.pitReport.climb.low ? <Badge variant="outline">L1</Badge> : null}
                  {data.pitReport.climb.mid ? <Badge variant="outline">L2</Badge> : null}
                  {data.pitReport.climb.high ? <Badge variant="outline">L3</Badge> : null}
                  {data.pitReport.climb.duringAuto ? <Badge variant="outline">Auto climb</Badge> : null}
                  {data.pitReport.underTrench ? <Badge variant="outline">Under trench</Badge> : null}
                  {data.pitReport.overBump ? <Badge variant="outline">Over bump</Badge> : null}
                </div>
                <p className="text-sm">
                  <Wrench className="mr-1 inline size-3" />
                  {data.pitReport.drivetrain || "Drivetrain not recorded"}
                </p>
                {data.pitReport.robotNotes ? (
                  <p className="text-sm">{data.pitReport.robotNotes}</p>
                ) : null}
                {data.pitReport.otherNotes ? (
                  <p className="text-muted-foreground text-sm">{data.pitReport.otherNotes}</p>
                ) : null}
                <p className="text-muted-foreground text-xs">
                  Scouted by {data.pitScoutName}
                </p>
              </div>
            )}

            <h3 className="font-medium">Match reports</h3>
            {data.reports.length === 0 ? (
              <p className="text-muted-foreground rounded-lg border border-dashed p-6 text-center text-sm">
                Nothing yet.
              </p>
            ) : (
              <div className="space-y-2">
                {data.reports.map((r) => (
                  <div key={r.reportId} className="space-y-1 rounded-lg border p-3 text-sm">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="font-medium">Qual {r.matchNumber}</span>
                      <Badge variant="outline" className="text-xs">{r.alliance}</Badge>
                      <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                        {r.scoutName}
                      </span>
                      {r.editCount > 0 ? (
                        <Badge variant="secondary" className="text-xs">
                          <Pencil className="size-3" />
                          edited
                        </Badge>
                      ) : null}
                      {r.hubStateSource === "none" ? (
                        <Badge variant="outline" className="text-xs">no shift split</Badge>
                      ) : null}
                    </div>
                    <div className="text-muted-foreground flex flex-wrap gap-3 text-xs tabular-nums">
                      <span>auto {r.autoFuel}</span>
                      <span>teleop {r.teleopFuel}</span>
                      <span>endgame {r.endgameFuel}</span>
                      <span className="font-medium">total {r.totalFuel}</span>
                      {r.deadFuel > 0 ? <span>dead {r.deadFuel}</span> : null}
                      <span>climb {CLIMB_LABEL[r.climb] ?? "—"}{r.autoClimb ? " +auto" : ""}</span>
                      <span>drv {r.driver}</span>
                      <span>def {r.defense}</span>
                      <span>acc {r.accuracy}%</span>
                    </div>
                    {r.broke || r.inconsistent ? (
                      <p className="text-destructive flex items-start gap-1 text-xs">
                        <AlertTriangle className="mt-0.5 size-3 shrink-0" />
                        {[r.broke ? `Broke: ${r.brokeNotes || "no detail"}` : null,
                          r.inconsistent ? `Inconsistent: ${r.inconsistentNotes || "no detail"}` : null]
                          .filter(Boolean).join(" · ")}
                      </p>
                    ) : null}
                    {r.finalNotes ? <p className="text-xs">{r.finalNotes}</p> : null}
                  </div>
                ))}
              </div>
            )}
            {footer}
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}
