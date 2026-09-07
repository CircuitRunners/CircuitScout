#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-event-purge.sh — full admins can permanently delete an event and
# everything attached to it.
#
# events.remove stays as the safe path — it still refuses when data exists.
# This is a separate, deliberately harder mutation, so nothing that used to be
# safe silently became destructive.
#
# No schema change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/events.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Convex: purge preview and purge"
cat > /tmp/pu.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/events.ts";
let s = readFileSync(p, "utf8");
if (s.includes("purgePreview")) { console.log("already patched"); process.exit(0); }
s += `
/** Exactly what a purge would destroy. Read-only; nothing acts on this. */
export const purgePreview = query({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) return null;

    const [teams, matches, reports, pit, lists, settings] = await Promise.all([
      ctx.db.query("teams").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("matches").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("matchReports").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("pitReports").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("pickLists").withIndex("by_event", (q) => q.eq("eventId", args.eventId)).collect(),
      ctx.db.query("teamSettings").collect(),
    ]);

    const scouts = new Set(reports.map((r) => r.scoutId));
    const activeFor = settings
      .filter((t) => t.activeEventId === args.eventId)
      .map((t) => t.teamNumber);

    return {
      eventKey: event.tbaEventKey,
      name: event.name,
      teams: teams.length,
      matches: matches.length,
      matchReports: reports.length,
      pitReports: pit.length,
      pickLists: lists.length,
      contributingScouts: scouts.size,
      activeFor,
    };
  },
});

/**
 * Deletes an event and everything attached to it. Full admins only, and
 * separate from events.remove so the safe path stays safe.
 *
 * Order matters: children before parents, so a failure part-way leaves
 * orphaned rows rather than rows pointing at an event that no longer exists.
 */
export const purge = mutation({
  args: { eventId: v.id("events"), confirmKey: v.string() },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) throw new Error("That event no longer exists.");
    if (args.confirmKey.trim() !== event.tbaEventKey) {
      throw new Error("The event key does not match.");
    }

    const counts = { matchReports: 0, pitReports: 0, entries: 0, lists: 0, matches: 0, teams: 0 };

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const report of reports) {
      const edits = await ctx.db
        .query("reportEdits")
        .withIndex("by_report", (q) => q.eq("reportId", report._id))
        .collect();
      for (const edit of edits) await ctx.db.delete(edit._id);
      const dismissals = await ctx.db
        .query("flagDismissals")
        .withIndex("by_report", (q) => q.eq("reportId", report._id))
        .collect();
      for (const row of dismissals) await ctx.db.delete(row._id);
      await ctx.db.delete(report._id);
      counts.matchReports += 1;
    }

    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const row of pit) { await ctx.db.delete(row._id); counts.pitReports += 1; }

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const list of lists) {
      const entries = await ctx.db
        .query("pickListEntries")
        .withIndex("by_list", (q) => q.eq("pickListId", list._id))
        .collect();
      for (const entry of entries) { await ctx.db.delete(entry._id); counts.entries += 1; }
      await ctx.db.delete(list._id);
      counts.lists += 1;
    }

    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const match of matches) {
      const claims = await ctx.db
        .query("matchClaims")
        .withIndex("by_match_team", (q) => q.eq("matchId", match._id))
        .collect();
      for (const claim of claims) await ctx.db.delete(claim._id);
      await ctx.db.delete(match._id);
      counts.matches += 1;
    }

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const team of teams) { await ctx.db.delete(team._id); counts.teams += 1; }

    // Any team pointing at this event is left with none rather than a
    // dangling id, so their app says "no active event" instead of breaking.
    const settings = await ctx.db.query("teamSettings").collect();
    for (const row of settings) {
      if (row.activeEventId === args.eventId) {
        await ctx.db.patch(row._id, { activeEventId: null, updatedAt: Date.now() });
      }
    }

    await ctx.db.delete(args.eventId);
    return counts;
  },
});
`;
writeFileSync(p, s);
console.log("convex/events.ts patched");
MJS
bun /tmp/pu.mjs

say "Admin UI: delete button and confirmation"
cat > /tmp/pu2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/index.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("purgeTarget")) { console.log("already patched"); process.exit(0); }

s = s.replace(/import \{ ([^}]*) \} from "lucide-react";/,
              'import { $1, Trash } from "lucide-react";');
s = s.replace("  const setActiveForTeam = useMutation(api.events.setActiveForTeam);",
`  const setActiveForTeam = useMutation(api.events.setActiveForTeam);
  const purgeEvent = useMutation(api.events.purge);
  const [purgeTarget, setPurgeTarget] = useState<string | null>(null);
  const [purgeKey, setPurgeKey] = useState("");
  const [purging, setPurging] = useState(false);`);

// the red button, left of the activate control
const activate = `                {targetTeam === null ? (`;
if (!s.includes(activate)) fail("could not find the activation control");
s = s.replace(activate, `                {isFullAdmin ? (
                  <Button variant="destructive" size="sm"
                    onClick={() => {
                      setPurgeTarget(purgeTarget === event._id ? null : event._id);
                      setPurgeKey("");
                    }}>
                    <Trash className="size-3" /> Delete
                  </Button>
                ) : null}
                {targetTeam === null ? (`);

// the confirmation panel, inside the row so it wraps underneath
const removeBlock = `              {removing === event._id ? (`;
if (!s.includes(removeBlock)) fail("could not find the removal panel");
s = s.replace(removeBlock, `              {purgeTarget === event._id ? (
                <PurgePanel
                  eventId={event._id}
                  confirmKey={purgeKey}
                  onConfirmKeyChange={setPurgeKey}
                  busy={purging}
                  onCancel={() => { setPurgeTarget(null); setPurgeKey(""); }}
                  onPurge={() => {
                    setPurging(true);
                    void purgeEvent({ eventId: event._id, confirmKey: purgeKey })
                      .then((c) => {
                        toast.success(\`\${event.name} deleted\`, {
                          description:
                            \`\${c.matchReports} match reports, \${c.pitReports} pit reports, \` +
                            \`\${c.lists} pick lists, \${c.matches} matches, \${c.teams} teams.\`,
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

${removeBlock}`);

// the panel component
s = s.replace("export default function AdminPage() {", `function PurgePanel({
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
        This permanently deletes {preview.name} and everything attached to it.
      </p>
      <ul className="text-muted-foreground space-y-0.5 text-xs">
        <li>{preview.matchReports} match reports
          {preview.contributingScouts > 0
            ? \` from \${preview.contributingScouts} scouts\`
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
          Export from Coverage and Quality first if you want to keep any of it —
          there is no undo and no snapshot.
        </p>
      )}
      <Input
        placeholder={\`Type \${preview.eventKey} to confirm\`}
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

export default function AdminPage() {`);

if (!s.includes('import type { Id }')) {
  s = s.replace('import { api } from "../../../convex/_generated/api";',
    'import { api } from "../../../convex/_generated/api";\nimport type { Id } from "../../../convex/_generated/dataModel";');
}

writeFileSync(p, s);
console.log("src/routes/admin/index.tsx patched");
MJS
bun /tmp/pu2.mjs
rm -f /tmp/pu.mjs /tmp/pu2.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
