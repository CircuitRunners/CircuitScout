#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-admin-edit.sh
#   1. Deletions are logged (SCHEMA CHANGE: deletionLog table)
#   2. Deletions require typing the team number to confirm
#   3. Admin editing reuses the scout form via ?report=<id>
#   4. Admin can edit and delete pit reports as well as match reports
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/admin/reports-admin.tsx ]] || { echo "ERROR: run patch-admin-reports.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema: deletionLog"
cat > /tmp/e1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
if (s.includes("deletionLog")) { console.log("already has deletionLog"); process.exit(0); }
const anchor = `  pickLists: defineTable({`;
if (!s.includes(anchor)) { console.error("could not find pickLists in schema"); process.exit(1); }
s = s.replace(anchor, `  /**
   * Deleting a report also deletes its edit trail, so the reason and a full
   * snapshot are recorded here instead. A gap nobody can account for is worse
   * than a bad number that was explained.
   */
  deletionLog: defineTable({
    eventId: v.id("events"),
    kind: v.union(v.literal("matchReport"), v.literal("pitReport")),
    teamNumber: v.number(),
    matchNumber: v.union(v.number(), v.null()),
    scoutName: v.string(),
    deletedBy: v.id("users"),
    deletedAt: v.number(),
    reason: v.string(),
    snapshot: v.string(),
  }).index("by_event", ["eventId"]),

${anchor}`);
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/e1.mjs

say "Convex: logged deletion, pit tools, edit loader"
cat > /tmp/e2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/admin.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("deletionLog")) { console.log("admin.ts already patched"); process.exit(0); }

s = s.replace('import { activeEvent, requireAdmin } from "./lib/guards";',
  'import { activeEvent, requireAdmin, requireUser } from "./lib/guards";');

const oldDelete = s.slice(s.indexOf("/**\n * Deletion is unaudited"));
if (!oldDelete) fail("could not find deleteReport");
s = s.slice(0, s.indexOf("/**\n * Deletion is unaudited"));

