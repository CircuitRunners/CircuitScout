#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-team-admin-events-ui.sh — team admins can see and use the event cards.
#
# They could already import and activate events server-side; the UI was still
# gated on full admin, so the buttons were invisible. "Configuring for" now
# shows every team to a full admin and only their own to a team admin.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/admin/index.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

cat > /tmp/tae.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/index.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("Your team's event")) { console.log("already patched"); process.exit(0); }

// 1. unwrap the import + events cards
const openTag = "      {isFullAdmin ? (\n        <>\n";
const closeTag = "        </>\n      ) : null}\n";
const start = s.indexOf(openTag);
const end = start === -1 ? -1 : s.indexOf(closeTag, start);
if (start === -1 || end === -1) {
  console.log("  (no full-admin wrapper on the event cards — already visible)");
} else {
  const inner = s.slice(start + openTag.length, end);
  s = s.slice(0, start) + inner + s.slice(end + closeTag.length);
  console.log("  unwrapped the import and events cards");
}

// 2. show "Configuring for" to any admin
const cfg = `      {isFullAdmin ? (
        <Card>
          <CardHeader>
            <CardTitle>Configuring for</CardTitle>`;
if (!s.includes(cfg)) fail("could not find the Configuring for card");
s = s.replace(cfg, `      {me ? (
        <Card>
          <CardHeader>
            <CardTitle>{isFullAdmin ? "Configuring for" : "Your team's event"}</CardTitle>`);

s = s.replace(`            <CardDescription>
              Which team the activation buttons above apply to.
            </CardDescription>`,
`            <CardDescription>
              {isFullAdmin
                ? "Which team the activation buttons above apply to."
                : "Activations above apply to your team. Events themselves are shared — importing one makes it available to everyone."}
            </CardDescription>`);

// 3. a team admin sees one team, and it is not a choice
const oldButtons = `            {(settings ?? []).map((row) => (
              <Button key={row.teamNumber} size="sm"
                variant={targetTeam === row.teamNumber ? "default" : "outline"}
                onClick={() => setTeamFor(row.teamNumber)}>
                {row.teamNumber}
                <span className="text-muted-foreground ml-1 text-xs">
                  {row.eventKey ?? "none"}
                </span>
              </Button>
            ))}`;
if (!s.includes(oldButtons)) fail("could not find the team buttons");
s = s.replace(oldButtons, `            {(settings ?? []).map((row) => (
              <Button key={row.teamNumber} size="sm"
                variant={targetTeam === row.teamNumber ? "default" : "outline"}
                // A team admin has exactly one option, so the button reports
                // rather than selects.
                disabled={!isFullAdmin}
                onClick={() => setTeamFor(row.teamNumber)}>
                {row.teamNumber}
                <span className="text-muted-foreground ml-1 text-xs">
                  {row.eventKey ?? "none"}
                </span>
              </Button>
            ))}`);

writeFileSync(p, s);
console.log("src/routes/admin/index.tsx patched");
MJS
bun /tmp/tae.mjs
rm -f /tmp/tae.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
