import { useQuery } from "convex/react";
import { AlertTriangle, ArrowLeft } from "lucide-react";
import { Link, useParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { CompareTable } from "@/components/compare-table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

type Robot = {
  teamNumber: number;
  nickname: string;
  stats: { avgTotalFuel: number; avgClimbPoints: number; reportCount: number };
  thisMatch: {
    scoutName: string;
    autoFuel: number;
    teleopFuel: number;
    deadFuel: number;
    endgameFuel: number;
    totalFuel: number;
    climbPoints: number;
    driver: number;
    defense: number;
    accuracy: number;
    broke: boolean;
    inconsistent: boolean;
    finalNotes: string;
  }[];
};

function projected(side: Robot[]) {
  return side.reduce(
    (sum, r) => sum + r.stats.avgTotalFuel + r.stats.avgClimbPoints,
    0,
  );
}

function Actuals({ side, label }: { side: Robot[]; label: string }) {
  const any = side.some((r) => r.thisMatch.length > 0);
  if (!any) return null;

  return (
    <div className="space-y-2">
      <h3 className="text-sm font-medium">{label} — what happened</h3>
      {side.map((robot) =>
        robot.thisMatch.map((report, i) => (
          <div key={`${robot.teamNumber}-${i}`} className="space-y-1 rounded-lg border p-3 text-sm">
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-medium tabular-nums">{robot.teamNumber}</span>
              <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                {robot.nickname} · {report.scoutName}
              </span>
            </div>
            <div className="text-muted-foreground flex flex-wrap gap-3 text-xs tabular-nums">
              <span>auto {report.autoFuel}</span>
              <span>teleop {report.teleopFuel}</span>
              <span>endgame {report.endgameFuel}</span>
              <span className="font-medium">total {report.totalFuel}</span>
              {report.deadFuel > 0 ? <span>dead {report.deadFuel}</span> : null}
              <span>climb {report.climbPoints}</span>
              <span>drv {report.driver}</span>
              <span>def {report.defense}</span>
              <span>acc {report.accuracy}%</span>
            </div>
            {report.broke || report.inconsistent ? (
              <p className="text-destructive flex items-center gap-1 text-xs">
                <AlertTriangle className="size-3" />
                {report.broke ? "Broke down" : ""}
                {report.broke && report.inconsistent ? " · " : ""}
                {report.inconsistent ? "Inconsistent" : ""}
              </p>
            ) : null}
            {report.finalNotes ? <p className="text-xs">{report.finalNotes}</p> : null}
          </div>
        )),
      )}
    </div>
  );
}

export default function MatchPreviewPage() {
  const epaData = useQuery(api.statbotics.forEvent);
  const params = useParams();
  const matchNumber = Number.parseInt(params.matchNumber ?? "", 10);
  const data = useQuery(
    api.stats.forMatch,
    Number.isNaN(matchNumber) ? "skip" : { matchNumber },
  );

  if (Number.isNaN(matchNumber)) {
    return <PageShell title="Match preview" description="Bad URL." />;
  }
  if (data === undefined) {
    return <PageShell title="Match preview" description="Loading…" />;
  }
  if (data === null) {
    return (
      <PageShell title="Match preview" description="That match is not at the active event.">
        <Button variant="outline" render={<Link to="/matches" />}>
          <ArrowLeft className="size-4" /> Back
        </Button>
      </PageShell>
    );
  }

  const epaByTeam = new Map((epaData?.rows ?? []).map((r) => [r.teamNumber, r.epa]));
  const epaSum = (side: Robot[]) =>
    side.reduce((sum, r) => sum + (epaByTeam.get(r.teamNumber) ?? 0), 0);
  const epaCovered = (side: Robot[]) =>
    side.filter((r) => epaByTeam.has(r.teamNumber)).length;

  const redProjected = projected(data.red);
  const blueProjected = projected(data.blue);

  const played = data.redScore !== null && data.blueScore !== null;
  // Predicted time is TBA's live estimate and beats the original schedule
  // once an event starts running late, which they always do.
  const whenMs = data.actualTime ?? data.predictedTime ?? data.scheduledTime;
  const when = whenMs === null ? null : new Date(whenMs);

  return (
    <PageShell
      title={`Qual ${data.matchNumber}`}
      description="Season averages predict; the reports below record what your scouts saw."
      actions={
        <Button variant="outline" render={<Link to="/matches" />}>
          <ArrowLeft className="size-4" /> All matches
        </Button>
      }
    >
      <div className="grid gap-4 md:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle>Projected · scouter data</CardTitle>
            <CardDescription>
              Sum of each robot's average total fuel and climb points. A crude
              estimate that ignores defense, field interference and robots with
              no data — a starting point, not a prediction.
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap items-center gap-6">
            <div>
              <p className="text-xs text-red-600 dark:text-red-400">Red</p>
              <p className="text-3xl font-semibold tabular-nums">
                {redProjected.toFixed(0)}
              </p>
            </div>
            <div>
              <p className="text-xs text-blue-600 dark:text-blue-400">Blue</p>
              <p className="text-3xl font-semibold tabular-nums">
                {blueProjected.toFixed(0)}
              </p>
            </div>
            {data.red.concat(data.blue).some((r) => r.stats.reportCount === 0) ? (
              <Badge variant="outline">Some robots have no data</Badge>
            ) : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Projected · EPA</CardTitle>
            <CardDescription>
              Statbotics EPA summed per alliance. Independent of your scouting,
              so a wide gap between the two is worth a look rather than a
              tiebreak.
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap items-center gap-6">
            {epaData === undefined ? (
              <p className="text-muted-foreground text-sm">Loading…</p>
            ) : epaByTeam.size === 0 ? (
              <p className="text-muted-foreground text-sm">
                No EPA yet — an admin can pull it from the Admin page.
              </p>
            ) : (
              <>
                <div>
                  <p className="text-xs text-red-600 dark:text-red-400">Red</p>
                  <p className="text-3xl font-semibold tabular-nums">
                    {epaSum(data.red).toFixed(0)}
                  </p>
                </div>
                <div>
                  <p className="text-xs text-blue-600 dark:text-blue-400">Blue</p>
                  <p className="text-3xl font-semibold tabular-nums">
                    {epaSum(data.blue).toFixed(0)}
                  </p>
                </div>
                {epaCovered(data.red) + epaCovered(data.blue) < 6 ? (
                  <Badge variant="outline">
                    Only {epaCovered(data.red) + epaCovered(data.blue)} of 6 have EPA
                  </Badge>
                ) : null}
              </>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{played ? "Actual score" : "Scheduled"}</CardTitle>
            <CardDescription>
              {played
                ? "Official result from The Blue Alliance, as of the last import."
                : "Not played yet. Times from The Blue Alliance drift during an event."}
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap items-center gap-6">
            {played ? (
              <>
                <div>
                  <p className="text-xs text-red-600 dark:text-red-400">
                    Red{data.winningAlliance === "red" ? " · won" : ""}
                  </p>
                  <p
                    className={[
                      "text-3xl tabular-nums",
                      data.winningAlliance === "red" ? "font-bold" : "font-semibold",
                    ].join(" ")}
                  >
                    {data.redScore}
                  </p>
                </div>
                <div>
                  <p className="text-xs text-blue-600 dark:text-blue-400">
                    Blue{data.winningAlliance === "blue" ? " · won" : ""}
                  </p>
                  <p
                    className={[
                      "text-3xl tabular-nums",
                      data.winningAlliance === "blue" ? "font-bold" : "font-semibold",
                    ].join(" ")}
                  >
                    {data.blueScore}
                  </p>
                </div>
                {data.winningAlliance === "" ? (
                  <Badge variant="outline">Tie</Badge>
                ) : null}
              </>
            ) : (
              <div>
                <p className="text-2xl font-semibold">
                  {when === null ? "Time unknown" : when.toLocaleTimeString([], {
                    hour: "numeric", minute: "2-digit",
                  })}
                </p>
                {when !== null ? (
                  <p className="text-muted-foreground text-xs">
                    {when.toLocaleDateString()}
                    {data.predictedTime !== null ? " · predicted" : " · scheduled"}
                  </p>
                ) : null}
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      {/* Scores are only as fresh as the last import — say so rather than
          letting a stale number read as live. */}
      <p className="text-muted-foreground text-xs">
        Scores and times come from the last TBA import
        {data.importedAt !== null
          ? ` (${new Date(data.importedAt).toLocaleString()})`
          : ""}
        . An admin re-importing the event refreshes them.
      </p>

      <h3 className="font-medium text-red-600 dark:text-red-400">Red alliance</h3>
      <CompareTable columns={data.red} />

      <h3 className="font-medium text-blue-600 dark:text-blue-400">Blue alliance</h3>
      <CompareTable columns={data.blue} />

      <Actuals side={data.red} label="Red" />
      <Actuals side={data.blue} label="Blue" />
    </PageShell>
  );
}
