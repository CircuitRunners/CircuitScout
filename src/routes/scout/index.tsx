import { useQuery } from "convex/react";
import { ChevronRight, X } from "lucide-react";
import { useMemo, useState } from "react";
import { useNavigate } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { STATION_LABELS, type Station } from "@/lib/types";
import { submittedBeforeMatchEnd } from "@/lib/scoring";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

function MatchRobots({
  matchNumber,
  highlight,
  assignedTeam,
}: {
  matchNumber: number;
  highlight: number | null;
  assignedTeam: number | null;
}) {
  const data = useQuery(api.matches.teamsInMatch, { matchNumber });
  const counts = useQuery(api.matchReports.countsForMatch, { matchNumber });
  const navigate = useNavigate();

  if (data === undefined || data === null) {
    return <p className="text-muted-foreground p-3 text-sm">Loading…</p>;
  }

  const countFor = (teamId: string) =>
    counts?.find((c) => c.teamId === teamId) ?? { count: 0, mine: false };

  const column = (
    teams: typeof data.red,
    label: string,
    tone: string,
  ) => (
    <div className="space-y-2">
      <p className={`text-xs font-medium uppercase tracking-wide ${tone}`}>{label}</p>
      {teams.map((team, index) =>
        team === null ? (
          <div key={index} className="text-muted-foreground rounded-md border p-3 text-sm">
            Unknown team
          </div>
        ) : (
          (() => {
            const { count, mine } = countFor(team._id);
            return (
              <button
                key={team._id}
                onClick={() => void navigate(`/scout/${matchNumber}/${team.number}`)}
                className={[
                  "flex min-h-14 w-full items-center gap-2 rounded-md border p-3 text-left transition-colors",
                  team.number === assignedTeam
                    ? "border-2 border-green-500 bg-green-500/10"
                    : team.number === highlight
                      ? "border-primary bg-primary/10"
                      : "hover:bg-accent/50",
                ].join(" ")}
              >
                <span className="font-semibold tabular-nums">{team.number}</span>
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {team.number === assignedTeam ? "yours" : team.nickname}
                </span>
                <Badge
                  variant={count === 0 ? "outline" : mine ? "secondary" : "default"}
                  className="shrink-0 tabular-nums"
                  title={
                    mine
                      ? "You have already reported this robot"
                      : "Reports submitted for this robot"
                  }
                >
                  {count}
                  {mine ? " ✓" : ""}
                </Badge>
              </button>
            );
          })()
        ),
      )}
    </div>
  );

  return (
    <div className="space-y-3 p-3">
      <div className="grid grid-cols-2 gap-4">
        {column(data.red, "Red", "text-red-600 dark:text-red-400")}
        {column(data.blue, "Blue", "text-blue-600 dark:text-blue-400")}
      </div>
      <p className="text-muted-foreground text-xs">
        The number is how many scouts have reported that robot. A tick means one
        of them is you. More than one report is fine — a second look is a
        cross-check, not a duplicate.
      </p>
    </div>
  );
}

