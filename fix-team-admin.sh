#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fix-team-admin.sh — repairs four defects in patch-team-admin.sh.
#
#   1. A greedy regex replaced ALL of pickLists.ts's imports, not just the
#      guards one. Restores the missing imports.
#   2. deletionLog already had a `teamNumber` — the SCOUTED team. Adding
#      another for the owning team collided. Renamed to ownerTeamNumber.
#   3. `requireAdmin` left imported but unused in admin.ts.
#   4. `isAnyAdmin` in the pick lists page referenced itself.
#
# Safe to run once. Each step checks before acting and says what it did.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/pickLists.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "1. pickLists.ts imports"
cat > /tmp/r1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/pickLists.ts";
let s = readFileSync(p, "utf8");
if (s.includes('from "convex/values"')) { console.log("imports look intact"); process.exit(0); }
s = `import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import type { MutationCtx } from "./_generated/server";
import type { Doc, Id } from "./_generated/dataModel";
` + s;
writeFileSync(p, s);
console.log("restored the imports a greedy regex removed");
MJS
bun /tmp/r1.mjs

say "2. deletionLog key collision"
cat > /tmp/r2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";

// schema: drop the duplicate, add a distinctly named one.
let s = readFileSync("convex/schema.ts", "utf8");
const dup = "    reason: v.string(),\n    snapshot: v.string(),\n    teamNumber: v.optional(v.number()),";
if (s.includes(dup)) {
  s = s.replace(dup,
    "    reason: v.string(),\n    snapshot: v.string(),\n    // The team whose admin deleted it — distinct from teamNumber above,\n    // which is the team the report was ABOUT.\n    ownerTeamNumber: v.optional(v.number()),");
  writeFileSync("convex/schema.ts", s);
  console.log("convex/schema.ts: deletionLog.ownerTeamNumber");
} else {
  console.log("convex/schema.ts: nothing to change");
}

// admin.ts: same rename at the two insert sites and the filter.
let a = readFileSync("convex/admin.ts", "utf8");
const before = a;
a = a.split("      teamNumber: admin.teamNumber,").join("      ownerTeamNumber: admin.teamNumber,");
a = a.split("managesTeam(me, r.teamNumber)").join("managesTeam(me, r.ownerTeamNumber)");
if (a !== before) { writeFileSync("convex/admin.ts", a); console.log("convex/admin.ts: renamed"); }
else console.log("convex/admin.ts: nothing to rename");
MJS
bun /tmp/r2.mjs

say "3. admin.ts unused bindings"
cat > /tmp/r3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/admin.ts";
let s = readFileSync(p, "utf8");

// Drop `const me = ` where the handler never uses it again.
const blocks = s.split(/(?=export const )/);
const fixed = blocks.map((block) => {
  if (!block.includes("const me = await requireTeamAdmin(ctx);")) return block;
  const after = block.split("const me = await requireTeamAdmin(ctx);")[1] ?? "";
  const used = /\bme\b/.test(after);
  return used
    ? block
    : block.replace("const me = await requireTeamAdmin(ctx);", "await requireTeamAdmin(ctx);");
});
s = fixed.join("");

if (!/\brequireAdmin\b(?!\w)/.test(s.split("\n").filter((l) => !l.startsWith("import")).join("\n"))) {
  s = s.replace("  activeEvent, managesTeam, requireAdmin, requireTeamAdmin, requireUser,\n",
                "  activeEvent, managesTeam, requireTeamAdmin, requireUser,\n");
  console.log("dropped the unused requireAdmin import");
}
writeFileSync(p, s);
console.log("convex/admin.ts: unused bindings cleared");
MJS
bun /tmp/r3.mjs

say "4. isAnyAdmin self-reference"
cat > /tmp/r4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/picklists/index.tsx";
let s = readFileSync(p, "utf8");
const bad = /const isAnyAdmin = isAnyAdmin \|\| profile\?\.role === "teamAdmin";/;
if (!bad.test(s)) { console.log("nothing to fix"); process.exit(0); }
s = s.replace(bad,
  'const isAnyAdmin =\n    profile?.role === "admin" || profile?.role === "teamAdmin";');
writeFileSync(p, s);
console.log("src/routes/picklists/index.tsx: isAnyAdmin fixed");
MJS
bun /tmp/r4.mjs
rm -f /tmp/r1.mjs /tmp/r2.mjs /tmp/r3.mjs /tmp/r4.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
