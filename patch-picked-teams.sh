#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-picked-teams.sh
#   1. Search floats matching Uncategorized teams to the top instead of hiding
#      the rest; other tiers still filter.
#   2. Uncategorized stays draggable while searching.
#   3. Drops the "Tier 1 is highest" line.
#   4. A pick tick on the primary list, hiding picked teams everywhere. The
#      "Show picked" toggle appears on every list; only the primary carries the
#      tick that sets the state.
#
# SCHEMA CHANGE: pickedTeams table, scoped per scouting team so one team's
# picks never hide teams for another.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/picklists/board.tsx ]] || { echo "ERROR: run track-f.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema"
cat > /tmp/pk1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("pickedTeams")) { console.log("already patched"); process.exit(0); }
const anchor = "  pickLists: defineTable({";
if (!s.includes(anchor)) fail("could not find pickLists");
s = s.replace(anchor, `  /**
   * A team taken off the board during alliance selection. Scoped per scouting
   * team — 1002 marking a robot picked must not blank it for 254.
   */
  pickedTeams: defineTable({
    eventId: v.id("events"),
    scoutingTeamNumber: v.number(),
    teamId: v.id("teams"),
    pickedAt: v.number(),
    pickedBy: v.id("users"),
  })
    .index("by_event_team", ["eventId", "scoutingTeamNumber"])
    .index("by_event_target", ["eventId", "teamId"]),

${anchor}`);
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/pk1.mjs

say "Convex: picked teams"
cat > convex/picked.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import {
  activeEvent, currentProfile, currentTeamNumber, managesTeam, requireUser,
} from "./lib/guards";

/** Teams my scouting team has marked as taken. */
export const forEvent = query({
  args: {},
  handler: async (ctx) => {
    await requireUser(ctx);
    const event = await activeEvent(ctx);
    const teamNumber = await currentTeamNumber(ctx);
    if (!event || teamNumber === undefined) return [];

    const rows = await ctx.db
      .query("pickedTeams")
      .withIndex("by_event_team", (q) =>
        q.eq("eventId", event._id).eq("scoutingTeamNumber", teamNumber))
      .collect();
    return rows.map((r) => r.teamId as string);
  },
});

/**
 * Same permission as editing the primary list: this is a statement about what
 * the team has done in the draft, not a personal note.
 */
export const toggle = mutation({
  args: { teamId: v.id("teams") },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const teamNumber = profile?.teamNumber;
    if (teamNumber === undefined || !managesTeam(profile, teamNumber)) {
      throw new Error("Only your team's admin can mark a team picked.");
    }

    const existing = (
      await ctx.db
        .query("pickedTeams")
        .withIndex("by_event_team", (q) =>
          q.eq("eventId", event._id).eq("scoutingTeamNumber", teamNumber))
        .collect()
    ).find((r) => r.teamId === args.teamId);

    if (existing) {
      await ctx.db.delete(existing._id);
      return { picked: false };
    }
    await ctx.db.insert("pickedTeams", {
      eventId: event._id,
      scoutingTeamNumber: teamNumber,
      teamId: args.teamId,
      pickedAt: Date.now(),
      pickedBy: userId,
    });
    return { picked: true };
  },
});
EOF
echo "convex/picked.ts written"

say "Chip: pick tick"
cat > /tmp/pk2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/picklists/team-chip.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("onTogglePicked")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { GripVertical, MessageSquare, MessageSquareWarning } from "lucide-react";',
  'import {\n  Check, GripVertical, MessageSquare, MessageSquareWarning,\n} from "lucide-react";');
s = s.replace('import { Badge } from "@/components/ui/badge";',
  'import { Badge } from "@/components/ui/badge";\nimport { Button } from "@/components/ui/button";');

s = s.replace(`  note: string;
  needsNote: boolean;
  onOpen: () => void;
}) {`, `  note: string;
  needsNote: boolean;
  picked?: boolean;
  onTogglePicked?: () => void;
  onOpen: () => void;
}) {`);
s = s.replace(`  note,
  needsNote,
  onOpen,
}: {`, `  note,
  needsNote,
  picked = false,
  onTogglePicked,
  onOpen,
}: {`);

const badgeAnchor = `        <Badge variant={pitScouted ? "secondary" : "outline"} className="shrink-0 text-[10px]">`;
if (!s.includes(badgeAnchor)) fail("could not find the pit badge");
s = s.replace(badgeAnchor, `        {onTogglePicked ? (
          <Button size="icon" variant={picked ? "secondary" : "ghost"}
            className="size-6 shrink-0"
            aria-label={picked ? \`Unmark \${teamNumber} as picked\` : \`Mark \${teamNumber} as picked\`}
            onClick={(e) => { e.stopPropagation(); onTogglePicked(); }}>
            <Check className="size-3.5" />
          </Button>
        ) : null}
${badgeAnchor}`);

