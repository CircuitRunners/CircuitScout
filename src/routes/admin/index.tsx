import { useAction, useMutation, useQuery } from "convex/react";
import { CheckCircle2, Download, LoaderCircle, Trash2, Trash, RotateCcw } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { PageShell } from "@/routes/page-shell";
import { RolesTable } from "./roles-table";
import {
  DeletionLog, FlaggedReports, ManageReports, PitReportsAdmin,
  TeamsNeedingAttention,
} from "./reports-admin";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";

function PurgePanel({
  eventId,
  confirmKey,
  onConfirmKeyChange,
  busy,
  onCancel,
  onPurge,
}: {
  eventId: Id<"events">;
  confirmKey: string;
  onConfirmKeyChange: (next: string) => void;
  busy: boolean;
  onCancel: () => void;
  onPurge: () => void;
}) {
  const preview = useQuery(api.events.purgePreview, { eventId });
  if (preview === undefined) {
    return <p className="text-muted-foreground w-full p-3 text-sm">Counting…</p>;
  }
  if (preview === null) return null;

  const nothing =
    preview.matchReports === 0 && preview.pitReports === 0 && preview.pickLists === 0;

  return (
    <div className="border-destructive mt-1 w-full space-y-3 rounded-md border p-3">
      <p className="text-destructive text-sm font-medium">
        Deleting {preview.name} hides it and everything attached to it.
      </p>
      <ul className="text-muted-foreground space-y-0.5 text-xs">
        <li>{preview.matchReports} match reports
          {preview.contributingScouts > 0
            ? ` from ${preview.contributingScouts} scouts`
            : ""}</li>
        <li>{preview.pitReports} pit reports</li>
        <li>{preview.pickLists} pick lists, including everyone's personal ones</li>
        <li>{preview.matches} matches and {preview.teams} teams</li>
      </ul>
      {preview.activeFor.length > 0 ? (
        <p className="text-destructive text-xs">
          Team {preview.activeFor.join(", ")} currently has this event active.
          They will be left with no event.
        </p>
      ) : null}
      {nothing ? (
        <p className="text-muted-foreground text-xs">
          Nothing was scouted here, so this is only removing imported data.
        </p>
      ) : (
        <p className="text-muted-foreground text-xs">
          Recoverable for 24 hours from the bottom of this list, then purged
          for good. Export from Coverage and Quality if you want a copy that
          outlives that.
        </p>
      )}
      <Input
        placeholder={`Type ${preview.eventKey} to confirm`}
        value={confirmKey}
        autoCapitalize="none"
        onChange={(e) => onConfirmKeyChange(e.target.value)}
      />
      <div className="flex gap-2">
        <Button variant="destructive" size="sm"
          disabled={busy || confirmKey.trim() !== preview.eventKey}
          onClick={onPurge}>
          Delete permanently
        </Button>
        <Button variant="ghost" size="sm" onClick={onCancel}>Cancel</Button>
      </div>
    </div>
  );
}

