#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-picklist-fixes.sh
#   1. Team cards open the detail modal in place, not on /teams.
#   2. Tiers renamed: first / second / third pick.
#   3. Drops into a tier actually land.
#   4. Admin can populate the primary list with all teams (interim until the
#      merge exists).
# No schema change — the tier keys stay t1/t2/t3, only the labels move.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/picklists/board.tsx ]] || { echo "ERROR: run track-f.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Tier labels"
cat > /tmp/f1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/lib/types.ts";
let s = readFileSync(p, "utf8");
if (s.includes("First pick")) { console.log("already patched"); process.exit(0); }
const old = `export const TIER_LABELS: Record<Tier, string> = {
  t1: "Tier 1", t2: "Tier 2", t3: "Tier 3",
  dnp: "Do Not Pick", uncategorized: "Uncategorized",
};`;
if (!s.includes(old)) { console.error("could not find TIER_LABELS"); process.exit(1); }
s = s.replace(old, `// Keys stay t1/t2/t3 — renaming them would be a schema migration for no gain.
export const TIER_LABELS: Record<Tier, string> = {
  t1: "First pick", t2: "Second pick", t3: "Third pick",
  dnp: "Do not pick", uncategorized: "Uncategorized",
};`);
writeFileSync(p, s);
console.log("convex/lib/types.ts patched");
MJS
bun /tmp/f1.mjs

say "Primary list: populate with all teams"
cat > /tmp/f2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/pickLists.ts";
let s = readFileSync(p, "utf8");
if (s.includes("populatePrimary")) { console.log("already patched"); process.exit(0); }
s += `
/**
 * Drops every team into the primary list's Uncategorized column. The primary
 * list is meant to be filled by the merge, but until that exists an admin
 * needs some way to rank by hand. Skips teams already on the list, so it is
 * safe to run again after a re-import adds teams.
 */
export const populatePrimary = mutation({
  args: {},
  handler: async (ctx) => {
    await requireAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const list = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", null))
      .first();
    if (!list) throw new Error("There is no primary list yet.");

    const existing = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", list._id))
      .collect();
    const already = new Set(existing.map((e) => e.teamId));
    let order = existing.reduce((max, e) => Math.max(max, e.order), 0);

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    teams.sort((a, b) => a.number - b.number);

    let added = 0;
    for (const team of teams) {
      if (already.has(team._id)) continue;
      order += 1000;
      await ctx.db.insert("pickListEntries", {
        pickListId: list._id,
        teamId: team._id,
        tier: "uncategorized",
        order,
      });
      added += 1;
    }
    return { added };
  },
});
`;
writeFileSync(p, s);
console.log("convex/pickLists.ts patched");
MJS
bun /tmp/f2.mjs

say "Landing: populate button"
cat > /tmp/f3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/picklists/index.tsx";
let s = readFileSync(p, "utf8");
if (s.includes("populatePrimary")) { console.log("already patched"); process.exit(0); }
s = s.replace("  const ensurePrimary = useMutation(api.pickLists.ensurePrimary);",
`  const ensurePrimary = useMutation(api.pickLists.ensurePrimary);
  const populatePrimary = useMutation(api.pickLists.populatePrimary);`);
s = s.replace(`              <Button size="sm" variant="outline"
                render={<Link to={\`/picklists/\${primary._id}\`} />}>
                Open
              </Button>`,
`              {profile?.role === "admin" && primary.total === 0 ? (
                <Button size="sm" variant="secondary"
                  onClick={() => {
                    void populatePrimary({})
                      .then((r) => toast.success(\`\${r.added} teams added\`))
                      .catch((error: unknown) =>
                        toast.error("Could not populate", {
                          description: error instanceof Error ? error.message : String(error),
                        }));
                  }}>
                  Add all teams
                </Button>
              ) : null}
              <Button size="sm" variant="outline"
                render={<Link to={\`/picklists/\${primary._id}\`} />}>
                Open
              </Button>`);
writeFileSync(p, s);
console.log("src/routes/picklists/index.tsx patched");
MJS
bun /tmp/f3.mjs

say "Board: in-place modal and working drops"
cat > /tmp/f4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/picklists/board.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("overTier")) { console.log("already patched"); process.exit(0); }

s = s.replace(`import {
  DndContext, DragOverlay, PointerSensor, TouchSensor, closestCorners,
  useDroppable, useSensor, useSensors,
  type DragEndEvent, type DragStartEvent,
} from "@dnd-kit/core";`,
`import {
  DndContext, DragOverlay, PointerSensor, TouchSensor, closestCorners,
  pointerWithin, useDroppable, useSensor, useSensors,
  type CollisionDetection, type DragEndEvent, type DragOverEvent,
  type DragStartEvent,
} from "@dnd-kit/core";`);

