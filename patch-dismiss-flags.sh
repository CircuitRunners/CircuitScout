#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-dismiss-flags.sh
#   Lets an admin dismiss an individual flag on a report, with a note.
#
# SCHEMA CHANGE: flagDismissals table.
#
# A dismissal is scoped to one reason on one report and goes STALE if the
# report is edited afterwards — otherwise dismissing "dead-hub" today would
# suppress a genuine dead-hub flag caused by an edit next week.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/admin.ts ]] || { echo "ERROR: run patch-admin-reports.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema: flagDismissals"
cat > /tmp/d1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
if (s.includes("flagDismissals")) { console.log("already present"); process.exit(0); }
const anchor = "  pickLists: defineTable({";
if (!s.includes(anchor)) { console.error("could not find pickLists"); process.exit(1); }
s = s.replace(anchor, `  /**
   * A dismissed flag. Scoped to one reason on one report, and compared against
   * the report's updatedAt on read — a dismissal made before an edit does not
   * silence a flag the edit caused.
   */
  flagDismissals: defineTable({
    reportId: v.id("matchReports"),
    reason: v.string(),
    note: v.string(),
    dismissedBy: v.id("users"),
    dismissedAt: v.number(),
  })
    .index("by_report", ["reportId"])
    .index("by_report_reason", ["reportId", "reason"]),

${anchor}`);
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/d1.mjs

say "Convex: dismissal logic"
cat > /tmp/d2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/admin.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("dismissFlag")) { console.log("already patched"); process.exit(0); }

// Row type gains the dismissed list.
s = s.replace(`  reasons: FlagReason[];
  reasonLabels: string[];
};`, `  reasons: FlagReason[];
  reasonLabels: string[];
  dismissed: {
    reason: FlagReason;
    label: string;
    note: string;
    byName: string;
    at: number;
  }[];
};`);

// Load dismissals alongside everything else.
s = s.replace(`    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    // Auto-winner answers per match`,
`    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));

    const allDismissals = await ctx.db.query("flagDismissals").collect();
    const dismissalsByReport = new Map<string, typeof allDismissals>();
    for (const d of allDismissals) {
      const list = dismissalsByReport.get(d.reportId) ?? [];
      list.push(d);
      dismissalsByReport.set(d.reportId, list);
    }

    // Auto-winner answers per match`);

// Split computed reasons into active and dismissed.
const oldPush = `      if (args.onlyFlagged && reasons.length === 0) continue;`;
if (!s.includes(oldPush)) fail("could not find the onlyFlagged filter");
s = s.replace(oldPush, `      // A dismissal made before the report was last edited is stale: the edit
      // may be exactly what caused the flag to reappear.
      const dismissalsFor = dismissalsByReport.get(report._id) ?? [];
      const live = new Map(
        dismissalsFor
          .filter((d) => d.dismissedAt >= report.updatedAt)
          .map((d) => [d.reason, d]),
      );

      const dismissed = reasons
        .filter((r) => live.has(r))
        .map((r) => {
          const d = live.get(r);
          return {
            reason: r,
            label: REASON_LABELS[r],
            note: d?.note ?? "",
            byName: d ? (nameByUser.get(d.dismissedBy) ?? "Unknown") : "Unknown",
            at: d?.dismissedAt ?? 0,
          };
        });

      const activeReasons = reasons.filter((r) => !live.has(r));

      if (args.onlyFlagged && activeReasons.length === 0 && dismissed.length === 0) {
        continue;
      }`);

s = s.replace(`        reasons,
        reasonLabels: reasons.map((r) => REASON_LABELS[r]),
      });`,
`        reasons: activeReasons,
        reasonLabels: activeReasons.map((r) => REASON_LABELS[r]),
        dismissed,
      });`);

