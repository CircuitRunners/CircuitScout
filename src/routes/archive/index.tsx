import { LoadingText } from "@/components/loading-text";
import { useQuery } from "convex/react";
import { Archive, ChevronRight } from "lucide-react";
import { useMemo, useState } from "react";
import { Link, useNavigate } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { MenuSelect } from "@/components/menu-select";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import {
  Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";

export default function ArchivePage() {
  const events = useQuery(api.archive.events);
  const navigate = useNavigate();
  // Ephemeral by design: a refresh shows the gate again, so a tab left open
  // overnight cannot come back still pointed at an old competition.
  const [entered, setEntered] = useState(false);
  const [season, setSeason] = useState<string>("all");

  const seasons = useMemo(
    () => [...new Set((events ?? []).map((e) => e.season))].sort((a, b) => b - a),
    [events],
  );
  const shown = (events ?? []).filter((e) => season === "all" || String(e.season) === season);

  return (
    <PageShell
      title="Past events"
      description="Read-only. Nothing here can be scouted, ranked or edited."
    >
      <Dialog open={!entered} onOpenChange={(next) => { if (!next) void navigate(-1); }}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>You are about to read old data</DialogTitle>
            <DialogDescription>
              These numbers are from competitions that are over.
            </DialogDescription>
          </DialogHeader>
          <p className="text-muted-foreground text-sm">
            Nothing on these pages affects your current event. Quoting a figure
            from here in an alliance meeting is the mistake this dialog exists
            to prevent.
          </p>
          <div className="flex gap-2">
            <Button onClick={() => setEntered(true)}>
              <Archive className="size-4" /> Show me
            </Button>
            <Button variant="outline" onClick={() => void navigate(-1)}>
              Take me back
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      {entered ? (
        <Card>
          <CardHeader>
            <CardTitle>Events</CardTitle>
            <CardDescription>
              Every event imported into this deployment, newest season first.
              Deleted events show a snapshot from just before they were deleted.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-1">
            {seasons.length > 1 ? (
              <div className="pb-2">
                <MenuSelect label="Season" value={season} className="w-40"
                  options={[
                    { value: "all", label: "All seasons" },
                    ...seasons.map((s) => ({ value: String(s), label: `${s} season` })),
                  ]}
                  onChange={setSeason} />
              </div>
            ) : null}
            {events === undefined ? (
              <p className="text-muted-foreground text-sm"><LoadingText /></p>
            ) : events.length === 0 ? (
              <p className="text-muted-foreground text-sm">Nothing imported yet.</p>
            ) : shown.length === 0 ? (
              <p className="text-muted-foreground text-sm">No events in the {season} season.</p>
            ) : (
              shown.map((event) => (
                <Button key={event.eventKey} variant="outline"
                  className="h-auto w-full justify-start py-3 whitespace-normal"
                  render={<Link to={`/archive/${event.eventKey}`} />}>
                  <span className="min-w-0 flex-1 text-left">
                    <span className="font-medium">{event.name}</span>
                    <span className="text-muted-foreground block text-xs sm:ml-2 sm:inline">
                      {event.eventKey} · {event.teamCount} teams ·{" "}
                      {event.reportCount} reports
                    </span>
                  </span>
                  {event.deleted ? (
                    <Badge variant="outline" className="shrink-0 border-dashed">
                      Deleted
                    </Badge>
                  ) : null}
                  {event.isMine ? (
                    <Badge variant="destructive" className="shrink-0">
                      Your live event
                    </Badge>
                  ) : event.activeForTeams.length > 0 ? (
                    <Badge variant="outline" className="shrink-0">
                      Live for {event.activeForTeams.join(", ")}
                    </Badge>
                  ) : null}
                  <ChevronRight className="size-4 shrink-0" />
                </Button>
              ))
            )}
          </CardContent>
        </Card>
      ) : null}
    </PageShell>
  );
}