s += `/**
 * Loads a report for editing. Allowed for its author or an admin — the same
 * rule matchReports.update enforces, so the form never offers an edit the
 * mutation would then reject.
 */
export const reportForEdit = query({
  args: { reportId: v.id("matchReports") },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const report = await ctx.db.get(args.reportId);
    if (!report) return null;

    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .unique();
    if (report.scoutId !== userId && profile?.role !== "admin") return null;

    return report;
  },
});

async function describe(
  ctx: { db: { get: (id: never) => Promise<unknown> } },
): Promise<never> { throw new Error("unused"); }

export const deleteReport = mutation({
  args: { reportId: v.id("matchReports"), reason: v.string() },
  handler: async (ctx, args) => {
    const admin = await requireAdmin(ctx);
    const reason = args.reason.trim();
    if (reason === "") throw new Error("A reason is required.");

    const report = await ctx.db.get(args.reportId);
    if (!report) throw new Error("That report no longer exists.");

    const team = await ctx.db.get(report.teamId);
    const match = await ctx.db.get(report.matchId);
    const profiles = await ctx.db.query("profiles").collect();
    const scoutName =
      profiles.find((p) => p.userId === report.scoutId)?.displayName ?? "Unknown";

    await ctx.db.insert("deletionLog", {
      eventId: report.eventId,
      kind: "matchReport",
      teamNumber: team?.number ?? 0,
      matchNumber: match?.matchNumber ?? null,
      scoutName,
      deletedBy: admin.userId,
      deletedAt: Date.now(),
      reason,
      snapshot: JSON.stringify(report),
    });

    const edits = await ctx.db
      .query("reportEdits")
      .withIndex("by_report", (q) => q.eq("reportId", args.reportId))
      .collect();
    for (const edit of edits) await ctx.db.delete(edit._id);

    await ctx.db.delete(args.reportId);
  },
});

/** Pit reports for the active event, with team and scout resolved. */
export const pitReports = query({
  args: {},
  handler: async (ctx) => {
    await requireAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) return [];

    const reports = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();

    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    const rows = [];
    for (const report of reports) {
      const team = await ctx.db.get(report.teamId);
      if (!team) continue;
      rows.push({
        pitReportId: report._id,
        teamNumber: team.number,
        teamNickname: team.nickname,
        scoutName: nameByUser.get(report.scoutId) ?? "Unknown scout",
        drivetrain: report.drivetrain,
        updatedAt: report.updatedAt,
      });
    }
    return rows.sort((a, b) => a.teamNumber - b.teamNumber);
  },
});

export const deletePitReport = mutation({
  args: { pitReportId: v.id("pitReports"), reason: v.string() },
  handler: async (ctx, args) => {
    const admin = await requireAdmin(ctx);
    const reason = args.reason.trim();
    if (reason === "") throw new Error("A reason is required.");

    const report = await ctx.db.get(args.pitReportId);
    if (!report) throw new Error("That report no longer exists.");

    const team = await ctx.db.get(report.teamId);
    const profiles = await ctx.db.query("profiles").collect();
    const scoutName =
      profiles.find((p) => p.userId === report.scoutId)?.displayName ?? "Unknown";

    await ctx.db.insert("deletionLog", {
      eventId: report.eventId,
      kind: "pitReport",
      teamNumber: team?.number ?? 0,
      matchNumber: null,
      scoutName,
      deletedBy: admin.userId,
      deletedAt: Date.now(),
      reason,
      snapshot: JSON.stringify(report),
    });

    await ctx.db.delete(args.pitReportId);
  },
});

/** The deletion trail. Read-only; nothing in the app removes from it. */
export const deletions = query({
  args: {},
  handler: async (ctx) => {
    await requireAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) return [];
    const rows = await ctx.db
      .query("deletionLog")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();

    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    return rows
      .map((r) => ({ ...r, deletedByName: nameByUser.get(r.deletedBy) ?? "Unknown" }))
      .sort((a, b) => b.deletedAt - a.deletedAt);
  },
});
`;
s = s.replace(`async function describe(
  ctx: { db: { get: (id: never) => Promise<unknown> } },
): Promise<never> { throw new Error("unused"); }

`, "");
writeFileSync(p, s);
console.log("convex/admin.ts patched");
MJS
bun /tmp/e2.mjs

say "Scout form: edit mode"
cat > /tmp/e3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/scout/form.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("editReason")) { console.log("form already in edit mode"); process.exit(0); }

s = s.replace('import { useNavigate, useParams } from "react-router";',
              'import { useNavigate, useParams, useSearchParams } from "react-router";');
s = s.replace('import { api } from "../../../convex/_generated/api";',
  'import { api } from "../../../convex/_generated/api";\nimport type { Id } from "../../../convex/_generated/dataModel";');

s = s.replace(`  const submit = useMutation(api.matchReports.submit);`,
`  const submit = useMutation(api.matchReports.submit);
  const update = useMutation(api.matchReports.update);

  const [searchParams] = useSearchParams();
  const editId = searchParams.get("report");
  const editing = useQuery(
    api.admin.reportForEdit,
    editId ? { reportId: editId as Id<"matchReports"> } : "skip",
  );
  const [editReason, setEditReason] = useState("");
  const [hydrated, setHydrated] = useState(false);`);

