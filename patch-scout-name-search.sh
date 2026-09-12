#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-scout-name-search.sh
#   Search bar on the admin Scouts card — filter by name or team number.
#   Sits beside "Batch assign shifts", outside the canSetRoles gate, so team
#   admins get it too.
#
# No schema change, no new Convex functions. Filtering is client-side: a search
# term passed as a query arg would tear down and re-establish the live
# subscription on every keystroke, and this list is small enough that it never
# needs to.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/admin/roles-table.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Roles table: scout search"
cat > /tmp/s1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/roles-table.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
if (s.includes("scoutSearch")) { console.log("already patched"); process.exit(0); }

// Every anchor is checked before anything is written, so a miss leaves the
// file alone rather than half-edited.
const stateAnchor = `  const [batchOpen, setBatchOpen] = useState(false);`;
if (!s.includes(stateAnchor)) fail("could not find the batchOpen state");

const oldVisible = `  const visible = useMemo(
    () => (teamFilter === "all"
      ? sorted
      : sorted.filter((p) => p.teamNumber === teamFilter)),
    [sorted, teamFilter],
  );`;
if (!s.includes(oldVisible)) fail("could not find the visible memo");

const toolbar = `          <div className="flex gap-2">
            <Button variant="outline" onClick={() => setBatchOpen(true)}>
              Batch assign shifts
            </Button>
          </div>`;
if (!s.includes(toolbar)) fail("could not find the batch assign row");

const loading = `          {profiles === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : (
            visible.map((profile) => {`;
if (!s.includes(loading)) fail("could not find the row rendering");

// --- state ------------------------------------------------------------------
s = s.replace(stateAnchor, `${stateAnchor}
  const [scoutSearch, setScoutSearch] = useState("");`);

// --- filter: composes with the team filter rather than replacing it ---------
s = s.replace(oldVisible, `  const visible = useMemo(() => {
    const byTeam = teamFilter === "all"
      ? sorted
      : sorted.filter((p) => p.teamNumber === teamFilter);
    const needle = scoutSearch.trim().toLowerCase();
    if (needle === "") return byTeam;
    // Team number matches too — a full admin looking across several teams can
    // type either, and it costs nothing.
    return byTeam.filter((p) =>
      p.displayName.toLowerCase().includes(needle) ||
      String(p.teamNumber ?? "").includes(needle),
    );
  }, [sorted, teamFilter, scoutSearch]);`);

// --- the input, beside the batch button -------------------------------------
s = s.replace(toolbar, `          <div className="flex gap-2">
            <Button variant="outline" onClick={() => setBatchOpen(true)}>
              Batch assign shifts
            </Button>
            {/* Deliberately outside the canSetRoles gate below — a team admin
                looking for one of their own scouts needs this as much as a
                full admin does. */}
            <Input className="flex-1" placeholder="Search scouts"
              aria-label="Search scouts by name"
              value={scoutSearch}
              onChange={(e) => setScoutSearch(e.target.value)} />
          </div>`);

// --- empty state: a search with no matches should say so --------------------
s = s.replace(loading, `          {profiles === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : visible.length === 0 ? (
            <p className="text-muted-foreground text-sm">
              {scoutSearch.trim() === ""
                ? "No scouts here yet."
                : \`No scouts match “\${scoutSearch.trim()}”.\`}
            </p>
          ) : (
            visible.map((profile) => {`);

writeFileSync(p, s);
console.log("src/routes/admin/roles-table.tsx patched");
MJS
bun /tmp/s1.mjs
rm -f /tmp/s1.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
