#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-scout-search.sh
#   Search bar on /scout — filter by team number or match number.
#   Also puts the previously-unused Button import to work.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/scout/index.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Scout landing: search"
cat > /tmp/s1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/scout/index.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("matchSearch")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { ChevronRight } from "lucide-react";',
              'import { ChevronRight, X } from "lucide-react";');
s = s.replace('import { useState } from "react";',
              'import { useMemo, useState } from "react";');
s = s.replace('import { Badge } from "@/components/ui/badge";',
              'import { Badge } from "@/components/ui/badge";\nimport { Input } from "@/components/ui/input";');

// Highlight the searched team inside an expanded match.
s = s.replace('function MatchRobots({ matchNumber }: { matchNumber: number }) {',
`function MatchRobots({
  matchNumber,
  highlight,
}: {
  matchNumber: number;
  highlight: number | null;
}) {`);

const oldBtnClass = `                className="hover:bg-accent/50 flex min-h-14 w-full items-center gap-2 rounded-md border p-3 text-left transition-colors"`;
if (!s.includes(oldBtnClass)) fail("could not find the robot button class");
s = s.replace(oldBtnClass, `                className={[
                  "flex min-h-14 w-full items-center gap-2 rounded-md border p-3 text-left transition-colors",
                  team.number === highlight
                    ? "border-primary bg-primary/10"
                    : "hover:bg-accent/50",
                ].join(" ")}`);

// Filter the match list.
const oldState = `  const [open, setOpen] = useState<number | null>(null);`;
if (!s.includes(oldState)) fail("could not find the open state");
s = s.replace(oldState, `  const [open, setOpen] = useState<number | null>(null);
  const [matchSearch, setMatchSearch] = useState("");

  // One box for both, because a scout looking for "their" match knows either
  // the match number or their assigned team — and often only one of them.
  const searchNumber = Number.parseInt(matchSearch.trim(), 10);
  const shown = useMemo(() => {
    if (!matches) return [];
    const needle = matchSearch.trim();
    if (needle === "") return matches;
    return matches.filter(
      (m) =>
        String(m.matchNumber) === needle ||
        (!Number.isNaN(searchNumber) &&
          (m.redTeamNumbers.includes(searchNumber) ||
            m.blueTeamNumbers.includes(searchNumber))),
    );
  }, [matches, matchSearch, searchNumber]);

  // A single hit is unambiguous, so open it rather than making them tap again.
  const onlyHit = shown.length === 1 ? (shown[0]?.matchNumber ?? null) : null;
  const expanded = onlyHit ?? open;
  const highlight =
    !Number.isNaN(searchNumber) &&
    matches?.some((m) =>
      m.redTeamNumbers.includes(searchNumber) ||
      m.blueTeamNumbers.includes(searchNumber))
      ? searchNumber
      : null;`);

// Search input in the card header area.
const oldDesc = `        <CardContent className="space-y-1">
          {(matches ?? []).map((match) => (`;
if (!s.includes(oldDesc)) fail("could not find the match list");
s = s.replace(oldDesc, `        <CardContent className="space-y-3">
          <div className="flex gap-2">
            <Input
              placeholder="Match number or team number"
              inputMode="numeric"
              value={matchSearch}
              onChange={(e) => setMatchSearch(e.target.value)}
            />
            {matchSearch !== "" ? (
              <Button variant="ghost" size="icon" aria-label="Clear search"
                onClick={() => setMatchSearch("")}>
                <X className="size-4" />
              </Button>
            ) : null}
          </div>

          {matchSearch.trim() !== "" ? (
            <p className="text-muted-foreground text-xs">
              {shown.length === 0
                ? "No match with that number, and no team with that number is playing."
                : \`\${shown.length} match\${shown.length === 1 ? "" : "es"} — a number can mean either a match or a team, so both are searched.\`}
            </p>
          ) : null}

          {shown.map((match) => (`);

s = s.replace(`                onClick={() =>
                  setOpen(open === match.matchNumber ? null : match.matchNumber)
                }`,
`                onClick={() =>
                  setOpen(expanded === match.matchNumber ? null : match.matchNumber)
                }`);

s = s.replace(`                <ChevronRight
                  className={\`size-4 shrink-0 transition-transform \${
                    open === match.matchNumber ? "rotate-90" : ""
                  }\`}
                />`,
`                <ChevronRight
                  className={\`size-4 shrink-0 transition-transform \${
                    expanded === match.matchNumber ? "rotate-90" : ""
                  }\`}
                />`);

s = s.replace(`              {open === match.matchNumber ? (
                <MatchRobots matchNumber={match.matchNumber} />
              ) : null}`,
`              {expanded === match.matchNumber ? (
                <MatchRobots matchNumber={match.matchNumber} highlight={highlight} />
              ) : null}`);

s = s.replace('      description="Pick a match, then pick a robot. The badge shows how many reports that robot already has."',
              '      description="Search by match or team, then pick a robot. The badge shows how many reports that robot already has."');

writeFileSync(p, s);
console.log("src/routes/scout/index.tsx patched");
MJS
bun /tmp/s1.mjs
rm -f /tmp/s1.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