// hydrate an existing report exactly once
s = s.replace("  // No Match Start tap: anchor on the first look at teleop.",
`  // Editing hydrates once. Convex queries are live, so re-hydrating would
  // stamp on the correction in progress every time anything else changed.
  useEffect(() => {
    if (!editing || hydrated) return;
    setStart(editing.auto.path.start);
    setCycles(editing.auto.path.cycles);
    setDepot(editing.auto.path.depotPickups);
    setOutpost(editing.auto.path.outpostPickups);
    setAutoClimb(editing.auto.climbL1);
    setAutoFuel(editing.auto.fuel);
    setAutoFouls(editing.auto.fouls);
    setAutoNotes(editing.auto.notes);
    setByShift(editing.teleop.byShift);
    setTPassedNeutral(editing.teleop.passedNeutral);
    setTPassedFull(editing.teleop.passedFullField);
    setStoleFuel(editing.teleop.stoleFuel);
    setDefended(editing.teleop.defended);
    setTeleopNotes(editing.teleop.notes);
    setClimb(editing.endgame.climb);
    setEndFuel(editing.endgame.fuel);
    setEPassedNeutral(editing.endgame.passedNeutral);
    setEPassedFull(editing.endgame.passedFullField);
    setEndNotes(editing.endgame.notes);
    setFinalNotes(editing.finalNotes ?? "");
    setDriver(editing.ratings.driver);
    setDefense(editing.ratings.defense);
    setAccuracy(editing.ratings.accuracy);
    setShootsOnMove(editing.ratings.shootsOnMove);
    setBroke(editing.ratings.broke);
    setBrokeNotes(editing.ratings.brokeNotes);
    setInconsistent(editing.ratings.inconsistent);
    setInconsistentNotes(editing.ratings.inconsistentNotes);
    setAutoWinner(editing.autoWinner);
    setStartedAt(editing.matchStartedAt);
    setEstimated(editing.hubStateSource === "estimated");
    setHydrated(true);
  }, [editing, hydrated]);

  // No Match Start tap: anchor on the first look at teleop.`);

// the estimated-anchor effect must not fire while editing
s = s.replace(`    if (period === "teleop" && startedAt === null) {`,
              `    if (editId) return;
    if (period === "teleop" && startedAt === null) {`);
s = s.replace(`  }, [period, startedAt]);`, `  }, [period, startedAt, editId]);`);

// require a reason when editing
s = s.replace(`  if (finalNotes.trim() === "") missing.push("final notes");`,
`  if (finalNotes.trim() === "") missing.push("final notes");
  if (editId && editReason.trim() === "") missing.push("a reason for this edit");`);

// save() branches
const oldSave = `      await submit({
        matchId: data.match._id,
        teamId: data.team._id,
        auto: {`;
if (!s.includes(oldSave)) fail("could not find submit call");
s = s.replace(oldSave, `      const payload = {
        auto: {`);

const oldTail = `        matchStartedAt: startedAt,
        autoWinner,
        hubStateSource,
      });
      toast.success(\`Qual \${matchNumber} · team \${teamNumber} submitted\`);
      void navigate("/scout");`;
if (!s.includes(oldTail)) fail("could not find the submit tail");
s = s.replace(oldTail, `        matchStartedAt: startedAt,
        autoWinner,
        hubStateSource,
      };

      if (editId) {
        await update({
          reportId: editId as Id<"matchReports">,
          reason: editReason.trim(),
          ...payload,
        });
        toast.success("Report updated");
        void navigate(-1);
      } else {
        await submit({
          matchId: data.match._id,
          teamId: data.team._id,
          ...payload,
        });
        toast.success(\`Qual \${matchNumber} · team \${teamNumber} submitted\`);
        void navigate("/scout");
      }`);

// don't block on "you already reported this" while editing
s = s.replace("  if (data.myReport) {", "  if (data.myReport && !editId) {");

// reason box + button label
s = s.replace(`      {missing.length > 0 ? (`,
`      {editId ? (
        <Card>
          <CardHeader><CardTitle>Why are you changing this?</CardTitle></CardHeader>
          <CardContent className="space-y-2">
            <p className="text-muted-foreground text-sm">
              Appended to this report's history and never overwritten. Whoever
              reads the number later needs to know it moved, and why.
            </p>
            <Input
              placeholder="Reason (required)"
              value={editReason}
              onChange={(e) => setEditReason(e.target.value)}
            />
          </CardContent>
        </Card>
      ) : null}

      {missing.length > 0 ? (`);

