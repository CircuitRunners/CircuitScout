#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-admin-reports.sh
#   1. "Flagged" section on /admin listing every report with a data-quality
#      problem, and why.
#   2. "Manage reports" section: correct the auto winner, or delete a report.
#
# New file convex/admin.ts rather than editing convex/matchReports.ts, which
# Track C owns. No schema change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/admin/index.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Convex: admin report tools"
cat > convex/admin.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent, requireAdmin } from "./lib/guards";
import {
  countedTeleopFuel,
  submittedBeforeMatchEnd,
  uncountedTeleopFuel,
} from "./lib/scoring";
export type FlagReason =
  | "early"          // finished before the buzzer
  | "no-split"       // no time anchor, fuel not attributable to a shift
  | "dead-hub"       // more inactive-hub fuel than active
  | "disagreement";  // auto winner conflicts with other scouts in the match

const REASON_LABELS: Record<FlagReason, string> = {
  early: "Submitted before match end",
  "no-split": "No shift split",
  "dead-hub": "More dead-hub than counted fuel",
  disagreement: "Auto winner disagrees with other scouts",
};

export const flagLabels = query({
  args: {},
  handler: async () => REASON_LABELS,
});

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
  submittedAt: number;
  editCount: number;
  reasons: FlagReason[];
  reasonLabels: string[];
};

/**
 * Every report at the active event, newest first, with any data-quality flags
 * attached. Flags are DERIVED on read, so correcting a report clears its flag
 * immediately rather than leaving a stale marker behind.
 */
export const reports = query({
  args: { onlyFlagged: v.boolean() },
  handler: async (ctx, args): Promise<Row[]> => {
    await requireAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) return [];

    const all = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();

    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const matchById = new Map(matches.map((m) => [m._id, m]));

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const teamById = new Map(teams.map((t) => [t._id, t]));

    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    // Auto-winner answers per match, for the cross-scout check.
    const answersByMatch = new Map<string, ("red" | "blue")[]>();
    for (const r of all) {
      if (r.autoWinner === null) continue;
      const list = answersByMatch.get(r.matchId) ?? [];
      list.push(r.autoWinner);
      answersByMatch.set(r.matchId, list);
    }

    const rows: Row[] = [];
    for (const report of all) {
      const match = matchById.get(report.matchId);
      const team = teamById.get(report.teamId);
      if (!match || !team) continue;

      const onRed = match.redTeamNumbers.includes(team.number);
      const alliance: "red" | "blue" = onRed ? "red" : "blue";
      const isWinner =
        report.autoWinner === null ? null : report.autoWinner === alliance;

      const counted =
        isWinner === null
          ? Object.values(report.teleop.byShift).reduce((a, b) => a + b, 0)
          : countedTeleopFuel(report.teleop.byShift, isWinner);
      const dead =
        isWinner === null ? 0 : uncountedTeleopFuel(report.teleop.byShift, isWinner);

      const reasons: FlagReason[] = [];
      if (submittedBeforeMatchEnd(report.matchStartedAt, report.submittedAt)) {
        reasons.push("early");
      }
      if (report.hubStateSource === "none") reasons.push("no-split");
      if (dead > counted && dead > 0) reasons.push("dead-hub");

      const answers = answersByMatch.get(report.matchId) ?? [];
      if (
        report.autoWinner !== null &&
        answers.length > 1 &&
        answers.some((a) => a !== report.autoWinner)
      ) {
        reasons.push("disagreement");
      }

      if (args.onlyFlagged && reasons.length === 0) continue;

      const edits = await ctx.db
        .query("reportEdits")
        .withIndex("by_report", (q) => q.eq("reportId", report._id))
        .collect();

      rows.push({
        reportId: report._id,
        matchNumber: match.matchNumber,
        teamNumber: team.number,
        teamNickname: team.nickname,
        scoutName: nameByUser.get(report.scoutId) ?? "Unknown scout",
        alliance,
        autoWinner: report.autoWinner,
        counted,
        dead,
        submittedAt: report.submittedAt,
        editCount: edits.length,
        reasons,
        reasonLabels: reasons.map((r) => REASON_LABELS[r]),
      });
    }

    return rows.sort((a, b) => b.submittedAt - a.submittedAt);
  },
});

