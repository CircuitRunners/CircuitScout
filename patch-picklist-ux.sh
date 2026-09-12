#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-picklist-ux.sh
#   1. Drops the "dragging is off while searching" hint.
#   2. Columns scroll on their own instead of the whole page.
#   3. The primary list fills itself — no "Add all teams" button.
#
# No schema change.
#
# Every file is read and fully checked before anything is written, so a missed
# anchor leaves that file untouched rather than half-edited. Each step reports
# what it did.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/picklists/board.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Board: hint removal and column scrolling"
cat > /tmp/ux1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/picklists/board.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`  ABORT (${p} untouched): ${m}`); process.exit(1); };

if (s.includes("overscroll-contain")) { console.log("  already patched"); process.exit(0); }

// --- check everything first -------------------------------------------------
const oldCol = `      className={[
        "min-h-32 min-w-64 flex-1 space-y-2 rounded-lg border p-2 transition-colors",`;
if (!s.includes(oldCol)) fail("could not find the column className");

const oldHeader = `      <div className="flex items-center justify-between px-1">
        <span className="text-sm font-medium">{TIER_LABELS[tier]}</span>
        <span className="text-muted-foreground text-xs tabular-nums">{rows.length}</span>
      </div>
      {children}`;
if (!s.includes(oldHeader)) fail("could not find the column header");

// --- 1. the hint, in either wording it shipped as ---------------------------
const hints = [
  /\n\s*\{searching \? \(\n\s*<span className="text-muted-foreground text-xs">\n\s*Matches float to the top of Uncategorized\. Ranked tiers are\n\s*filtered, so dragging is off there\.\n\s*<\/span>\n\s*\) : null\}/,
  /\n\s*\{searching \? \(\n\s*<span className="text-muted-foreground text-xs">[\s\S]{0,400}?dragging is off[\s\S]{0,200}?<\/span>\n\s*\) : null\}/,
];
let removed = false;
for (const re of hints) {
  if (re.test(s)) { s = s.replace(re, ""); removed = true; break; }
}
console.log(removed ? "  hint removed" : "  (hint not found — already gone?)");

// --- 2. each column scrolls itself ------------------------------------------
// A finger inside a column moves that column. overscroll-contain stops the
// page from taking over once the column hits its end.
s = s.replace(oldCol, `      className={[
        "flex max-h-[70vh] min-h-32 min-w-64 flex-1 flex-col gap-2 rounded-lg border p-2 transition-colors",`);

s = s.replace(oldHeader, `      <div className="flex shrink-0 items-center justify-between px-1">
        <span className="text-sm font-medium">{TIER_LABELS[tier]}</span>
        <span className="text-muted-foreground text-xs tabular-nums">{rows.length}</span>
      </div>
      {/* The cards scroll, the heading stays put — a column you cannot see the
          name of is hard to drop into with any confidence. */}
      <div className="min-h-0 flex-1 space-y-2 overflow-y-auto overscroll-contain">
        {children}
      </div>`);

writeFileSync(p, s);
console.log("  src/routes/picklists/board.tsx patched");
MJS
bun /tmp/ux1.mjs

say "Primary list fills itself"
cat > /tmp/ux2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";

