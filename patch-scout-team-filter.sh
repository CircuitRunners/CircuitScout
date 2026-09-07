#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-scout-team-filter.sh — searchable team filter on the Scouts list.
# Full admins only; a team admin's list is already scoped to one team.
#
# Built as a plain input plus a toggled panel rather than a combobox
# primitive — one less Base UI API to be wrong about on a screen used rarely.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/admin/roles-table.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

cat > /tmp/f.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/roles-table.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("teamFilter")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { TriangleAlert, UserMinus, X } from "lucide-react";',
              'import { ChevronDown, TriangleAlert, UserMinus, X } from "lucide-react";');
s = s.replace('import { Button } from "@/components/ui/button";',
              'import { Button } from "@/components/ui/button";\nimport { Input } from "@/components/ui/input";');

s = s.replace("  const [busy, setBusy] = useState(false);",
`  const [busy, setBusy] = useState(false);

  const [teamFilter, setTeamFilter] = useState<number | "all">("all");
  const [pickerOpen, setPickerOpen] = useState(false);
  const [teamSearch, setTeamSearch] = useState("");`);

// team list with counts, derived from the scouts themselves
s = s.replace("  const pendingCount = sorted.filter((p) => p.pendingJoin).length;",
`  // Teams come from the scouts present, not from TBA — the filter should only
  // offer options that would actually show something.
  const teamCounts = useMemo(() => {
    const counts = new Map<number, number>();
    for (const profile of profiles ?? []) {
      if (profile.teamNumber === undefined) continue;
      counts.set(profile.teamNumber, (counts.get(profile.teamNumber) ?? 0) + 1);
    }
    return [...counts.entries()].sort((a, b) => a[0] - b[0]);
  }, [profiles]);

  const visible = useMemo(
    () => (teamFilter === "all"
      ? sorted
      : sorted.filter((p) => p.teamNumber === teamFilter)),
    [sorted, teamFilter],
  );

  const noTeamCount = (profiles ?? []).filter((p) => p.teamNumber === undefined).length;
  const pendingCount = sorted.filter((p) => p.pendingJoin).length;`);

// render the picker at the top of the card body
const anchor = `        <CardContent className="space-y-2">
          {(departures ?? []).map((row) => (`;
if (!s.includes(anchor)) fail("could not find the scouts card body");
s = s.replace(anchor, `        <CardContent className="space-y-2">
          {canSetRoles && teamCounts.length > 0 ? (
            <div className="space-y-2">
              <Button variant="outline" className="w-full justify-between"
                onClick={() => setPickerOpen(!pickerOpen)}>
                {teamFilter === "all" ? "All teams" : \`Team \${teamFilter}\`}
                <ChevronDown className={\`size-4 transition-transform \${pickerOpen ? "rotate-180" : ""}\`} />
              </Button>

              {pickerOpen ? (
                <div className="space-y-1 rounded-lg border p-2">
                  <Input autoFocus placeholder="Find a team number"
                    inputMode="numeric" value={teamSearch}
                    onChange={(e) => setTeamSearch(e.target.value)} />
                  <div className="max-h-56 space-y-1 overflow-y-auto">
                    <Button variant={teamFilter === "all" ? "default" : "ghost"}
                      className="w-full justify-between"
                      onClick={() => {
                        setTeamFilter("all");
                        setPickerOpen(false);
                        setTeamSearch("");
                      }}>
                      All
                      <span className="text-muted-foreground text-xs tabular-nums">
                        {(profiles ?? []).length}
                      </span>
                    </Button>
                    {teamCounts
                      .filter(([number]) =>
                        teamSearch.trim() === "" ||
                        String(number).includes(teamSearch.trim()))
                      .map(([number, count]) => (
                        <Button key={number}
                          variant={teamFilter === number ? "default" : "ghost"}
                          className="w-full justify-between"
                          onClick={() => {
                            setTeamFilter(number);
                            setPickerOpen(false);
                            setTeamSearch("");
                          }}>
                          {number}
                          <span className="text-muted-foreground text-xs tabular-nums">
                            {count}
                          </span>
                        </Button>
                      ))}
                  </div>
                  {noTeamCount > 0 ? (
                    <p className="text-muted-foreground px-2 pt-1 text-xs">
                      {noTeamCount} scout{noTeamCount === 1 ? "" : "s"} have no team
                      number and only appear under All.
                    </p>
                  ) : null}
                </div>
              ) : null}
            </div>
          ) : null}

          {(departures ?? []).map((row) => (`);

// the list now renders the filtered set
s = s.replace("            sorted.map((profile) => {", "            visible.map((profile) => {");

writeFileSync(p, s);
console.log("src/routes/admin/roles-table.tsx patched");
MJS
bun /tmp/f.mjs
rm -f /tmp/f.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
