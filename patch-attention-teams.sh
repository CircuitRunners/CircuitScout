#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-attention-teams.sh — attention items on the teams tab.
#   Everyone sees them; admins, team admins and trusted scouts can settle them.
#
# CHANGES SCOPE: attention items become EVENT-WIDE rather than limited to your
# own team's scouts. A broken robot is a fact about the robot, and match
# reports are already pooled across teams at an event — scoping the warning
# but not the data it came from was inconsistent.
#
# No schema change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/admin.ts ]] || { echo "ERROR: run patch-attention.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Convex: shared attention module"
cat > convex/attention.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent, currentProfile, requireUser } from "./lib/guards";
import type { Doc } from "./_generated/dataModel";

/**
 * Who may settle an item. Trusted scouts are included deliberately: they are
 * the people in the stands who saw the robot, and making them wait for an
 * admin is how a warning sits unread through alliance selection.
 */
export function canSettle(profile: Doc<"profiles"> | null): boolean {
  if (!profile) return false;
  if (profile.role === "admin" || profile.role === "teamAdmin") return true;
  return profile.weightTier === "lead" || profile.weightTier === "trusted";
}

export const permissions = query({
  args: {},
  handler: async (ctx) => ({ canSettle: canSettle(await currentProfile(ctx)) }),
});

/**
 * Every outstanding broke/inconsistent report at the active event, from any
 * scouting team. Readable by anyone signed in.
 */