writeFileSync(p, s);
console.log("src/routes/picklists/team-chip.tsx patched");
MJS
bun /tmp/pk2.mjs

say "Board"
cat > /tmp/pk3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/picklists/board.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("showPicked")) { console.log("already patched"); process.exit(0); }

s = s.replace("  const move = useMutation(api.entries.move);",
`  const move = useMutation(api.entries.move);
  const picked = useQuery(api.picked.forEvent);
  const togglePicked = useMutation(api.picked.toggle);`);

s = s.replace("  const [search, setSearch] = useState(\"\");",
`  const [search, setSearch] = useState("");
  const [showPicked, setShowPicked] = useState(false);`);

// hide picked, float search matches in uncategorized, filter elsewhere
const oldFilter = `    const needle = search.trim().toLowerCase();
    if (needle !== "") {
      for (const [tier, rows] of map) {
        map.set(tier, rows.filter((r) =>
          String(r.teamNumber).includes(needle) ||
          r.nickname.toLowerCase().includes(needle)));
      }
    }
    return map;`;
if (!s.includes(oldFilter)) fail("could not find the search filter");
s = s.replace(oldFilter, `    const pickedSet = new Set(picked ?? []);
    if (!showPicked) {
      for (const [tier, rows] of map) {
        map.set(tier, rows.filter((r) => !pickedSet.has(r.teamId)));
      }
    }

    const needle = search.trim().toLowerCase();
    if (needle !== "") {
      const hit = (r: Row) =>
        String(r.teamNumber).includes(needle) ||
        r.nickname.toLowerCase().includes(needle);

      for (const [tier, rows] of map) {
        if (tier === "uncategorized") {
          // Float matches to the top rather than hiding the rest: every card
          // stays present, so a drop still lands between real neighbours.
          map.set(tier, [...rows].sort((a, b) => Number(hit(b)) - Number(hit(a))));
        } else {
          map.set(tier, rows.filter(hit));
        }
      }
    }
    return map;`);
s = s.replace("  }, [entries, sort, stats, search]);",
              "  }, [entries, sort, stats, search, picked, showPicked]);");

s = s.replace(`          {searching ? (
            <span className="text-muted-foreground text-xs">
              Dragging is off while searching — a card would land next to hidden
              neighbours.
            </span>
          ) : null}`,
`          {searching ? (
            <span className="text-muted-foreground text-xs">
              Matches float to the top of Uncategorized. Ranked tiers are
              filtered, so dragging is off there.
            </span>
          ) : null}`);

// the toggle, under the sort row, primary list only
const sortRowEnd = `        {sort ? (
          <span className="text-muted-foreground text-xs">
            View only — stored order is untouched.
          </span>
        ) : null}
      </div>`;
if (!s.includes(sortRowEnd)) fail("could not find the sort row");
s = s.replace(sortRowEnd, `${sortRowEnd}

      {/* Everyone can hide or reveal picked teams on the list they are looking
          at. Only the primary list carries the tick that SETS them, since that
          records what the team actually did in the draft. */}
      <div className="flex flex-wrap items-center gap-2">
        <Button size="sm" variant={showPicked ? "secondary" : "outline"}
          onClick={() => setShowPicked(!showPicked)}>
          Show picked {showPicked ? "✓" : ""}
        </Button>
        <span className="text-muted-foreground text-xs">
          {(picked ?? []).length} taken
          {list.isPrimary && list.canEdit
            ? " · tick a team to mark it picked"
            : " · marked on the team primary list"}
        </span>
      </div>`);

// uncategorized stays draggable while searching
s = s.replace("                      draggable={list.canEdit && !searching}",
`                      draggable={
                        list.canEdit && (!searching || row.tier === "uncategorized")
                      }`);

// pick tick on the primary list only
s = s.replace(`                      note={row.note}`,
`                      picked={(picked ?? []).includes(row.teamId)}
                      onTogglePicked={
                        list.isPrimary && list.canEdit
                          ? () => {
                              void togglePicked({ teamId: row.teamId as Id<"teams"> })
                                .catch((error: unknown) =>
                                  toast.error("Could not update", {
                                    description:
                                      error instanceof Error ? error.message : String(error),
                                  }));
                            }
                          : undefined
                      }
                      note={row.note}`);

// drop the instruction line
s = s.replace('      description="Tier 1 is highest. Drag by the grip to move a team between tiers."\n', "");

writeFileSync(p, s);
console.log("src/routes/picklists/board.tsx patched");
MJS
bun /tmp/pk3.mjs
rm -f /tmp/pk1.mjs /tmp/pk2.mjs /tmp/pk3.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