// ---------------------------------------------------------------------------
// convex/pickLists.ts — seedPrimaryEntries, called on create AND on open
// ---------------------------------------------------------------------------
{
  const p = "convex/pickLists.ts";
  let s = readFileSync(p, "utf8");
  const fail = (m) => { console.error(`  ABORT (${p} untouched): ${m}`); process.exit(1); };

  if (s.includes("seedPrimaryEntries")) {
    console.log("  convex/pickLists.ts already patched");
  } else {
    const insertAnchor = `    return await ctx.db.insert("pickLists", {
      eventId: event._id,
      ownerId: null,
      teamNumber: me.teamNumber,`;
    if (!s.includes(insertAnchor)) fail("could not find the ensurePrimary insert");

    const closeAnchor = `      isPrimary: true,
      isSubmitted: false,
      createdAt: Date.now(),
    });
  },
});`;
    if (!s.includes(closeAnchor)) fail("could not find the ensurePrimary close");

    // types the helper needs
    const head = [];
    if (!s.includes("MutationCtx")) head.push(`import type { MutationCtx } from "./_generated/server";`);
    if (!s.includes(`from "./_generated/dataModel"`)) head.push(`import type { Id } from "./_generated/dataModel";`);
    if (head.length > 0) {
      const directive = /^(\s*["']use node["'];?\s*\n)/.exec(s);
      const at = directive ? directive[0].length : 0;
      s = s.slice(0, at) + head.join("\n") + "\n" + s.slice(at);
    }

    s = s.replace(insertAnchor, `    const listId = await ctx.db.insert("pickLists", {
      eventId: event._id,
      ownerId: null,
      teamNumber: me.teamNumber,`);

    s = s.replace(closeAnchor, `      isPrimary: true,
      isSubmitted: false,
      createdAt: Date.now(),
    });

    await seedPrimaryEntries(ctx, event._id, listId);
    return listId;
  },
});

/**
 * Puts every team on a primary list that is missing them. The primary list has
 * no owner to notice a gap, so it keeps itself in step rather than waiting for
 * an admin to press a button they may not know exists.
 *
 * Idempotent — teams already on the list are skipped, and ordering of existing
 * entries is never disturbed. Safe to call on every open.
 */
export async function seedPrimaryEntries(
  ctx: MutationCtx,
  eventId: Id<"events">,
  listId: Id<"pickLists">,
) {
  const existing = await ctx.db
    .query("pickListEntries")
    .withIndex("by_list", (q) => q.eq("pickListId", listId))
    .collect();
  const have = new Set(existing.map((e) => e.teamId));
  let order = existing.reduce((max, e) => Math.max(max, e.order), 0);

  const teams = await ctx.db
    .query("teams")
    .withIndex("by_event", (q) => q.eq("eventId", eventId))
    .collect();
  teams.sort((a, b) => a.number - b.number);

  for (const team of teams) {
    if (have.has(team._id)) continue;
    order += 1000;
    await ctx.db.insert("pickListEntries", {
      pickListId: listId,
      teamId: team._id,
      tier: "uncategorized",
      order,
    });
  }
}`);

    // A primary list created BEFORE this patch is already empty and would never
    // fill, since the seed above only runs on creation. Top up on open too.
    const existingReturns = [
      { from: `    if (existing) return existing._id;`,
        to:   `    if (existing) {\n      await seedPrimaryEntries(ctx, event._id, existing._id);\n      return existing._id;\n    }` },
      { from: `    if (existing !== null) return existing._id;`,
        to:   `    if (existing !== null) {\n      await seedPrimaryEntries(ctx, event._id, existing._id);\n      return existing._id;\n    }` },
      { from: `    if (existing) {\n      return existing._id;\n    }`,
        to:   `    if (existing) {\n      await seedPrimaryEntries(ctx, event._id, existing._id);\n      return existing._id;\n    }` },
    ];
    let topped = false;
    for (const { from, to } of existingReturns) {
      if (s.includes(from)) { s = s.replace(from, to); topped = true; break; }
    }
    console.log(topped
      ? "  existing primary lists top up on open"
      : "  NOTE: could not find the existing-list return in ensurePrimary —\n" +
        "        new primary lists seed fine, but one created before this patch\n" +
        "        will only fill on the next TBA re-import. Paste ensurePrimary\n" +
        "        and this becomes a two-line fix.");

    writeFileSync(p, s);
    console.log("  convex/pickLists.ts patched");
  }
}

// ---------------------------------------------------------------------------
// convex/events.ts — a re-import tops up every primary list for that event
// ---------------------------------------------------------------------------
{
  const p = "convex/events.ts";
  let e = readFileSync(p, "utf8");
  const fail = (m) => { console.error(`  ABORT (${p} untouched): ${m}`); process.exit(1); };

  if (e.includes("seedPrimaryEntries")) {
    console.log("  convex/events.ts already patched");
  } else {
    const anchor = `    return {
      eventId,
      name: args.name,
      teamsAdded, teamsUpdated, teamsRemoved, teamsKept,`;
    if (!e.includes(anchor)) fail("could not find the applyImport return");

    const guardImport = /(import \{[^}]*\} from "\.\/lib\/guards";)/;
    if (!guardImport.test(e)) fail("could not find the guards import to anchor to");
    e = e.replace(guardImport, `$1\nimport { seedPrimaryEntries } from "./pickLists";`);

    e = e.replace(anchor, `    // Teams added by a re-import should appear on the primary list without
    // anyone remembering to top it up.
    const primaries = (
      await ctx.db
        .query("pickLists")
        .withIndex("by_event", (q) => q.eq("eventId", eventId))
        .collect()
    ).filter((l) => l.ownerId === null);
    for (const list of primaries) {
      await seedPrimaryEntries(ctx, eventId, list._id);
    }

${anchor}`);

    writeFileSync(p, e);
    console.log("  convex/events.ts patched");
  }
}

// ---------------------------------------------------------------------------
// src/routes/picklists/index.tsx — drop the button
// ---------------------------------------------------------------------------
{
  const p = "src/routes/picklists/index.tsx";
  let ui = readFileSync(p, "utf8");
  if (!ui.includes("populatePrimary")) {
    console.log("  (no Add all teams button found — already gone?)");
  } else {
    const before = ui;
    ui = ui.replace(/\n\s*\{isAnyAdmin && primary\.total === 0 \? \([\s\S]*?\) : null\}/, "");
    ui = ui.replace("  const populatePrimary = useMutation(api.pickLists.populatePrimary);\n", "");
    if (ui === before) {
      console.error("  WARNING: populatePrimary is referenced but neither the button block");
      console.error("           nor the hook line matched. src/routes/picklists/index.tsx");
      console.error("           left alone — remove the button by hand.");
    } else if (ui.includes("populatePrimary")) {
      console.error("  WARNING: a populatePrimary reference remains — check the file.");
      writeFileSync(p, ui);
      console.log("  src/routes/picklists/index.tsx partially patched");
    } else {
      writeFileSync(p, ui);
      console.log("  src/routes/picklists/index.tsx patched");
    }
  }
}
MJS
bun /tmp/ux2.mjs
rm -f /tmp/ux1.mjs /tmp/ux2.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  The `populatePrimary` mutation in convex/pickLists.ts is now unused. It is
  left in place deliberately — deleting it is a one-line change you can make
  once you have confirmed the automatic seeding works at a real event.

DONE
