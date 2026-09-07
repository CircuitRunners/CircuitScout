#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-merge-link.sh — reach the merge from the primary list row on
# /picklists, where the thing it acts on actually lives. Admin only.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/picklists/index.tsx ]] || { echo "ERROR: run track-f.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

cat > /tmp/ml.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/picklists/index.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("/admin/merge")) { console.log("already linked"); process.exit(0); }

s = s.replace('import { Check, ListPlus, Lock, Trash2 } from "lucide-react";',
              'import { Check, GitMerge, ListPlus, Lock, Trash2 } from "lucide-react";');

const anchor = `              <Button size="sm" variant="outline"
                render={<Link to={\`/picklists/\${primary._id}\`} />}>
                Open
              </Button>`;
if (!s.includes(anchor)) fail("could not find the primary list Open button");
s = s.replace(anchor, `${anchor}
              {profile?.role === "admin" ? (
                <Button size="sm" variant="secondary"
                  render={<Link to="/admin/merge" />}>
                  <GitMerge className="size-4" />
                  Merge
                </Button>
              ) : null}`);

s = s.replace(`            What the team acts on during alliance selection. Admin only, and it
            starts blank — the merge fills it from everyone's submitted lists.`,
`            What the team acts on during alliance selection. Admin only, and it
            starts blank — Merge fills it from everyone's submitted lists.`);

writeFileSync(p, s);
console.log("src/routes/picklists/index.tsx patched");
MJS
bun /tmp/ml.mjs
rm -f /tmp/ml.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
