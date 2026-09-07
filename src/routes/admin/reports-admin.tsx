import { useMutation, useQuery } from "convex/react";
import { AlertTriangle, EyeOff, History, Pencil, RotateCcw, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import { Link } from "react-router";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";

type Row = {
  reportId: string;
  matchNumber: number;
  teamNumber: number;
  teamNickname: string;
  scoutName: string;
  alliance: "red" | "blue";
  autoWinner: "red" | "blue" | null;
  counted: number;
  dead: number;
  editCount: number;
  reasons: string[];
  reasonLabels: string[];
  dismissed: {
    reason: string;
    label: string;
    note: string;
    byName: string;
    at: number;
  }[];
};

function EditHistory({ reportId }: { reportId: string }) {
  const history = useQuery(api.admin.editHistory, {
    reportId: reportId as Id<"matchReports">,
  });
  if (history === undefined) return <p className="text-xs">Loading…</p>;
  if (history.length === 0) return <p className="text-xs">No edits.</p>;
  return (
    <ul className="space-y-1 text-xs">
      {history.map((edit) => (
        <li key={edit._id}>
          <span className="font-medium">{edit.editorName}</span>
          {" · "}
          {new Date(edit.editedAt).toLocaleString()}
          {" — "}
          {edit.reason}
        </li>
      ))}
    </ul>
  );
}

function ReportRow({ row }: { row: Row }) {
  const setAutoWinner = useMutation(api.admin.setAutoWinner);
  const deleteReport = useMutation(api.admin.deleteReport);
  const dismissFlag = useMutation(api.admin.dismissFlag);
  const restoreFlag = useMutation(api.admin.restoreFlag);

  const [action, setAction] = useState<"none" | "winner" | "delete">("none");
  const [reason, setReason] = useState("");
  const [confirmText, setConfirmText] = useState("");
  const [busy, setBusy] = useState(false);
  const [dismissing, setDismissing] = useState<string | null>(null);
  const [dismissNote, setDismissNote] = useState("");

  const flip = row.autoWinner === "red" ? "blue" : "red";
  const id = row.reportId as Id<"matchReports">;

  const dismiss = async (reason: string) => {
    setBusy(true);
    try {
      await dismissFlag({ reportId: id, reason, note: dismissNote });
      toast.success("Flag dismissed");
      setDismissing(null);
      setDismissNote("");
    } catch (error) {
      toast.error("Failed", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  const restore = async (reason: string) => {
    try {
      await restoreFlag({ reportId: id, reason });
      toast.success("Flag restored");
    } catch (error) {
      toast.error("Failed", {
        description: error instanceof Error ? error.message : String(error),
      });
    }
  };

  const run = async (kind: "winner" | "delete") => {
    setBusy(true);
    try {
      if (kind === "winner") {
        await setAutoWinner({ reportId: id, autoWinner: flip, reason });
        toast.success(`Auto winner set to ${flip}`);
      } else {
        await deleteReport({ reportId: id, reason });
        toast.success("Report deleted");
      }
      setAction("none");
      setReason("");
      setConfirmText("");
    } catch (error) {
      toast.error("Failed", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-3 rounded-lg border p-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-medium">Qual {row.matchNumber}</span>
        <span className="tabular-nums">{row.teamNumber}</span>
        <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
          {row.teamNickname} · {row.scoutName} · {row.alliance}
        </span>
        <span className="text-muted-foreground shrink-0 text-xs tabular-nums">
          {row.counted} counted / {row.dead} dead
        </span>
      </div>

      {row.reasons.length > 0 ? (
        <div className="space-y-2">
          {row.reasons.map((reason, i) => (
            <div key={reason} className="flex flex-wrap items-center gap-2">
              <Badge variant="destructive" className="text-xs">
                <AlertTriangle className="size-3" />
                {row.reasonLabels[i] ?? reason}
              </Badge>
              <Button size="sm" variant="ghost"
                onClick={() => setDismissing(dismissing === reason ? null : reason)}>
                <EyeOff className="size-3" /> Dismiss
              </Button>
            </div>
          ))}
        </div>
      ) : null}

      {dismissing !== null ? (
        <div className="space-y-2 rounded-md border border-dashed p-3">
          <p className="text-muted-foreground text-xs">
            Dismissing says someone checked this and it is fine. The note is
            what the next person reads instead of the flag.
          </p>
          <Input
            placeholder="What did you check? (required)"
            value={dismissNote}
            onChange={(e) => setDismissNote(e.target.value)}
          />
          <Button size="sm" disabled={busy || dismissNote.trim() === ""}
            onClick={() => void dismiss(dismissing)}>
            Dismiss flag
          </Button>
        </div>
      ) : null}

      {row.dismissed.length > 0 ? (
        <div className="space-y-1">
          {row.dismissed.map((d) => (
            <div key={d.reason} className="flex flex-wrap items-center gap-2">
              <Badge variant="outline" className="text-xs">
                <EyeOff className="size-3" />
                {d.label}
              </Badge>
              <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                {d.note} — {d.byName}
              </span>
              <Button size="sm" variant="ghost"
                onClick={() => void restore(d.reason)}>
                <RotateCcw className="size-3" /> Restore
              </Button>
            </div>
          ))}
        </div>
      ) : null}

      <div className="flex flex-wrap gap-2">
        <Button size="sm" variant="outline" render={
          <Link to={`/scout/${row.matchNumber}/${row.teamNumber}?report=${row.reportId}`} />
        }>
          <Pencil className="size-3" /> Edit
        </Button>
        <Button size="sm" variant="outline"
          onClick={() => setAction(action === "winner" ? "none" : "winner")}>
          Set auto winner to {flip}
        </Button>
        <Button size="sm" variant="outline"
          onClick={() => setAction(action === "delete" ? "none" : "delete")}>
          <Trash2 className="size-3" /> Delete
        </Button>
        {row.editCount > 0 ? (
          <Badge variant="secondary">
            <History className="size-3" />
            {row.editCount} edit{row.editCount === 1 ? "" : "s"}
          </Badge>
        ) : null}
      </div>

      {action !== "none" ? (
        <div className="space-y-2 rounded-md border border-dashed p-3">
          {action === "delete" ? (
            <p className="text-destructive text-xs">
              This removes the report and its edit trail permanently. The reason
              and a full snapshot are kept in the deletion log. Correcting a
              report is almost always better than removing it.
            </p>
          ) : null}
          <Input
            placeholder="Reason (required)"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
          {action === "delete" ? (
            <Input
              placeholder={`Type ${row.teamNumber} to confirm`}
              inputMode="numeric"
              value={confirmText}
              onChange={(e) => setConfirmText(e.target.value)}
            />
          ) : null}
          <Button
            size="sm"
            variant={action === "delete" ? "destructive" : "default"}
            disabled={
              busy ||
              reason.trim() === "" ||
              (action === "delete" && confirmText.trim() !== String(row.teamNumber))
            }
            onClick={() => void run(action)}
          >
            {action === "delete" ? "Delete permanently" : "Confirm"}
          </Button>
        </div>
      ) : null}

      {row.editCount > 0 ? <EditHistory reportId={row.reportId} /> : null}
    </div>
  );
}

export function FlaggedReports() {
  const rows = useQuery(api.admin.reports, { onlyFlagged: true });

  return (
    <Card>
      <CardHeader>
        <CardTitle>Flagged</CardTitle>
        <CardDescription>
          Reports with a data-quality problem. Flags are recomputed on every
          read, so correcting a report clears its flag immediately. A dismissed
          flag stays visible here with its note, and comes back automatically if
          the report is edited afterwards.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        {rows === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) : rows.length === 0 ? (
          <p className="text-muted-foreground text-sm">
            Nothing flagged. Note that a report with no time anchor cannot be
            checked for early submission, so "not flagged" is not the same as
            "verified".
          </p>
        ) : (
          rows.map((row) => <ReportRow key={row.reportId} row={row} />)
        )}
      </CardContent>
    </Card>
  );
}

export function ManageReports() {
  const rows = useQuery(api.admin.reports, { onlyFlagged: false });
  const [search, setSearch] = useState("");

  const shown = useMemo(() => {
    if (!rows) return [];
    const needle = search.trim().toLowerCase();
    if (needle === "") return rows.slice(0, 25);
    return rows
      .filter(
        (r) =>
          String(r.teamNumber).includes(needle) ||
          String(r.matchNumber) === needle ||
          r.teamNickname.toLowerCase().includes(needle) ||
          r.scoutName.toLowerCase().includes(needle),
      )
      .slice(0, 50);
  }, [rows, search]);

  return (
    <Card>
      <CardHeader>
        <CardTitle>Manage reports</CardTitle>
        <CardDescription>
          Search by team, match or scout. Correcting the auto winner
          reclassifies counted and dead fuel without touching anything the
          scout actually observed.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        <Input
          placeholder="Team number, match number or scout name"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
        {rows === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) : shown.length === 0 ? (
          <p className="text-muted-foreground text-sm">Nothing matches.</p>
        ) : (
          <>
            {search.trim() === "" ? (
              <p className="text-muted-foreground text-xs">
                Showing the 25 most recent of {rows.length}. Search to narrow.
              </p>
            ) : null}
            {shown.map((row) => <ReportRow key={row.reportId} row={row} />)}
          </>
        )}
      </CardContent>
    </Card>
  );
}

export function PitReportsAdmin() {
  const rows = useQuery(api.admin.pitReports, {});
  const remove = useMutation(api.admin.deletePitReport);
  const [openId, setOpenId] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const [confirmText, setConfirmText] = useState("");
  const [busy, setBusy] = useState(false);
  const [search, setSearch] = useState("");

  const shown = (rows ?? []).filter((r) => {
    const needle = search.trim().toLowerCase();
    if (needle === "") return true;
    return (
      String(r.teamNumber).includes(needle) ||
      r.teamNickname.toLowerCase().includes(needle) ||
      r.scoutName.toLowerCase().includes(needle)
    );
  });

  const drop = async (id: string, teamNumber: number) => {
    setBusy(true);
    try {
      await remove({ pitReportId: id as Id<"pitReports">, reason });
      toast.success(`Pit report for ${teamNumber} deleted`);
      setOpenId(null);
      setReason("");
      setConfirmText("");
    } catch (error) {
      toast.error("Failed", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>Pit reports</CardTitle>
        <CardDescription>
          Editing opens the normal pit form. There is one pit report per team,
          so an edit updates it in place rather than adding a second.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        <Input
          placeholder="Team number, nickname or scout"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
        {rows === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) : shown.length === 0 ? (
          <p className="text-muted-foreground text-sm">No pit reports yet.</p>
        ) : (
          shown.map((row) => (
            <div key={row.pitReportId} className="space-y-2 rounded-lg border p-3">
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-semibold tabular-nums">{row.teamNumber}</span>
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {row.teamNickname} · {row.drivetrain || "no drivetrain"} · {row.scoutName}
                </span>
                <Button size="sm" variant="outline"
                  render={<Link to={`/pit/${row.teamNumber}`} />}>
                  <Pencil className="size-3" /> Edit
                </Button>
                <Button size="sm" variant="outline"
                  onClick={() =>
                    setOpenId(openId === row.pitReportId ? null : row.pitReportId)}>
                  <Trash2 className="size-3" /> Delete
                </Button>
              </div>
              {openId === row.pitReportId ? (
                <div className="space-y-2 rounded-md border border-dashed p-3">
                  <p className="text-destructive text-xs">
                    The reason and a full snapshot are kept in the deletion log.
                  </p>
                  <Input placeholder="Reason (required)" value={reason}
                    onChange={(e) => setReason(e.target.value)} />
                  <Input
                    placeholder={`Type ${row.teamNumber} to confirm`}
                    inputMode="numeric"
                    value={confirmText}
                    onChange={(e) => setConfirmText(e.target.value)}
                  />
                  <Button size="sm" variant="destructive"
                    disabled={
                      busy ||
                      reason.trim() === "" ||
                      confirmText.trim() !== String(row.teamNumber)
                    }
                    onClick={() => void drop(row.pitReportId, row.teamNumber)}>
                    Delete permanently
                  </Button>
                </div>
              ) : null}
            </div>
          ))
        )}
      </CardContent>
    </Card>
  );
}

export function DeletionLog() {
  const rows = useQuery(api.admin.deletions, {});
  const [expanded, setExpanded] = useState<string | null>(null);

  return (
    <Card>
      <CardHeader>
        <CardTitle>Deletion log</CardTitle>
        <CardDescription>
          Every deleted report, with its reason and a full snapshot. Nothing in
          the app removes from this list.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        {rows === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) : rows.length === 0 ? (
          <p className="text-muted-foreground text-sm">Nothing has been deleted.</p>
        ) : (
          rows.map((row) => (
            <div key={row._id} className="space-y-2 rounded-lg border p-3 text-sm">
              <div className="flex flex-wrap items-center gap-2">
                <Badge variant="outline">
                  {row.kind === "pitReport" ? "Pit" : `Qual ${row.matchNumber ?? "?"}`}
                </Badge>
                <span className="tabular-nums">{row.teamNumber}</span>
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  by {row.scoutName} · deleted by {row.deletedByName} ·{" "}
                  {new Date(row.deletedAt).toLocaleString()}
                </span>
                <Button size="sm" variant="ghost"
                  onClick={() => setExpanded(expanded === row._id ? null : row._id)}>
                  <History className="size-3" /> Snapshot
                </Button>
              </div>
              <p className="text-xs">{row.reason}</p>
              {expanded === row._id ? (
                <pre className="bg-muted max-h-64 overflow-auto rounded-md p-2 text-[10px]">
                  {JSON.stringify(JSON.parse(row.snapshot), null, 2)}
                </pre>
              ) : null}
            </div>
          ))
        )}
      </CardContent>
    </Card>
  );
}
