#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-batch-for-team-admins.sh — "Batch assign shifts" is a team admin's job.
#
# It was nested in the full-admin block that also holds the team filter and
# Manage scouts, so team admins could not see it. Assigning shifts to their own
# scouts is exactly what a team admin is for; deleting accounts and filtering
# across teams are not.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/admin/roles-table.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

cat > /tmp/b.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/roles-table.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("Assigning shifts is a team")) { console.log("already patched"); process.exit(0); }

// Remove the existing trigger wherever it sits — indentation varies with
// which patches landed. If it was never added, inserting below fixes that too.
const existing = /\n\s*<Button variant="outline" onClick=\{\(\) => setBatchOpen\(true\)\}>\n\s*Batch assign shifts\n\s*<\/Button>/;
if (existing.test(s)) {
  s = s.replace(existing, "");
  console.log("  removed the gated trigger");
} else {
  console.log("  no existing trigger found — adding one");
}

// …and into a row of its own, above it, visible to any admin.
const blockAnchor = `          {canSetRoles && teamCounts.length > 0 ? (`;
if (!s.includes(blockAnchor)) fail("could not find the full-admin block");
s = s.replace(blockAnchor, `          {/* Assigning shifts is a team admin's job. Filtering across teams and
              deleting accounts are not, so those stay above. */}
          <div className="flex gap-2">
            <Button variant="outline" onClick={() => setBatchOpen(true)}>
              Batch assign shifts
            </Button>
          </div>

${blockAnchor}`);

writeFileSync(p, s);
console.log("src/routes/admin/roles-table.tsx patched");
MJS
bun /tmp/b.mjs
rm -f /tmp/b.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