// New mutations.
s += `
/**
 * Dismisses one flag on one report. The note is required — a dismissal is an
 * assertion that someone checked, and the next person to read the number needs
 * to know what was checked.
 */
export const dismissFlag = mutation({
  args: {
    reportId: v.id("matchReports"),
    reason: v.string(),
    note: v.string(),
  },
  handler: async (ctx, args) => {
    const admin = await requireAdmin(ctx);
    const note = args.note.trim();
    if (note === "") throw new Error("A note is required.");

    const report = await ctx.db.get(args.reportId);
    if (!report) throw new Error("That report no longer exists.");

    const existing = await ctx.db
      .query("flagDismissals")
      .withIndex("by_report_reason", (q) =>
        q.eq("reportId", args.reportId).eq("reason", args.reason))
      .unique();

    if (existing) {
      await ctx.db.patch(existing._id, {
        note,
        dismissedBy: admin.userId,
        dismissedAt: Date.now(),
      });
      return existing._id;
    }

    return await ctx.db.insert("flagDismissals", {
      reportId: args.reportId,
      reason: args.reason,
      note,
      dismissedBy: admin.userId,
      dismissedAt: Date.now(),
    });
  },
});

/** Puts a dismissed flag back. */
export const restoreFlag = mutation({
  args: { reportId: v.id("matchReports"), reason: v.string() },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const existing = await ctx.db
      .query("flagDismissals")
      .withIndex("by_report_reason", (q) =>
        q.eq("reportId", args.reportId).eq("reason", args.reason))
      .unique();
    if (existing) await ctx.db.delete(existing._id);
  },
});
`;
writeFileSync(p, s);
console.log("convex/admin.ts patched");
MJS
bun /tmp/d2.mjs

say "Client: dismiss and restore"
cat > /tmp/d3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/reports-admin.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("dismissFlag")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { AlertTriangle, History, Pencil, Trash2 } from "lucide-react";',
              'import { AlertTriangle, EyeOff, History, Pencil, RotateCcw, Trash2 } from "lucide-react";');

// Row type
s = s.replace(`  editCount: number;
  reasonLabels: string[];
};`, `  editCount: number;
  reasons: string[];
  reasonLabels: string[];
  dismissed: {
    reason: string;
    label: string;
    note: string;
    byName: string;
    at: number;
  }[];
};`);

// Flag rendering with dismiss / restore
const oldFlags = `      {row.reasonLabels.length > 0 ? (
        <div className="flex flex-wrap gap-1">
          {row.reasonLabels.map((label) => (
            <Badge key={label} variant="destructive" className="text-xs">
              <AlertTriangle className="size-3" />
              {label}
            </Badge>
          ))}
        </div>
      ) : null}`;
if (!s.includes(oldFlags)) fail("could not find the flag badges");
s = s.replace(oldFlags, `      {row.reasons.length > 0 ? (
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
      ) : null}`);

// state + handlers
s = s.replace(`  const setAutoWinner = useMutation(api.admin.setAutoWinner);
  const deleteReport = useMutation(api.admin.deleteReport);`,
`  const setAutoWinner = useMutation(api.admin.setAutoWinner);
  const deleteReport = useMutation(api.admin.deleteReport);
  const dismissFlag = useMutation(api.admin.dismissFlag);
  const restoreFlag = useMutation(api.admin.restoreFlag);`);

s = s.replace(`  const [confirmText, setConfirmText] = useState("");
  const [busy, setBusy] = useState(false);`,
`  const [confirmText, setConfirmText] = useState("");
  const [busy, setBusy] = useState(false);
  const [dismissing, setDismissing] = useState<string | null>(null);
  const [dismissNote, setDismissNote] = useState("");`);

s = s.replace(`  const flip = row.autoWinner === "red" ? "blue" : "red";
  const id = row.reportId as Id<"matchReports">;`,
`  const flip = row.autoWinner === "red" ? "blue" : "red";
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
  };`);

// Flagged section wording
s = s.replace(`          Reports with a data-quality problem. Flags are recomputed on every
          read, so correcting a report clears its flag immediately — there is no
          stale marker to chase.`,
`          Reports with a data-quality problem. Flags are recomputed on every
          read, so correcting a report clears its flag immediately. A dismissed
          flag stays visible here with its note, and comes back automatically if
          the report is edited afterwards.`);

writeFileSync(p, s);
console.log("src/routes/admin/reports-admin.tsx patched");
MJS
bun /tmp/d3.mjs
rm -f /tmp/d1.mjs /tmp/d2.mjs /tmp/d3.mjs

say "Regenerating Convex types before typecheck"
bunx convex dev --once || echo "Convex push skipped or failed — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
