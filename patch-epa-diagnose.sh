#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-epa-diagnose.sh
#   1. If rows come back but no EPA field is found, say so and show the actual
#      shape — storing zero and reporting success is the worst outcome.
#   2. Last-refresh time moves next to the button.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/statbotics.ts ]] || { echo "ERROR: run patch-statbotics.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Surface the real response shape"
cat > /tmp/d1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/statbotics.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("no EPA field")) { console.log("already patched"); process.exit(0); }

// Some hosts wrap the array in an object; treat both shapes as a list.
const oldList = "  const list = Array.isArray(body) ? body : [];";
if (!s.includes(oldList)) fail("could not find the list extraction");
s = s.replace(oldList, `  const list = Array.isArray(body)
    ? body
    : Array.isArray((body as { results?: unknown[] } | null)?.results)
      ? ((body as { results: unknown[] }).results)
      : Array.isArray((body as { data?: unknown[] } | null)?.data)
        ? ((body as { data: unknown[] }).data)
        : [];`);

const oldReturn = "  return { rows, sample: JSON.stringify(list[0]) };";
if (!s.includes(oldReturn)) fail("could not find the fetch return");
s = s.replace(oldReturn, `  // Rows arrived but nothing parsed: that is a field-path problem, not an
  // empty event, and the difference matters. Show the shape rather than
  // silently storing nothing and calling it a success.
  if (rows.length === 0) {
    throw new Error(
      \`Got \${list.length} rows from \${BASE} but found no EPA field. First row: \${JSON.stringify(list[0]).slice(0, 400)}\`,
    );
  }

  return { rows, sample: JSON.stringify(list[0]) };`);

writeFileSync(p, s);
console.log("convex/statbotics.ts patched");
MJS
bun /tmp/d1.mjs

say "Timestamp next to the button"
cat > /tmp/d2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/index.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("Never pulled yet")) { console.log("already patched"); process.exit(0); }

// out of the description…
s = s.replace(/\n\s*\{epa\?\.fetchedAt\n\s*\? `[^`]*`\n\s*: " Never pulled\."\}/, "");

const oldSpan = `          <span className="text-muted-foreground text-xs tabular-nums">
            {epa?.rows.length ?? 0} teams
          </span>`;
if (!s.includes(oldSpan)) fail("could not find the teams count");
s = s.replace(oldSpan, `          <span className="text-muted-foreground text-xs">
            {epa?.fetchedAt
              ? \`\${epa.rows.length} teams · pulled \${new Date(epa.fetchedAt).toLocaleString()}\`
              : "Never pulled yet"}
          </span>`);

writeFileSync(p, s);
console.log("src/routes/admin/index.tsx patched");
MJS
bun /tmp/d2.mjs
rm -f /tmp/d1.mjs /tmp/d2.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