s = s.replace(`        Submit report
      </Button>`, `        {editId ? "Save changes" : "Submit report"}
      </Button>`);

// editing an old match must not trip the early-submit warning
s = s.replace(`  const beforeMatchEnd = startedAt !== null && phase !== "over";`,
              `  const beforeMatchEnd = !editId && startedAt !== null && phase !== "over";`);

writeFileSync(p, s);
console.log("src/routes/scout/form.tsx patched");
MJS
bun /tmp/e3.mjs
rm -f /tmp/e1.mjs /tmp/e2.mjs /tmp/e3.mjs

say "Admin UI: confirm-by-team-number, edit links, pit reports, deletion log"
cat > /tmp/e4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/reports-admin.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("PitReportsAdmin")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { AlertTriangle, History, Trash2 } from "lucide-react";',
              'import { AlertTriangle, History, Pencil, Trash2 } from "lucide-react";');
s = s.replace('import { useMemo, useState } from "react";',
              'import { useMemo, useState } from "react";\nimport { Link } from "react-router";');

// --- typed confirmation on match report deletion, plus an edit link ---
const oldActions = `      <div className="flex flex-wrap gap-2">
        <Button size="sm" variant="outline"
          onClick={() => setAction(action === "winner" ? "none" : "winner")}>
          Set auto winner to {flip}
        </Button>
        <Button size="sm" variant="outline"
          onClick={() => setAction(action === "delete" ? "none" : "delete")}>
          <Trash2 className="size-3" /> Delete
        </Button>`;
if (!s.includes(oldActions)) fail("could not find the action row");
s = s.replace(oldActions, `      <div className="flex flex-wrap gap-2">
        <Button size="sm" variant="outline" render={
          <Link to={\`/scout/\${row.matchNumber}/\${row.teamNumber}?report=\${row.reportId}\`} />
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
        </Button>`);

const oldConfirm = `      {action !== "none" ? (
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
      ) : null}`;
if (!s.includes(oldConfirm)) fail("could not find the confirm block");
s = s.replace(oldConfirm, `      {action !== "none" ? (
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
              placeholder={\`Type \${row.teamNumber} to confirm\`}
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
      ) : null}`);

s = s.replace(`  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);`,
`  const [reason, setReason] = useState("");
  const [confirmText, setConfirmText] = useState("");
  const [busy, setBusy] = useState(false);`);

s = s.replace(`      setAction("none");
      setReason("");`, `      setAction("none");
      setReason("");
      setConfirmText("");`);

// --- pit reports + deletion log ---
s += `
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
      toast.success(\`Pit report for \${teamNumber} deleted\`);
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
                  render={<Link to={\`/pit/\${row.teamNumber}\`} />}>
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
                    placeholder={\`Type \${row.teamNumber} to confirm\`}
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
                  {row.kind === "pitReport" ? "Pit" : \`Qual \${row.matchNumber ?? "?"}\`}
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
`;
writeFileSync(p, s);
console.log("src/routes/admin/reports-admin.tsx patched");
MJS
bun /tmp/e4.mjs

cat > /tmp/e5.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/index.tsx";
let s = readFileSync(p, "utf8");
if (s.includes("PitReportsAdmin")) { console.log("already wired"); process.exit(0); }
s = s.replace('import { FlaggedReports, ManageReports } from "./reports-admin";',
  'import {\n  DeletionLog, FlaggedReports, ManageReports, PitReportsAdmin,\n} from "./reports-admin";');
s = s.replace("      <ManageReports />",
  "      <ManageReports />\n\n      <PitReportsAdmin />\n\n      <DeletionLog />");
writeFileSync(p, s);
console.log("src/routes/admin/index.tsx patched");
MJS
bun /tmp/e5.mjs
rm -f /tmp/e4.mjs /tmp/e5.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