export const editHistory = query({
  args: { reportId: v.id("matchReports") },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const edits = await ctx.db
      .query("reportEdits")
      .withIndex("by_report", (q) => q.eq("reportId", args.reportId))
      .collect();
    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));
    return edits
      .map((e) => ({ ...e, editorName: nameByUser.get(e.editedBy) ?? "Unknown" }))
      .sort((a, b) => b.editedAt - a.editedAt);
  },
});

/**
 * The highest-value correction available. Because teleop fuel is banked per
 * shift, flipping the auto winner reclassifies counted vs dead fuel without
 * touching a single observation the scout made.
 */
export const setAutoWinner = mutation({
  args: {
    reportId: v.id("matchReports"),
    autoWinner: v.union(v.literal("red"), v.literal("blue")),
    reason: v.string(),
  },
  handler: async (ctx, args) => {
    const admin = await requireAdmin(ctx);
    const reason = args.reason.trim();
    if (reason === "") throw new Error("A reason is required.");

    const report = await ctx.db.get(args.reportId);
    if (!report) throw new Error("That report no longer exists.");

    await ctx.db.patch(args.reportId, {
      autoWinner: args.autoWinner,
      updatedAt: Date.now(),
    });
    await ctx.db.insert("reportEdits", {
      reportId: args.reportId,
      editedBy: admin.userId,
      editedAt: Date.now(),
      reason: `Auto winner set to ${args.autoWinner}: ${reason}`,
    });
  },
});

/**
 * Deletion is unaudited — the edit trail is keyed to a report id that will no
 * longer exist. Prefer correcting a report over removing it; a bad number that
 * has been explained is more useful than a gap nobody can account for.
 */
export const deleteReport = mutation({
  args: { reportId: v.id("matchReports"), reason: v.string() },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    if (args.reason.trim() === "") throw new Error("A reason is required.");

    const edits = await ctx.db
      .query("reportEdits")
      .withIndex("by_report", (q) => q.eq("reportId", args.reportId))
      .collect();
    for (const edit of edits) await ctx.db.delete(edit._id);

    await ctx.db.delete(args.reportId);
  },
});
EOF

say "Client: admin report sections"
cat > src/routes/admin/reports-admin.tsx <<'EOF'
import { useMutation, useQuery } from "convex/react";
import { AlertTriangle, History, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
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
  reasonLabels: string[];
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

  const [action, setAction] = useState<"none" | "winner" | "delete">("none");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);

  const flip = row.autoWinner === "red" ? "blue" : "red";
  const id = row.reportId as Id<"matchReports">;

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

      {row.reasonLabels.length > 0 ? (
        <div className="flex flex-wrap gap-1">
          {row.reasonLabels.map((label) => (
            <Badge key={label} variant="destructive" className="text-xs">
              <AlertTriangle className="size-3" />
              {label}
            </Badge>
          ))}
        </div>
      ) : null}

      <div className="flex flex-wrap gap-2">
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
            <p className="text-muted-foreground text-xs">
              Deletion is not audited — the edit trail goes with it. Correcting
              a report is almost always better than removing it.
            </p>
          ) : null}
          <Input
            placeholder="Reason (required)"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
          <Button
            size="sm"
            variant={action === "delete" ? "destructive" : "default"}
            disabled={busy || reason.trim() === ""}
            onClick={() => void run(action)}
          >
            Confirm
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
          read, so correcting a report clears its flag immediately — there is no
          stale marker to chase.
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
EOF

say "Wire into /admin"
cat > /tmp/a1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/index.tsx";
let s = readFileSync(p, "utf8");
if (s.includes("FlaggedReports")) { console.log("already wired"); process.exit(0); }
s = s.replace('import { RolesTable } from "./roles-table";',
  'import { RolesTable } from "./roles-table";\nimport { FlaggedReports, ManageReports } from "./reports-admin";');
s = s.replace("      <RolesTable />",
  "      <RolesTable />\n\n      <FlaggedReports />\n\n      <ManageReports />");
writeFileSync(p, s);
console.log("src/routes/admin/index.tsx patched");
MJS
bun /tmp/a1.mjs
rm -f /tmp/a1.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
