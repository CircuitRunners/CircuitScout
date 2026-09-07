#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-pick-notes.sh
#   1. Search box on the pick list board.
#   2. Pick notes per entry, edited from the team card. Required on first picks
#      — enforced when the list is submitted, not when the card is dragged.
#
# SCHEMA CHANGE: pickListEntries.note (optional).
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/picklists/board.tsx ]] || { echo "ERROR: run track-f.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema"
cat > /tmp/n1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
if (s.includes("note: v.optional(v.string())")) { console.log("already patched"); process.exit(0); }
const marker = /(pickListEntries: defineTable\(\{[\s\S]*?)(\n\s*order: v\.number\(\),)/;
if (!marker.test(s)) { console.error("could not find pickListEntries.order"); process.exit(1); }
s = s.replace(marker, "$1$2\n    note: v.optional(v.string()),");
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/n1.mjs

say "Convex: notes and the submission gate"
cat > /tmp/n2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

let e = readFileSync("convex/entries.ts", "utf8");
if (!e.includes("setNote")) {
  e = e.replace("        tier: entry.tier,\n        order: entry.order,",
                "        tier: entry.tier,\n        order: entry.order,\n        note: entry.note ?? \"\",");
  e += `
/** A note on why this team sits where it does. */
export const setNote = mutation({
  args: { entryId: v.id("pickListEntries"), note: v.string() },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);

    const entry = await ctx.db.get(args.entryId);
    if (!entry) throw new Error("That card no longer exists.");
    const list = await ctx.db.get(entry.pickListId);
    if (!list) throw new Error("That list no longer exists.");

    if (list.ownerId === null) {
      if (profile?.role !== "admin") {
        throw new Error("Only an admin can edit the primary list.");
      }
    } else if (list.ownerId !== userId) {
      throw new Error("That is someone else's list.");
    }

    await ctx.db.patch(args.entryId, { note: args.note });
  },
});
`;
  writeFileSync("convex/entries.ts", e);
  console.log("convex/entries.ts patched");
}

let p = readFileSync("convex/pickLists.ts", "utf8");
if (!p.includes("needs a note")) {
  const anchor = `    const mine = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", userId))
      .collect();`;
  if (!p.includes(anchor)) fail("could not find setSubmitted");
  p = p.replace(anchor, `    // A first pick is the one choice the whole team has to defend out loud, so
    // it does not go in without a reason. Checked here rather than on the drag:
    // the note is written after the card moves, not before.
    const first = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list_tier", (q) =>
        q.eq("pickListId", args.listId).eq("tier", "t1"))
      .collect();
    const missing = [];
    for (const entry of first) {
      if ((entry.note ?? "").trim() !== "") continue;
      const team = await ctx.db.get(entry.teamId);
      missing.push(team ? String(team.number) : "a team");
    }
    if (missing.length > 0) {
      throw new Error(
        \`Every first pick needs a note before this list can be submitted. Missing: \${missing.join(", ")}.\`,
      );
    }

${anchor}`);
  writeFileSync("convex/pickLists.ts", p);
  console.log("convex/pickLists.ts patched");
}
MJS
bun /tmp/n2.mjs

say "Team detail: optional footer slot"
cat > /tmp/n3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/teams/team-detail.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("footer")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { useQuery } from "convex/react";',
              'import { useQuery } from "convex/react";\nimport type { ReactNode } from "react";');

const oldProps = `export function TeamDetail({
  teamNumber,
  onClose,
}: {
  teamNumber: number | null;
  onClose: () => void;
}) {`;
if (!s.includes(oldProps)) fail("could not find the TeamDetail props");
s = s.replace(oldProps, `export function TeamDetail({
  teamNumber,
  onClose,
  footer,
}: {
  teamNumber: number | null;
  onClose: () => void;
  /** Rendered at the bottom of the modal. The pick list passes its note editor. */
  footer?: ReactNode;
}) {`);

const oldEnd = `          </>
        )}
      </DialogContent>`;
if (!s.includes(oldEnd)) fail("could not find the modal body end");
s = s.replace(oldEnd, `            {footer}
          </>
        )}
      </DialogContent>`);

writeFileSync(p, s);
console.log("src/routes/teams/team-detail.tsx patched");
MJS
bun /tmp/n3.mjs

say "Chip: note indicator"
cat > /tmp/n4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/picklists/team-chip.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("needsNote")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { GripVertical } from "lucide-react";',
              'import { GripVertical, MessageSquare, MessageSquareWarning } from "lucide-react";');
s = s.replace(`  stats: ChipStats | null;
  draggable: boolean;
  onOpen: () => void;
}) {`,
`  stats: ChipStats | null;
  draggable: boolean;
  note: string;
  needsNote: boolean;
  onOpen: () => void;
}) {`);
s = s.replace(`  pitScouted,
  stats,
  draggable,
  onOpen,
}: {`,
`  pitScouted,
  stats,
  draggable,
  note,
  needsNote,
  onOpen,
}: {`);

const oldBadge = `        <Badge variant={pitScouted ? "secondary" : "outline"} className="shrink-0 text-[10px]">
          {pitScouted ? "Pit" : "No pit"}
        </Badge>`;
if (!s.includes(oldBadge)) fail("could not find the pit badge");
s = s.replace(oldBadge, `        {needsNote ? (
          <MessageSquareWarning className="text-destructive size-4 shrink-0" />
        ) : note ? (
          <MessageSquare className="text-muted-foreground size-4 shrink-0" />
        ) : null}
        <Badge variant={pitScouted ? "secondary" : "outline"} className="shrink-0 text-[10px]">
          {pitScouted ? "Pit" : "No pit"}
        </Badge>`);

s = s.replace(`      ) : (
        <p className="text-muted-foreground mt-1 pl-1 text-[11px]">
          No match data — unscouted is not the same as bad.
        </p>
      )}`,
`      ) : (
        <p className="text-muted-foreground mt-1 pl-1 text-[11px]">
          No match data — unscouted is not the same as bad.
        </p>
      )}
      {note ? (
        <p className="mt-1 line-clamp-2 pl-1 text-[11px] italic">{note}</p>
      ) : null}`);

writeFileSync(p, s);
console.log("src/routes/picklists/team-chip.tsx patched");
MJS
bun /tmp/n4.mjs

say "Board: search and the note editor"
cat > /tmp/n5.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/picklists/board.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("PickNote")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { Button } from "@/components/ui/button";',
              'import { Button } from "@/components/ui/button";\nimport { Input } from "@/components/ui/input";\nimport { Textarea } from "@/components/ui/textarea";');