export default function ScoutLandingPage() {
  const matches = useQuery(api.matches.listForEvent);
  const myReports = useQuery(api.matchReports.mine);
  const [open, setOpen] = useState<number | null>(null);
  const [matchSearch, setMatchSearch] = useState("");
  const assignments = useQuery(api.assignments.mine);
  const assignedByMatch = new Map(
    (assignments?.assigned ?? []).map((a) => [a.matchNumber, a]),
  );

  // One box for both, because a scout looking for "their" match knows either
  // the match number or their assigned team — and often only one of them.
  const searchNumber = Number.parseInt(matchSearch.trim(), 10);
  const shown = useMemo(() => {
    if (!matches) return [];
    const needle = matchSearch.trim();
    if (needle === "") return matches;
    return matches.filter(
      (m) =>
        String(m.matchNumber) === needle ||
        (!Number.isNaN(searchNumber) &&
          (m.redTeamNumbers.includes(searchNumber) ||
            m.blueTeamNumbers.includes(searchNumber))),
    );
  }, [matches, matchSearch, searchNumber]);

  // A single hit is unambiguous, so open it rather than making them tap again.
  const onlyHit = shown.length === 1 ? (shown[0]?.matchNumber ?? null) : null;
  const expanded = onlyHit ?? open;
  const highlight =
    !Number.isNaN(searchNumber) &&
    matches?.some((m) =>
      m.redTeamNumbers.includes(searchNumber) ||
      m.blueTeamNumbers.includes(searchNumber))
      ? searchNumber
      : null;

  return (
    <PageShell
      title="Match Scouting"
      description="Search by match or team, then pick a robot. The badge shows how many reports that robot already has."
    >
      <Card>
        <CardHeader>
          <CardTitle>Matches</CardTitle>
          <CardDescription>
            {matches === undefined
              ? "Loading…"
              : matches.length === 0
                ? "No schedule imported yet."
                : `${matches.length} qualification matches.`}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <div className="flex gap-2">
            <Input
              placeholder="Match number or team number"
              inputMode="numeric"
              value={matchSearch}
              onChange={(e) => setMatchSearch(e.target.value)}
            />
            {matchSearch !== "" ? (
              <Button variant="ghost" size="icon" aria-label="Clear search"
                onClick={() => setMatchSearch("")}>
                <X className="size-4" />
              </Button>
            ) : null}
          </div>

          {matchSearch.trim() !== "" ? (
            <p className="text-muted-foreground text-xs">
              {shown.length === 0
                ? "No match with that number, and no team with that number is playing."
                : `${shown.length} match${shown.length === 1 ? "" : "es"} — a number can mean either a match or a team, so both are searched.`}
            </p>
          ) : null}

          {shown.map((match) => (
            <div key={match._id} className={[
              "rounded-lg border",
              assignedByMatch.has(match.matchNumber)
                ? "border-2 border-green-500 bg-green-500/5"
                : "",
            ].join(" ")}>
              <button
                onClick={() =>
                  setOpen(expanded === match.matchNumber ? null : match.matchNumber)
                }
                className="hover:bg-accent/50 flex min-h-14 w-full items-center gap-3 p-3 text-left transition-colors"
              >
                <span className="font-medium">Qual {match.matchNumber}</span>
                {assignedByMatch.has(match.matchNumber) ? (
                  <span className={[
                    "shrink-0 rounded px-1.5 py-0.5 text-[11px] font-medium text-white",
                    assignedByMatch.get(match.matchNumber)!.station.startsWith("red")
                      ? "bg-red-600" : "bg-blue-600",
                  ].join(" ")}>
                    {STATION_LABELS[assignedByMatch.get(match.matchNumber)!.station as Station]} · yours
                  </span>
                ) : null}
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {match.redTeamNumbers.join(", ")} vs {match.blueTeamNumbers.join(", ")}
                </span>
                <ChevronRight
                  className={`size-4 shrink-0 transition-transform ${
                    expanded === match.matchNumber ? "rotate-90" : ""
                  }`}
                />
              </button>
              {expanded === match.matchNumber ? (
                <MatchRobots matchNumber={match.matchNumber} highlight={highlight}
                  assignedTeam={assignedByMatch.get(match.matchNumber)?.teamNumber ?? null} />
              ) : null}
            </div>
          ))}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>My reports</CardTitle>
          <CardDescription>Newest first.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {myReports === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : myReports.length === 0 ? (
            <p className="text-muted-foreground text-sm">Nothing submitted yet.</p>
          ) : (
            myReports.slice(0, 20).map((report) => (
              <div
                key={report._id}
                className="flex items-center gap-3 rounded-md border p-3 text-sm"
              >
                <span className="font-medium">
                  Qual {report.match?.matchNumber ?? "?"}
                </span>
                <span className="tabular-nums">{report.team?.number ?? "?"}</span>
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {report.team?.nickname ?? ""}
                </span>
                {submittedBeforeMatchEnd(report.matchStartedAt, report.submittedAt) ? (
                  <Badge variant="destructive">Early</Badge>
                ) : null}
                {report.hubStateSource === "none" ? (
                  <Badge variant="outline">No shift split</Badge>
                ) : null}
              </div>
            ))
          )}
        </CardContent>
      </Card>
    </PageShell>
  );
}
