import { useQuery } from "convex/react";
import { ArrowLeft } from "lucide-react";
import { Link, useParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { StatLinks } from "@/components/stat-links";
import { useRatings } from "@/lib/stat-site";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

type Robot = {
  teamNumber: number;
  nickname: string;
  notes: { id: string; scoutName: string; notes: string }[];
};

function Side({ label, robots, red }: { label: string; robots: Robot[]; red: boolean }) {
  return (
    <div className="space-y-3">
      <h3 className={red ? "font-medium text-red-600 dark:text-red-400" : "font-medium text-blue-600 dark:text-blue-400"}>
        {label}
      </h3>
      {robots.map((robot) => (
        <Card key={robot.teamNumber} className={red ? "border-red-600/30" : "border-blue-600/30"}>
          <CardHeader>
            <CardTitle className="flex items-baseline gap-2">
              <Link to={`/teams?team=${robot.teamNumber}`} className="tabular-nums hover:underline">
                {robot.teamNumber}
              </Link>
              <span className="text-muted-foreground text-sm font-normal">{robot.nickname}</span>
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            {robot.notes.length === 0 ? (
              <p className="text-muted-foreground text-sm">No notes on this robot in this match.</p>
            ) : (
              robot.notes.map((n) => (
                <div key={n.id} className="space-y-0.5">
                  <p className="text-sm whitespace-pre-wrap">{n.notes}</p>
                  <p className="text-muted-foreground text-xs">{n.scoutName}</p>
                </div>
              ))
            )}
          </CardContent>
        </Card>
      ))}
    </div>
  );
}

export default function NotesMatchPage() {
  const params = useParams();
  const matchNumber = Number.parseInt(params.matchNumber ?? "", 10);
  const data = useQuery(api.notes.forMatch, Number.isNaN(matchNumber) ? "skip" : { matchNumber });
  const ratings = useRatings();

  const back = (
    <Button variant="outline" render={<Link to="/matches" />}>
      <ArrowLeft className="size-4" /> All matches
    </Button>
  );

  if (Number.isNaN(matchNumber)) return <PageShell title="Match" description="Bad URL." actions={back} />;
  if (data === undefined) return <PageShell title="Match" description="Loading…" actions={back} />;
  if (data === null) {
    return <PageShell title="Match" description="That match is not at the active event." actions={back} />;
  }

  const sum = (side: Robot[]) =>
    side.reduce((total, r) => total + (ratings.byTeam.get(r.teamNumber)?.total ?? 0), 0);
  const covered = [...data.red, ...data.blue].filter((r) => ratings.byTeam.has(r.teamNumber)).length;
  const played = data.redScore !== null && data.blueScore !== null;
  const whenMs = data.actualTime ?? data.predictedTime ?? data.scheduledTime;

  return (
    <PageShell
      title={
        <>
          Qual {data.matchNumber}
          <StatLinks kind="match" eventKey={data.eventKey} matchKey={data.tbaMatchKey} />
        </>
      }
      description={whenMs === null ? undefined : `${played ? "Played" : "Scheduled"} ${new Date(whenMs).toLocaleString()}`}
      actions={back}
    >
      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>{played ? "Final score" : "Not played yet"}</CardTitle>
            <CardDescription>From The Blue Alliance.</CardDescription>
          </CardHeader>
          {played ? (
            <CardContent className="flex items-center gap-6">
              <div>
                <p className="text-xs text-red-600 dark:text-red-400">Red</p>
                <p className="text-3xl font-semibold tabular-nums">{data.redScore}</p>
              </div>
              <div>
                <p className="text-xs text-blue-600 dark:text-blue-400">Blue</p>
                <p className="text-3xl font-semibold tabular-nums">{data.blueScore}</p>
              </div>
            </CardContent>
          ) : null}
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Projected · {ratings.metric}</CardTitle>
            <CardDescription>
              {ratings.siteName} {ratings.metric} summed per alliance.
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap items-center gap-6">
            {ratings.loading ? (
              <p className="text-muted-foreground text-sm">Loading…</p>
            ) : ratings.byTeam.size === 0 ? (
              <p className="text-muted-foreground text-sm">
                No {ratings.metric} yet — an admin can pull it from the Admin page.
              </p>
            ) : (
              <>
                <div>
                  <p className="text-xs text-red-600 dark:text-red-400">Red</p>
                  <p className="text-3xl font-semibold tabular-nums">{sum(data.red).toFixed(0)}</p>
                </div>
                <div>
                  <p className="text-xs text-blue-600 dark:text-blue-400">Blue</p>
                  <p className="text-3xl font-semibold tabular-nums">{sum(data.blue).toFixed(0)}</p>
                </div>
                {covered < 6 ? (
                  <Badge variant="outline">Only {covered} of 6 have {ratings.metric}</Badge>
                ) : null}
              </>
            )}
          </CardContent>
        </Card>
      </div>

      <div className="grid gap-6 md:grid-cols-2">
        <Side label="Red" robots={data.red} red />
        <Side label="Blue" robots={data.blue} red={false} />
      </div>
    </PageShell>
  );
}
