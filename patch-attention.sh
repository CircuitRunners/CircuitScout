#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-attention.sh — "Teams Needing Attention" above Flagged.
#
# Reuses flagDismissals rather than adding a table, so the staleness rule comes
# free: a dismissal made before a report was edited does not silence the item
# the edit caused. Adds an optional `state` so dismissed and resolved are
# distinguishable — both hide the item, but they mean different things.
#
# SCHEMA CHANGE: flagDismissals.state (optional).
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/admin.ts ]] || { echo "ERROR: run patch-admin-reports.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema"
cat > /tmp/a1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("state: v.optional(v.union(v.literal(\"dismissed\")")) {
  console.log("already patched"); process.exit(0);
}
const anchor = `  flagDismissals: defineTable({
    reportId: v.id("matchReports"),
    reason: v.string(),`;
if (!s.includes(anchor)) fail("could not find flagDismissals");
s = s.replace(anchor, `${anchor}
    /** "resolved" means someone fixed it; "dismissed" means it was fine. */
    state: v.optional(v.union(v.literal("dismissed"), v.literal("resolved"))),`);
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/a1.mjs

say "Convex: attention query and actions"
cat > /tmp/a2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/admin.ts";
let s = readFileSync(p, "utf8");
if (s.includes("attentionItems")) { console.log("already patched"); process.exit(0); }

s += `
/**
 * Robots a scout reported as broken or inconsistent. Separate from the flagged
 * list: those are doubts about the DATA, these are facts about a ROBOT, and
 * conflating them buries the ones a strategy lead needs before a pick.
 */
export const attentionItems = query({
  args: {},
  handler: async (ctx) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) return [];

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();

    const profiles = await ctx.db.query("profiles").collect();
    const byUser = new Map(profiles.map((p) => [p.userId, p]));
    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const teamById = new Map(teams.map((t) => [t._id, t]));
    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    const matchById = new Map(matches.map((m) => [m._id, m]));

    const dismissals = await ctx.db.query("flagDismissals").collect();

    const rows = [];
    for (const report of reports) {
      if (!managesTeam(me, byUser.get(report.scoutId)?.teamNumber)) continue;
      const team = teamById.get(report.teamId);
      if (!team) continue;

      for (const kind of ["broke", "inconsistent"] as const) {
        if (!report.ratings[kind]) continue;

        // A decision made before the report changed is stale, same rule the
        // flagged list uses.
        const handled = dismissals.find(
          (d) => d.reportId === report._id && d.reason === kind &&
                 d.dismissedAt >= report.updatedAt,
        );
        if (handled) continue;

        rows.push({
          reportId: report._id,
          kind,
          teamNumber: team.number,
          nickname: team.nickname,
          matchNumber: matchById.get(report.matchId)?.matchNumber ?? 0,
          scoutName: byUser.get(report.scoutId)?.displayName ?? "Unknown scout",
          detail: kind === "broke"
            ? report.ratings.brokeNotes
            : report.ratings.inconsistentNotes,
          submittedAt: report.submittedAt,
        });
      }
    }

    return rows.sort((a, b) => b.submittedAt - a.submittedAt);
  },
});

/** Dismiss ("it was fine") or resolve ("it has been dealt with"). */
export const settleAttention = mutation({
  args: {
    reportId: v.id("matchReports"),
    kind: v.union(v.literal("broke"), v.literal("inconsistent")),
    state: v.union(v.literal("dismissed"), v.literal("resolved")),
    note: v.string(),
  },
  handler: async (ctx, args) => {
    const admin = await requireTeamAdmin(ctx);
    const note = args.note.trim();
    if (note === "") throw new Error("A note is required.");

    const existing = await ctx.db
      .query("flagDismissals")
      .withIndex("by_report_reason", (q) =>
        q.eq("reportId", args.reportId).eq("reason", args.kind))
      .unique();

    const fields = {
      note,
      state: args.state,
      dismissedBy: admin.userId,
      dismissedAt: Date.now(),
    };

    if (existing) {
      await ctx.db.patch(existing._id, fields);
      return existing._id;
    }
    return await ctx.db.insert("flagDismissals", {
      reportId: args.reportId,
      reason: args.kind,
      ...fields,
    });
  },
});
`;
writeFileSync(p, s);
console.log("convex/admin.ts patched");
MJS
bun /tmp/a2.mjs

say "Client: the attention card"
cat > /tmp/a3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/reports-admin.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("TeamsNeedingAttention")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { AlertTriangle, EyeOff, History, Pencil, RotateCcw, Trash2 } from "lucide-react";',
  'import {\n  AlertTriangle, Check, EyeOff, History, Pencil, RotateCcw, Trash2, Wrench,\n} from "lucide-react";');