export default function AdminPage() {
  const events = useQuery(api.events.list);
  const importEvent = useAction(api.tba.importEvent);
  const refreshBoth = useAction(api.refresh.now);
  const epa = useQuery(api.statbotics.forEvent);
  const [refreshing, setRefreshing] = useState(false);
  const setActiveForTeam = useMutation(api.events.setActiveForTeam);
  const softDelete = useMutation(api.events.softDelete);
  const recoverEvent = useMutation(api.events.recover);
  const [purgeTarget, setPurgeTarget] = useState<string | null>(null);
  const [purgeKey, setPurgeKey] = useState("");
  const [purging, setPurging] = useState(false);
  const settings = useQuery(api.events.teamSettings);
  const removeEvent = useMutation(api.events.remove);
  const [removing, setRemoving] = useState<string | null>(null);
  const [confirmKey, setConfirmKey] = useState("");

  const me = useQuery(api.profiles.me);
  const isFullAdmin = me?.role === "admin";

  const [teamFor, setTeamFor] = useState<number | null>(null);
  const targetTeam = isFullAdmin ? teamFor : (me?.teamNumber ?? null);

  const [eventKey, setEventKey] = useState("");
  const [importing, setImporting] = useState(false);

  const runImport = async () => {
    setImporting(true);
    try {
      const result = await importEvent({ tbaEventKey: eventKey.trim() });
      toast.success(`Imported ${result.name}`, {
        description:
          `${result.teamsAdded} teams added, ${result.teamsUpdated} updated. ` +
          `${result.matchesAdded} matches added, ${result.matchesUpdated} updated.`,
      });
      if (result.teamsKept > 0) {
        toast.warning(`${result.teamsKept} withdrawn team(s) kept`, {
          description: "They have scouting data, so their reports were preserved.",
        });
      }
      setEventKey("");
    } catch (error) {
      toast.error("Import failed", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setImporting(false);
    }
  };

  return (
    <PageShell
      title="Admin"
      description="Event setup, scout roles and weighting."
    >
      <Card>
        <CardHeader>
          <CardTitle>Import an event</CardTitle>
          <CardDescription>
            Pulls teams and the qualification schedule from The Blue Alliance.
            Safe to re-run whenever the schedule is revised.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="event-key">TBA event key</Label>
            <div className="flex gap-2">
              <Input
                id="event-key"
                placeholder="2026gadal"
                value={eventKey}
                autoCapitalize="none"
                autoCorrect="off"
                spellCheck={false}
                onChange={(e) => setEventKey(e.target.value)}
              />
              <Button
                disabled={importing || eventKey.trim() === ""}
                onClick={() => void runImport()}
              >
                {importing ? (
                  <LoaderCircle className="size-4 animate-spin" />
                ) : (
                  <Download className="size-4" />
                )}
                Import
              </Button>
            </div>
            <p className="text-muted-foreground text-xs">
              The API key lives on the Convex deployment, never in the browser.
              Set it with <code>bunx convex env set TBA_API_KEY &lt;key&gt;</code>.
            </p>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Events</CardTitle>
          <CardDescription>
            Every team picks its own event from this shared pool, so two teams
            at different competitions can use one deployment. Standing an event
            down changes nothing about its data.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {events === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : events.length === 0 ? (
            <p className="text-muted-foreground text-sm">
              No events yet. Import one above.
            </p>
          ) : (
            events.filter((e) => !e.deletedAt).map((event) => (
              <div
                key={event._id}
                className="flex flex-wrap items-center gap-3 rounded-lg border p-3"
              >
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <span className="truncate font-medium">{event.name}</span>
                    {(event.activeForTeams ?? []).length > 0 ? (
                      <Badge>
                        <CheckCircle2 className="size-3" />
                        Active for {(event.activeForTeams ?? []).join(", ")}
                      </Badge>
                    ) : null}
                  </div>
                  <p className="text-muted-foreground text-xs">
                    {event.tbaEventKey} · {event.teamCount} teams ·{" "}
                    {event.matchCount} qualification matches
                    {event.reportCount + event.pitCount > 0
                      ? ` · ${event.reportCount} match / ${event.pitCount} pit reports`
                      : ""}
                  </p>
                </div>
                {isFullAdmin ? (
                  <Button variant="destructive" size="sm"
                    onClick={() => {
                      setPurgeTarget(purgeTarget === event._id ? null : event._id);
                      setPurgeKey("");
                    }}>
                    <Trash className="size-3" /> Delete
                  </Button>
                ) : null}
                {targetTeam === null ? (
                  <span className="text-muted-foreground text-xs">
                    Pick a team below
                  </span>
                ) : event.activeForTeams?.includes(targetTeam) ? (
                  <Button variant="outline" size="sm"
                    onClick={() => void setActiveForTeam({
                      eventId: null, teamNumber: targetTeam,
                    })}>
                    Stand down for {targetTeam}
                  </Button>
                ) : (
                  <Button variant="outline" size="sm"
                    onClick={() => void setActiveForTeam({
                      eventId: event._id, teamNumber: targetTeam,
                    })}>
                    Activate for {targetTeam}
                  </Button>
                )}
                {event.removable ? (
                  <Button variant="outline" size="sm"
                    onClick={() => {
                      setRemoving(removing === event._id ? null : event._id);
                      setConfirmKey("");
                    }}>
                    <Trash2 className="size-3" /> Remove
                  </Button>
                ) : (
                  <Badge variant="secondary" title="Events holding scouting data cannot be removed">
                    {event.reportCount + event.pitCount} report
                    {event.reportCount + event.pitCount === 1 ? "" : "s"}
                  </Badge>
                )}

              {purgeTarget === event._id ? (
                <PurgePanel
                  eventId={event._id}
                  confirmKey={purgeKey}
                  onConfirmKeyChange={setPurgeKey}
                  busy={purging}
                  onCancel={() => { setPurgeTarget(null); setPurgeKey(""); }}
                  onPurge={() => {
                    setPurging(true);
                    void softDelete({ eventId: event._id, confirmKey: purgeKey })
                      .then(() => {
                        toast.success(`${event.name} deleted`, {
                          description: "Recoverable for 24 hours.",
                        });
                        setPurgeTarget(null);
                        setPurgeKey("");
                      })
                      .catch((error: unknown) =>
                        toast.error("Could not delete", {
                          description:
                            error instanceof Error ? error.message : String(error),
                        }))
                      .finally(() => setPurging(false));
                  }}
                />
              ) : null}

              {removing === event._id ? (
                <div className="mt-1 w-full space-y-2 rounded-md border border-dashed p-3">
                  <p className="text-muted-foreground text-xs">
                    Removes {event.teamCount} teams and {event.matchCount}{" "}
                    matches. Nothing scouted is lost because there is nothing
                    scouted — re-import from TBA to get it back.
                  </p>
                  <Input
                    placeholder={`Type ${event.tbaEventKey} to confirm`}
                    value={confirmKey}
                    autoCapitalize="none"
                    onChange={(e) => setConfirmKey(e.target.value)}
                  />
                  <Button size="sm" variant="destructive"
                    disabled={confirmKey.trim() !== event.tbaEventKey}
                    onClick={() => {
                      void removeEvent({ eventId: event._id })
                        .then(() => {
                          toast.success(`${event.name} removed`);
                          setRemoving(null);
                          setConfirmKey("");
                        })
                        .catch((error: unknown) =>
                          toast.error("Could not remove", {
                            description:
                              error instanceof Error ? error.message : String(error),
                          }));
                    }}>
                    Remove permanently
                  </Button>
                </div>
              ) : null}
              </div>
            ))
          )}

          {(events ?? []).some((e) => e.deletedAt) ? (
            <div className="space-y-2 pt-2">
              <p className="text-muted-foreground text-xs">
                Deleted — recoverable for 24 hours, then purged for good.
              </p>
              {(events ?? [])
                .filter((e) => e.deletedAt)
                .map((event) => {
                  const hoursLeft = Math.max(
                    0,
                    Math.ceil((event.deletedAt! + 24 * 60 * 60 * 1000 - Date.now()) / 3600000),
                  );
                  return (
                    <div key={event._id}
                      className="flex flex-wrap items-center gap-3 rounded-lg border p-3 opacity-60">
                      <div className="min-w-0 flex-1">
                        <span className="truncate font-medium line-through">
                          {event.name}
                        </span>
                        <p className="text-muted-foreground text-xs">
                          {event.tbaEventKey} · {event.teamCount} teams ·{" "}
                          {event.reportCount} match reports · purged in{" "}
                          {hoursLeft}h
                        </p>
                      </div>
                      {isFullAdmin ? (
                        <Button variant="secondary" size="sm"
                          onClick={() => {
                            void recoverEvent({ eventId: event._id })
                              .then((r) => toast.success(`${r.name} recovered`))
                              .catch((error: unknown) =>
                                toast.error("Could not recover", {
                                  description:
                                    error instanceof Error ? error.message : String(error),
                                }));
                          }}>
                          <RotateCcw className="size-3" /> Recover
                        </Button>
                      ) : null}
                    </div>
                  );
                })}
            </div>
          ) : null}
        </CardContent>
      </Card>


      {me ? (
        <Card>
          <CardHeader>
            <CardTitle>{isFullAdmin ? "Configuring for" : "Your team's event"}</CardTitle>
            <CardDescription>
              {isFullAdmin
                ? "Which team the activation buttons above apply to."
                : "Activations above apply to your team. Events themselves are shared — importing one makes it available to everyone."}
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap items-center gap-2">
            {(settings ?? []).map((row) => (
              <Button key={row.teamNumber} size="sm"
                variant={targetTeam === row.teamNumber ? "default" : "outline"}
                // A team admin has exactly one option, so the button reports
                // rather than selects.
                disabled={!isFullAdmin}
                onClick={() => setTeamFor(row.teamNumber)}>
                {row.teamNumber}
                <span className="text-muted-foreground ml-1 text-xs">
                  {row.eventKey ?? "none"}
                </span>
              </Button>
            ))}
            {me?.teamNumber !== undefined &&
             !(settings ?? []).some((r) => r.teamNumber === me.teamNumber) ? (
              <Button size="sm"
                variant={targetTeam === me.teamNumber ? "default" : "outline"}
                onClick={() => setTeamFor(me.teamNumber ?? null)}>
                {me.teamNumber} (yours)
              </Button>
            ) : null}
            {(settings ?? []).length === 0 && me?.teamNumber === undefined ? (
              <p className="text-muted-foreground text-sm">
                No team has chosen an event yet.
              </p>
            ) : null}
          </CardContent>
        </Card>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>Statbotics &amp; TBA</CardTitle>
          <CardDescription>
            EPA and match scores refresh together every two hours, and only
            while a team has an event active. Pull them now if you want the
            numbers current before alliance selection.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap items-center gap-3">
          <Button variant="outline" disabled={refreshing}
            onClick={() => {
              setRefreshing(true);
              void refreshBoth({})
                .then((r) =>
                  toast.success("Refreshed", {
                    description:
                      `EPA for ${r.epaTeams} teams · ${r.matchesUpdated} matches updated.`,
                  }))
                .catch((error: unknown) =>
                  toast.error("Refresh failed", {
                    description: error instanceof Error ? error.message : String(error),
                  }))
                .finally(() => setRefreshing(false));
            }}>
            Refresh Statbotics/TBA
          </Button>
          <span className="text-muted-foreground text-xs">
            {epa?.fetchedAt
              ? `${epa.rows.length} teams · pulled ${new Date(epa.fetchedAt).toLocaleString()}`
              : "Never pulled yet"}
          </span>
        </CardContent>
      </Card>

      <RolesTable />

      <TeamsNeedingAttention />

      <FlaggedReports />

      <ManageReports />

      <PitReportsAdmin />

      <DeletionLog />
    </PageShell>
  );
}
