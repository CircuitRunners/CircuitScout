import { useConvex, useMutation, useQuery } from "convex/react";
import { ChevronDown, Download } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { api } from "../../convex/_generated/api";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import {
  Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";

const SHEETS = [
  ["pit", "Pit scouting"],
  ["matchReports", "Match scouting"],
  ["teams", "Teams with stats"],
  ["matches", "Match list with stats"],
] as const;

function formatLeft(ms: number) {
  const total = Math.max(0, Math.ceil(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const sec = total % 60;
  if (h > 0) return `${h}h ${String(m).padStart(2, "0")}m`;
  if (m > 0) return `${m}m ${String(sec).padStart(2, "0")}s`;
  return `${sec}s`;
}

export function EventExport() {
  const convex = useConvex();
  const me = useQuery(api.profiles.me);
  // Non-empty only for a full admin, which is what gates the chooser.
  const eligible = useQuery(api.workbook.eligibleTeams);
  const cooldown = useQuery(api.workbook.cooldown);
  const recordExport = useMutation(api.workbook.recordExport);

  const [now, setNow] = useState(() => Date.now());
  const [open, setOpen] = useState(false);
  const [pickerOpen, setPickerOpen] = useState(false);
  const [team, setTeam] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);

  const until = cooldown?.until ?? null;
  const waiting = until !== null && until > now;

  // Ticks only while there is something to count down.
  useEffect(() => {
    if (until === null || until <= Date.now()) return;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [until]);

  const choices = eligible ?? [];
  const chosen = choices.find((c) => c.teamNumber === team) ?? null;

  const download = async () => {
    setBusy(true);
    try {
      const data = await convex.query(api.workbook.forTeam, {
        teamNumber: team ?? undefined,
      });
      if (!data) {
        toast.error("No active event", {
          description: "That team has no event set up right now.",
        });
        return;
      }

      // Dynamic import: ~1.5 MB that nobody pays for until they export.
      const XLSX = await import("xlsx");
      const book = XLSX.utils.book_new();
      for (const [key, label] of SHEETS) {
        const rows = data[key];
        XLSX.utils.book_append_sheet(
          book,
          XLSX.utils.json_to_sheet(rows.length > 0 ? rows : [{}]),
          label,
        );
      }

      XLSX.writeFile(book, `circuitscout-${data.eventKey}-team${data.teamNumber}.xlsx`);
      // After the file exists, so a failure costs nobody their window.
      await recordExport({});
      toast.success("Downloaded", {
        description: `${data.teams.length} teams · ${data.matchReports.length} match reports · ${data.pit.length} pit reports.`,
      });
      setOpen(false);
    } catch (error) {
      toast.error("Could not build the workbook", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  // Scouts do not need this. A lead shares the file with their team once it
  // is downloaded.
  if (me === undefined) return null;
  if (me === null || (me.role !== "admin" && me.role !== "teamAdmin")) return null;

  return (
    <>
      <Card>
        <CardHeader>
          <CardTitle>Export</CardTitle>
          <CardDescription>
            Everything collected at the active event, as a spreadsheet. Useful
            for strategy work off the app, and a fallback when venue wifi fails.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap items-center gap-3">
          <Button variant="outline" disabled={waiting} onClick={() => setOpen(true)}>
            <Download className="size-4" /> Download active event as xlsx
          </Button>
          {waiting ? (
            <span className="text-muted-foreground text-sm">
              Available in <span className="tabular-nums">{formatLeft(until - now)}</span> for this event
            </span>
          ) : null}
        </CardContent>
      </Card>

      <Dialog open={open} onOpenChange={(next) => { if (!next) setOpen(false); }}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Download event data as an xlsx spreadsheet?</DialogTitle>
            <DialogDescription>
              Four sheets: pit scouting, match scouting, teams with stats, and
              the match list with stats.
            </DialogDescription>
          </DialogHeader>

          {choices.length > 0 ? (
            <div className="space-y-1">
              <Button variant="outline" className="w-full justify-between"
                onClick={() => setPickerOpen(!pickerOpen)}>
                {chosen
                  ? `Team ${chosen.teamNumber} — ${chosen.eventName}`
                  : "Your team's active event"}
                <ChevronDown className={`size-4 transition-transform ${pickerOpen ? "rotate-180" : ""}`} />
              </Button>

              {pickerOpen ? (
                <div className="max-h-56 space-y-1 overflow-y-auto rounded-lg border p-2">
                  <Button variant={team === null ? "default" : "ghost"}
                    className="w-full justify-start"
                    onClick={() => { setTeam(null); setPickerOpen(false); }}>
                    Your team
                  </Button>
                  {choices.map((c) => (
                    <Button key={c.teamNumber}
                      variant={team === c.teamNumber ? "default" : "ghost"}
                      className="w-full justify-between"
                      onClick={() => { setTeam(c.teamNumber); setPickerOpen(false); }}>
                      <span>Team {c.teamNumber}</span>
                      <span className="text-muted-foreground truncate text-xs">
                        {c.eventName} · {c.members} on the app
                      </span>
                    </Button>
                  ))}
                </div>
              ) : null}

              <p className="text-muted-foreground text-xs">
                Only teams with people on the app and an active event appear here.
              </p>
            </div>
          ) : null}

          <div className="flex flex-wrap gap-2">
            <Button disabled={busy} onClick={() => void download()}>
              {busy ? "Building…" : "Download"}
            </Button>
            <Button variant="ghost" disabled={busy} onClick={() => setOpen(false)}>
              Cancel
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}