s += `
type AttentionRow = {
  reportId: string;
  kind: "broke" | "inconsistent";
  teamNumber: number;
  nickname: string;
  matchNumber: number;
  scoutName: string;
  detail: string;
};

function AttentionRowCard({ row }: { row: AttentionRow }) {
  const settle = useMutation(api.admin.settleAttention);
  const [mode, setMode] = useState<"none" | "dismissed" | "resolved">("none");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [expanded, setExpanded] = useState(false);

  const detail = row.detail.trim();
  const long = detail.length > 90;

  const run = () => {
    if (mode === "none") return;
    setBusy(true);
    void settle({
      reportId: row.reportId as Id<"matchReports">,
      kind: row.kind,
      state: mode,
      note,
    })
      .then(() => toast.success(mode === "resolved" ? "Marked resolved" : "Dismissed"))
      .catch((error: unknown) =>
        toast.error("Failed", {
          description: error instanceof Error ? error.message : String(error),
        }))
      .finally(() => setBusy(false));
  };

  return (
    <div className="space-y-2 rounded-lg border p-3">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant="destructive" className="text-xs">
          <AlertTriangle className="size-3" />
          {row.kind === "broke" ? "Broke down" : "Inconsistent"}
        </Badge>
        <span className="font-semibold tabular-nums">{row.teamNumber}</span>
        <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
          {row.nickname} · Qual {row.matchNumber} · {row.scoutName}
        </span>
      </div>

      {detail ? (
        <p
          className={[
            "text-sm",
            long && !expanded ? "line-clamp-1 cursor-pointer" : "",
          ].join(" ")}
          title={long ? detail : undefined}
          onClick={() => long && setExpanded(!expanded)}
        >
          {detail}
        </p>
      ) : (
        <p className="text-muted-foreground text-sm italic">
          No reason given — worth asking the scout before acting on it.
        </p>
      )}

      <div className="flex flex-wrap gap-2">
        <Button size="sm" variant="secondary"
          onClick={() => { setMode(mode === "resolved" ? "none" : "resolved"); setNote(""); }}>
          <Wrench className="size-3" /> Resolve
        </Button>
        <Button size="sm" variant="outline"
          onClick={() => { setMode(mode === "dismissed" ? "none" : "dismissed"); setNote(""); }}>
          <EyeOff className="size-3" /> Dismiss
        </Button>
      </div>

      {mode !== "none" ? (
        <div className="space-y-2 rounded-md border border-dashed p-3">
          <p className="text-muted-foreground text-xs">
            {mode === "resolved"
              ? "Resolved says the problem was dealt with — a repair, a rematch, a conversation."
              : "Dismissed says it was not really a problem."}{" "}
            Either way the note is what the next person reads.
          </p>
          <Input placeholder="What happened? (required)" value={note}
            onChange={(e) => setNote(e.target.value)} />
          <Button size="sm" variant={mode === "resolved" ? "secondary" : "default"}
            disabled={busy || note.trim() === ""} onClick={run}>
            <Check className="size-3" /> Confirm
          </Button>
        </div>
      ) : null}
    </div>
  );
}

export function TeamsNeedingAttention() {
  const rows = useQuery(api.admin.attentionItems);

  return (
    <Card>
      <CardHeader>
        <CardTitle>
          Teams needing attention
          {(rows ?? []).length > 0 ? (
            <Badge variant="destructive" className="ml-2">{rows?.length}</Badge>
          ) : null}
        </CardTitle>
        <CardDescription>
          Robots a scout saw break down or behave inconsistently. These are
          facts about a robot, not doubts about the data — an unread one is a
          pick nobody warned you about.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        {rows === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) : rows.length === 0 ? (
          <p className="text-muted-foreground text-sm">
            Nothing outstanding.
          </p>
        ) : (
          rows.map((row) => (
            <AttentionRowCard key={\`\${row.reportId}-\${row.kind}\`}
              row={row as AttentionRow} />
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
bun /tmp/a3.mjs

cat > /tmp/a4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/index.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("TeamsNeedingAttention")) { console.log("already wired"); process.exit(0); }
s = s.replace(/import \{\n(\s*)DeletionLog, FlaggedReports, ManageReports, PitReportsAdmin,\n\} from "\.\/reports-admin";/,
  'import {\n$1DeletionLog, FlaggedReports, ManageReports, PitReportsAdmin,\n$1TeamsNeedingAttention,\n} from "./reports-admin";');
if (!s.includes("TeamsNeedingAttention")) {
  s = s.replace('} from "./reports-admin";', ', TeamsNeedingAttention } from "./reports-admin";');
}
const anchor = "      <FlaggedReports />";
if (!s.includes(anchor)) fail("could not find FlaggedReports");
s = s.replace(anchor, `      <TeamsNeedingAttention />\n\n${anchor}`);
writeFileSync(p, s);
console.log("src/routes/admin/index.tsx patched");
MJS
bun /tmp/a4.mjs
rm -f /tmp/a1.mjs /tmp/a2.mjs /tmp/a3.mjs /tmp/a4.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