export const forEvent = query({
  args: {},
  handler: async (ctx) => {
    await requireUser(ctx);
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
      const team = teamById.get(report.teamId);
      if (!team) continue;

      for (const kind of ["broke", "inconsistent"] as const) {
        if (!report.ratings[kind]) continue;
        // A decision made before the report changed is stale.
        const settled = dismissals.find(
          (d) => d.reportId === report._id && d.reason === kind &&
                 d.dismissedAt >= report.updatedAt,
        );
        if (settled) continue;

        rows.push({
          reportId: report._id,
          kind,
          teamId: report.teamId,
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

export const settle = mutation({
  args: {
    reportId: v.id("matchReports"),
    kind: v.union(v.literal("broke"), v.literal("inconsistent")),
    state: v.union(v.literal("dismissed"), v.literal("resolved")),
    note: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);
    if (!canSettle(profile)) {
      throw new Error("Only admins and trusted scouts can settle these.");
    }
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
      dismissedBy: userId,
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
EOF
echo "convex/attention.ts written"

say "Shared warning component"
cat > src/components/attention-items.tsx <<'EOF'
import { useMutation, useQuery } from "convex/react";
import { AlertTriangle, Check, EyeOff, Wrench } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { api } from "../../convex/_generated/api";
import type { Id } from "../../convex/_generated/dataModel";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export type AttentionRow = {
  reportId: string;
  kind: "broke" | "inconsistent";
  teamNumber: number;
  nickname: string;
  matchNumber: number;
  scoutName: string;
  detail: string;
};

export const KIND_LABEL = {
  broke: "Broke down",
  inconsistent: "Inconsistent",
} as const;

/** Compact marker for a list row. */
export function AttentionBadge({ count }: { count: number }) {
  if (count === 0) return null;
  return (
    <Badge variant="destructive" className="shrink-0 text-[10px]">
      <AlertTriangle className="size-3" />
      {count}
    </Badge>
  );
}

export function AttentionCard({
  row,
  showTeam = false,
}: {
  row: AttentionRow;
  showTeam?: boolean;
}) {
  const settle = useMutation(api.attention.settle);
  const permissions = useQuery(api.attention.permissions);
  const [mode, setMode] = useState<"none" | "dismissed" | "resolved">("none");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [expanded, setExpanded] = useState(false);

  const detail = row.detail.trim();
  const long = detail.length > 90;
  const allowed = permissions?.canSettle ?? false;

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
    <div className="border-destructive/60 space-y-2 rounded-lg border p-3">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant="destructive" className="text-xs">
          <AlertTriangle className="size-3" />
          {KIND_LABEL[row.kind]}
        </Badge>
        {showTeam ? (
          <span className="font-semibold tabular-nums">{row.teamNumber}</span>
        ) : null}
        <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
          {showTeam ? `${row.nickname} · ` : ""}Qual {row.matchNumber} · {row.scoutName}
        </span>
      </div>

      {detail ? (
        <p
          className={["text-sm", long && !expanded ? "line-clamp-1 cursor-pointer" : ""].join(" ")}
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

      {allowed ? (
        <>
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
        </>
      ) : null}
    </div>
  );
}
EOF
echo "src/components/attention-items.tsx written"

say "Teams list: highlight and filter"
cat > /tmp/at1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/teams/index.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("needsAttention")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { api } from "../../../convex/_generated/api";',
  'import { api } from "../../../convex/_generated/api";\nimport { AttentionBadge } from "@/components/attention-items";');

s = s.replace("  const teams = useQuery(api.teams.listWithStatus);",
`  const teams = useQuery(api.teams.listWithStatus);
  const attention = useQuery(api.attention.forEvent);`);

s = s.replace(`type Filter = "all" | "no-pit" | "no-matches";`,
              `type Filter = "all" | "needs-help" | "no-pit" | "no-matches";`);
s = s.replace(`  { value: "all", label: "All" },`,
              `  { value: "all", label: "All" },\n  { value: "needs-help", label: "Needing assistance" },`);

// The filter button carries the count and glows when anything is outstanding —
// a filter nobody thinks to press is the same as no warning at all.
const oldFilterButton = `        {FILTERS.map((f) => (
          <Button
            key={f.value}
            size="sm"
            variant={filter === f.value ? "default" : "outline"}
            onClick={() => setFilter(f.value)}
          >
            {f.label}
          </Button>
        ))}`;
if (!s.includes(oldFilterButton)) fail("could not find the filter buttons");
s = s.replace(oldFilterButton, `        {FILTERS.map((f) => {
          const urgent = f.value === "needs-help" && attentionTeamCount > 0;
          return (
            <Button
              key={f.value}
              size="sm"
              variant={filter === f.value ? "default" : "outline"}
              className={
                urgent
                  ? "border-destructive text-destructive shadow-[0_0_10px_-1px_var(--destructive)] hover:text-destructive"
                  : ""
              }
              onClick={() => setFilter(f.value)}
            >
              {f.label}
              {urgent ? (
                <span className="bg-destructive ml-1 rounded-full px-1.5 text-[10px] font-semibold text-white tabular-nums">
                  {attentionTeamCount}
                </span>
              ) : null}
            </Button>
          );
        })}`);

s = s.replace("  const shown = useMemo(() => {",
`  // Count per team so a row can be marked without re-scanning the list.
  const attentionByTeam = useMemo(() => {
    const counts = new Map<number, number>();
    for (const row of attention ?? []) {
      counts.set(row.teamNumber, (counts.get(row.teamNumber) ?? 0) + 1);
    }
    return counts;
  }, [attention]);

  // Teams, not reports: three warnings on one robot is one team to look at.
  const attentionTeamCount = attentionByTeam.size;

  const shown = useMemo(() => {`);

s = s.replace(`      if (filter === "no-pit" && team.pitScouted) return false;`,
`      if (filter === "needs-help" && (attentionByTeam.get(team.number) ?? 0) === 0) {
        return false;
      }
      if (filter === "no-pit" && team.pitScouted) return false;`);
s = s.replace("  }, [teams, search, filter]);", "  }, [teams, search, filter, attentionByTeam]);");

const oldCard = `            <TeamCard
              key={team._id}
              number={team.number}
              nickname={team.nickname}
              pitScouted={team.pitScouted}
              reportCount={team.reportCount}
              tier={team.tier as Tier}
              onClick={() => open(team.number)}
            />`;
if (!s.includes(oldCard)) fail("could not find the team card");
s = s.replace(oldCard, `            <div key={team._id}
              className={
                (attentionByTeam.get(team.number) ?? 0) > 0
                  ? "border-destructive rounded-lg border-2"
                  : ""
              }>
              <TeamCard
                number={team.number}
                nickname={team.nickname}
                pitScouted={team.pitScouted}
                reportCount={team.reportCount}
                tier={team.tier as Tier}
                attention={attentionByTeam.get(team.number) ?? 0}
                onClick={() => open(team.number)}
              />
            </div>`);

writeFileSync(p, s);
console.log("src/routes/teams/index.tsx patched");
MJS
bun /tmp/at1.mjs

cat > /tmp/at2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/components/scouting/team-card.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("attention")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { Badge } from "@/components/ui/badge";',
  'import { Badge } from "@/components/ui/badge";\nimport { AttentionBadge } from "@/components/attention-items";');
s = s.replace(`  tier?: Tier;
  onClick?: () => void;
}) {`, `  tier?: Tier;
  attention?: number;
  onClick?: () => void;
}) {`);
s = s.replace(`  tier,
  onClick,
}: {`, `  tier,
  attention = 0,
  onClick,
}: {`);
const badgeAnchor = `      <div className="flex shrink-0 items-center gap-1.5">`;
if (!s.includes(badgeAnchor)) fail("could not find the badge row");
s = s.replace(badgeAnchor, `      <div className="flex shrink-0 items-center gap-1.5">
        <AttentionBadge count={attention} />`);
writeFileSync(p, s);
console.log("src/components/scouting/team-card.tsx patched");
MJS
bun /tmp/at2.mjs

say "Team detail: warning under the location"
cat > /tmp/at3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/teams/team-detail.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("AttentionCard")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { api } from "../../../convex/_generated/api";',
  'import { api } from "../../../convex/_generated/api";\nimport { AttentionCard, type AttentionRow } from "@/components/attention-items";');

s = s.replace("  const epa = useEpa(teamNumber);",
`  const epa = useEpa(teamNumber);
  const attention = useQuery(api.attention.forEvent);
  const mine = (attention ?? []).filter((row) => row.teamNumber === teamNumber);`);

const locationBlock = `            <p className="text-muted-foreground text-sm">
              {[data.team.city, data.team.stateProv, data.team.country]
                .filter(Boolean)
                .join(", ")}
            </p>`;
if (!s.includes(locationBlock)) fail("could not find the location line");
s = s.replace(locationBlock, `${locationBlock}

            {mine.length > 0 ? (
              <div className="space-y-2">
                {mine.map((row) => (
                  <AttentionCard key={\`\${row.reportId}-\${row.kind}\`}
                    row={row as AttentionRow} />
                ))}
              </div>
            ) : null}`);

writeFileSync(p, s);
console.log("src/routes/teams/team-detail.tsx patched");
MJS
bun /tmp/at3.mjs

say "Admin card: one source of truth"
cat > /tmp/at4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/reports-admin.tsx";
let s = readFileSync(p, "utf8");
if (s.includes("api.attention.forEvent")) { console.log("already patched"); process.exit(0); }
s = s.replace("  const rows = useQuery(api.admin.attentionItems);",
              "  const rows = useQuery(api.attention.forEvent);");
s = s.replace(`            <AttentionRowCard key={\`\${row.reportId}-\${row.kind}\`}
              row={row as AttentionRow} />`,
`            <SharedAttentionCard key={\`\${row.reportId}-\${row.kind}\`}
              row={row as AttentionRow} showTeam />`);
s = s.replace('import { api } from "../../../convex/_generated/api";',
  'import { api } from "../../../convex/_generated/api";\nimport {\n  AttentionCard as SharedAttentionCard,\n  type AttentionRow,\n} from "@/components/attention-items";');
writeFileSync(p, s);
console.log("src/routes/admin/reports-admin.tsx patched");
MJS
bun /tmp/at4.mjs
rm -f /tmp/at1.mjs /tmp/at2.mjs /tmp/at3.mjs /tmp/at4.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