s = s.replace(`type Row = {
  entryId: string;
  teamId: string;
  teamNumber: number;
  nickname: string;
  tier: Tier;
  order: number;
};`,
`type Row = {
  entryId: string;
  teamId: string;
  teamNumber: number;
  nickname: string;
  tier: Tier;
  order: number;
  note: string;
};

function PickNote({ row, canEdit }: { row: Row; canEdit: boolean }) {
  const setNote = useMutation(api.entries.setNote);
  const [text, setText] = useState(row.note);
  const [saving, setSaving] = useState(false);
  const required = row.tier === "t1";
  const dirty = text !== row.note;

  return (
    <div className="space-y-2 border-t pt-4">
      <div className="flex items-baseline justify-between">
        <h3 className="font-medium">Pick notes</h3>
        {required ? (
          <span className="text-destructive text-xs">
            Required for first picks
          </span>
        ) : null}
      </div>
      <p className="text-muted-foreground text-xs">
        Why this team sits where it does. Whoever reads the list during alliance
        selection was not in your head when you ranked it.
      </p>
      <Textarea rows={3} value={text} disabled={!canEdit}
        placeholder="Pick notes"
        onChange={(e) => setText(e.target.value)} />
      {canEdit ? (
        <Button size="sm" disabled={!dirty || saving}
          onClick={() => {
            setSaving(true);
            void setNote({ entryId: row.entryId as Id<"pickListEntries">, note: text })
              .then(() => toast.success("Note saved"))
              .catch((error: unknown) =>
                toast.error("Could not save", {
                  description: error instanceof Error ? error.message : String(error),
                }))
              .finally(() => setSaving(false));
          }}>
          {dirty ? "Save note" : "Saved"}
        </Button>
      ) : null}
    </div>
  );
}`);

s = s.replace("  const [selectedTeam, setSelectedTeam] = useState<number | null>(null);",
`  const [selectedTeam, setSelectedTeam] = useState<number | null>(null);
  const [search, setSearch] = useState("");`);

// Filtering hides neighbours, and a midpoint computed against a filtered
// column would land the card in the wrong place. Freeze dragging instead.
s = s.replace(`      rows.sort((a, b) => a.order - b.order);`,
`      rows.sort((a, b) => a.order - b.order);`);

const oldMemoEnd = `    return map;
  }, [entries, sort, stats]);`;
if (!s.includes(oldMemoEnd)) fail("could not find the byTier memo end");
s = s.replace(oldMemoEnd, `    const needle = search.trim().toLowerCase();
    if (needle !== "") {
      for (const [tier, rows] of map) {
        map.set(tier, rows.filter((r) =>
          String(r.teamNumber).includes(needle) ||
          r.nickname.toLowerCase().includes(needle)));
      }
    }
    return map;
  }, [entries, sort, stats, search]);

  const searching = search.trim() !== "";
  const selectedRow = ((entries ?? []) as Row[]).find(
    (r) => r.teamNumber === selectedTeam,
  ) ?? null;`);

s = s.replace(`      <div className="flex flex-wrap items-center gap-2">
        <span className="text-muted-foreground text-xs">Sort Uncategorized</span>`,
`      <div className="flex flex-wrap items-center gap-2">
        <Input className="max-w-56" placeholder="Find a team"
          value={search} onChange={(e) => setSearch(e.target.value)} />
        {searching ? (
          <span className="text-muted-foreground text-xs">
            Dragging is off while searching — a card would land next to hidden
            neighbours.
          </span>
        ) : null}
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <span className="text-muted-foreground text-xs">Sort Uncategorized</span>`);

s = s.replace(`                      draggable={list.canEdit}`,
              `                      draggable={list.canEdit && !searching}
                      note={row.note}
                      needsNote={row.tier === "t1" && row.note.trim() === ""}`);

s = s.replace(`      <TeamDetail teamNumber={selectedTeam} onClose={() => setSelectedTeam(null)} />`,
`      <TeamDetail
        teamNumber={selectedTeam}
        onClose={() => setSelectedTeam(null)}
        footer={
          selectedRow ? (
            <PickNote key={selectedRow.entryId} row={selectedRow} canEdit={list.canEdit} />
          ) : null
        }
      />`);

writeFileSync(p, s);
console.log("src/routes/picklists/board.tsx patched");
MJS
bun /tmp/n5.mjs
rm -f /tmp/n1.mjs /tmp/n2.mjs /tmp/n3.mjs /tmp/n4.mjs /tmp/n5.mjs

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
