import { useQuery } from "convex/react";
import { Link } from "react-router";

import { api } from "../../../convex/_generated/api";
import { NotesExport } from "./export";
import { ShiftRow } from "@/components/shift-picker";
import { StatLinks } from "@/components/stat-links";
import { useSeason } from "@/lib/season";
import { STATION_LABELS, type Station } from "@/lib/types";
import { PageShell } from "@/routes/page-shell";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

function Metric({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <Card>
      <CardHeader>
        <CardDescription>{label}</CardDescription>
        <CardTitle className="text-3xl tabular-nums">{value}</CardTitle>
      </CardHeader>
      {hint ? <CardContent className="text-muted-foreground -mt-4 text-xs">{hint}</CardContent> : null}
    </Card>
  );
}

export default function NotesDashboardPage() {
  const { event, year } = useSeason();
  const progress = useQuery(api.notes.progress);
  const matches = useQuery(api.matches.listForEvent);
  // Shifts and "Up next", counted in notes rather than 2026 reports.
  const assignments = useQuery(api.notes.assignments);

  const teams = progress?.teams ?? 0;
  const pitNoted = progress?.pitNoted ?? 0;
  const missing = progress?.teamsWithoutMatchNotes ?? [];

  return (
    <PageShell
      title={
        event ? (
          <>
            {event.name}
            <StatLinks kind="event" eventKey={event.tbaEventKey} />
          </>
        ) : "No active event"
      }
      description={
        event
          ? `${event.tbaEventKey} · ${teams} teams · ${matches?.length ?? 0} qualification matches · scouted with notes (no ${year ?? ""} forms yet)`
          : undefined
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
              {assignments.upNext.station === null ? null : (
                <span className={[
                  "rounded-md px-2 py-1 text-xs font-medium text-white",
                  assignments.upNext.station.startsWith("red") ? "bg-red-600" : "bg-blue-600",
                ].join(" ")}>
                  {STATION_LABELS[assignments.upNext.station as Station]}
                </span>
              )}
            </CardTitle>
          </CardHeader>
          <CardContent className="-mt-4 space-y-3">
            {assignments.upNext.assigned ? (
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
                    {assignments.upNext.matchesAway === 0
                      ? ""
                      : ` · ${assignments.upNext.matchesAway} match${assignments.upNext.matchesAway === 1 ? "" : "es"} away`}
                  </>
                )}
              </p>
            ) : null}
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
              Progress counts matches you have written notes on in each range.
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

      <div className="grid gap-4 sm:grid-cols-3">
        <Metric label="Pit notes" value={`${pitNoted}/${teams}`}
          hint={teams - pitNoted > 0 ? `${teams - pitNoted} still to do` : "Complete"} />
        <Metric label="Match notes" value={String(progress?.matchNotes ?? 0)} />
        <Metric label="Teams with no match notes" value={String(missing.length)} />
      </div>

      {missing.length > 0 ? (
        <Card>
          <CardHeader>
            <CardTitle>Teams with no match notes</CardTitle>
            <CardDescription>Nobody has written about these in a match yet.</CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap gap-2">
            {missing.map((n) => (
              <Button key={n} size="sm" variant="outline" render={<Link to={`/teams?team=${n}`} />}>
                {n}
              </Button>
            ))}
          </CardContent>
        </Card>
      ) : null}

      <NotesExport />
    </PageShell>
  );
}
