import { useQuery } from "convex/react";
import { Link } from "react-router";
import { useState } from "react";
import { ExternalLink } from "lucide-react";

import { api } from "../../convex/_generated/api";
import { ShiftRow } from "@/components/shift-picker";
import { STATION_LABELS, type Station } from "@/lib/types";
import { PageShell } from "./page-shell";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

/**
 * The mark is hotlinked from TBA, so it can fail — a blocked request, an
 * offline venue, a changed path. Falls back to a generic external-link icon
 * rather than leaving a broken image in the page heading.
 */
function TbaLink({ eventKey }: { eventKey: string }) {
  const [markFailed, setMarkFailed] = useState(false);

  return (
    <a
      href={`https://www.thebluealliance.com/event/${eventKey}`}
      target="_blank"
      rel="noreferrer noopener"
      className="text-muted-foreground hover:text-foreground inline-flex items-center gap-1.5 text-sm font-normal transition-colors"
    >
      {markFailed ? (
        <ExternalLink className="size-3.5" />
      ) : (
        <img
          src="/tba.png"          
          className="size-4 rounded-sm"
          onError={() => setMarkFailed(true)}
        />
      )}
      The Blue Alliance
    </a>
  );
}

function Metric({
  label, value, hint,
}: { label: string; value: string; hint?: string }) {
  return (
    <Card>
      <CardHeader>
        <CardDescription>{label}</CardDescription>
        <CardTitle className="text-3xl tabular-nums">{value}</CardTitle>
      </CardHeader>
      {hint ? (
        <CardContent className="text-muted-foreground -mt-4 text-xs">{hint}</CardContent>
      ) : null}
    </Card>
  );
}

export default function DashboardPage() {
  const event = useQuery(api.events.active);
  const teams = useQuery(api.teams.listWithStatus);
  const matches = useQuery(api.matches.listForEvent);
  const assignments = useQuery(api.assignments.mine);

  const total = teams?.length ?? 0;
  const pitDone = teams?.filter((t) => t.pitScouted).length ?? 0;
  const reports = teams?.reduce((sum, t) => sum + t.reportCount, 0) ?? 0;
  const noData = teams?.filter((t) => t.reportCount === 0).length ?? 0;

  // Six robots per match is full coverage. Anything less is a gap you want to
  // see now rather than during alliance selection.
  const expected = (matches?.length ?? 0) * 6;
  const coverage = expected === 0 ? 0 : Math.round((reports / expected) * 100);

  return (
    <PageShell
      title={
        event ? (
          <>
            {event.name}
            <TbaLink eventKey={event.tbaEventKey} />
          </>
        ) : (
          "No active event"
        )
      }
      description={
        event
          ? `${event.tbaEventKey} · ${total} teams · ${matches?.length ?? 0} qualification matches`
          : "An admin needs to set up an event before scouting can begin."
      }
      actions={
        <div className="flex gap-2">
          <Button variant="outline" render={<Link to="/pit" />}>Pit</Button>
          <Button render={<Link to="/scout" />}>Scout a match</Button>
        </div>
      }
    >
      {assignments?.upNext ? (
        <Card>
          <CardHeader>
            <CardDescription>Up next</CardDescription>
            <CardTitle className="flex flex-wrap items-baseline gap-3">
              <span className="text-3xl tabular-nums">
                Qual {assignments.upNext.matchNumber}
              </span>
              <span className={[
                "rounded-md px-2 py-1 text-xs font-medium text-white",
                assignments.upNext.station.startsWith("red") ? "bg-red-600" : "bg-blue-600",
              ].join(" ")}>
                {STATION_LABELS[assignments.upNext.station as Station]}
              </span>
            </CardTitle>
          </CardHeader>
          <CardContent className="-mt-4 space-y-3">
            <p className="text-muted-foreground text-sm">
              {assignments.upNext.teamNumber === null ? (
                "That station has no team in the imported schedule."
              ) : (
                <>
                  Team{" "}
                  <span className="text-foreground font-medium tabular-nums">
                    {assignments.upNext.teamNumber}
                  </span>
                  {assignments.upNext.nickname ? ` · ${assignments.upNext.nickname}` : ""}
                  {" · "}
                  {assignments.upNext.matchesAway === 0
                    ? "now"
                    : `${assignments.upNext.matchesAway} match${assignments.upNext.matchesAway === 1 ? "" : "es"} away`}
                </>
              )}
            </p>
            {assignments.upNext.teamNumber !== null ? (
              <Button variant="secondary"
                render={<Link to={`/scout/${assignments.upNext.matchNumber}/${assignments.upNext.teamNumber}`} />}>
                Scout this robot
              </Button>
            ) : null}
          </CardContent>
        </Card>
      ) : null}

      {(assignments?.shifts ?? []).length > 0 ? (
        <Card>
          <CardHeader>
            <CardTitle>Your shifts</CardTitle>
            <CardDescription>
              Progress counts reports you have submitted in each range.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-2">
            {(assignments?.shifts ?? []).map((shift) => (
              <ShiftRow key={shift.assignmentId}
                fromMatch={shift.fromMatch} toMatch={shift.toMatch}
                station={shift.station as Station}
                trailing={`${shift.done} of ${shift.total}`} />
            ))}
          </CardContent>
        </Card>
      ) : null}

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Metric label="Pit scouted" value={`${pitDone}/${total}`}
          hint={total - pitDone > 0 ? `${total - pitDone} still to do` : "Complete"} />
        <Metric label="Match reports" value={String(reports)} />
        <Metric label="Coverage" value={`${coverage}%`}
          hint={`of ${expected} possible robot-matches`} />
        <Metric label="Teams with no data" value={String(noData)}
          hint={noData > 0 ? "Unrankable until scouted" : "Every team has data"} />
      </div>

      {noData > 0 && teams ? (
        <Card>
          <CardHeader>
            <CardTitle>Teams with no match data</CardTitle>
            <CardDescription>
              These cannot be ranked on anything yet. Worth targeting before
              alliance selection.
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap gap-2">
            {teams
              .filter((t) => t.reportCount === 0)
              .map((t) => (
                <Button key={t._id} size="sm" variant="outline"
                  render={<Link to={`/teams?team=${t.number}`} />}>
                  {t.number}
                </Button>
              ))}
          </CardContent>
        </Card>
      ) : null}
    </PageShell>
  );
}