s = s.replace(`import { Link, useNavigate, useParams } from "react-router";`,
              `import { Link, useParams } from "react-router";`);
s = s.replace(`import { TeamChip, type ChipStats } from "./team-chip";`,
              `import { TeamChip, type ChipStats } from "./team-chip";\nimport { TeamDetail } from "@/routes/teams/team-detail";`);
s = s.replace("  const navigate = useNavigate();\n", "");

// An empty column with no height is a droppable nothing can be dropped on.
s = s.replace(`        "min-w-64 flex-1 space-y-2 rounded-lg border p-2 transition-colors",`,
              `        "min-h-32 min-w-64 flex-1 space-y-2 rounded-lg border p-2 transition-colors",`);

s = s.replace("  const [dragging, setDragging] = useState<Row | null>(null);",
`  const [dragging, setDragging] = useState<Row | null>(null);
  // The last column the pointer was over. dnd-kit reports \`over\` as null at
  // the moment of release often enough that relying on it alone loses drops.
  const [overTier, setOverTier] = useState<Tier | null>(null);
  const [selectedTeam, setSelectedTeam] = useState<number | null>(null);

  // pointerWithin resolves a column the pointer is actually inside, which is
  // what makes a drop onto empty space in a tier work. closestCorners is the
  // fallback for when the pointer is between columns.
  const collision: CollisionDetection = (args) => {
    const within = pointerWithin(args);
    return within.length > 0 ? within : closestCorners(args);
  };`);

const oldStart = `  const onDragStart = (event: DragStartEvent) => {
    const row = (entries as Row[] | undefined)?.find((r) => r.entryId === event.active.id);
    setDragging(row ?? null);
  };`;
if (!s.includes(oldStart)) fail("could not find onDragStart");
s = s.replace(oldStart, `  const resolveTier = (overId: string | null): Tier | null => {
    if (!overId) return null;
    if (overId.startsWith("col:")) return overId.slice(4) as Tier;
    return ((entries ?? []) as Row[]).find((r) => r.entryId === overId)?.tier ?? null;
  };

  const onDragStart = (event: DragStartEvent) => {
    const row = (entries as Row[] | undefined)?.find((r) => r.entryId === event.active.id);
    setDragging(row ?? null);
    setOverTier(row?.tier ?? null);
  };

  const onDragOver = (event: DragOverEvent) => {
    const tier = resolveTier(event.over ? String(event.over.id) : null);
    if (tier) setOverTier(tier);
  };`);

const oldEnd = `    const overId = String(over.id);
    const target = overId.startsWith("col:")
      ? (overId.slice(4) as Tier)
      : rows.find((r) => r.entryId === overId)?.tier;
    if (!target) return;`;
if (!s.includes(oldEnd)) fail("could not find the drag end target resolution");
s = s.replace(oldEnd, `    const overId = String(over.id);
    const target = resolveTier(overId) ?? overTier;
    if (!target) return;`);

// `over` being null must not abandon a drag that had a known column.
s = s.replace(`    const { active, over } = event;
    if (!over) return;`,
`    const { active, over } = event;
    if (!over) {
      setOverTier(null);
      return;
    }`);
s = s.replace(`    setDragging(null);
    const { active, over } = event;`,
`    setDragging(null);
    const { active, over } = event;`);

s = s.replace(`      <DndContext sensors={sensors} collisionDetection={closestCorners}
        onDragStart={onDragStart} onDragEnd={onDragEnd}>`,
`      <DndContext sensors={sensors} collisionDetection={collision}
        onDragStart={onDragStart} onDragOver={onDragOver} onDragEnd={onDragEnd}>`);

s = s.replace(`                      onOpen={() => void navigate(\`/teams?team=\${row.teamNumber}\`)}`,
              `                      onOpen={() => setSelectedTeam(row.teamNumber)}`);

const oldClose = `      </DndContext>
    </PageShell>`;
if (!s.includes(oldClose)) fail("could not find the closing DndContext");
s = s.replace(oldClose, `      </DndContext>

      <TeamDetail teamNumber={selectedTeam} onClose={() => setSelectedTeam(null)} />
    </PageShell>`);

writeFileSync(p, s);
console.log("src/routes/picklists/board.tsx patched");
MJS
bun /tmp/f4.mjs
rm -f /tmp/f1.mjs /tmp/f2.mjs /tmp/f3.mjs /tmp/f4.mjs

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
