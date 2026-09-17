#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-up-next.sh
#   "Up next" advances on scouting only, and never walks backwards.
#
#   1. TBA results no longer move it. The furthest match anyone has submitted
#      a report for is the only signal, read from this scout's own reports as
#      well as the pooled by_event query.
#   2. The reason it stuck: the selection had a fallback. With no assigned
#      match after the current one it returned "the first match you haven't
#      personally reported" — which walks BACKWARDS to qual 2 and looks like
#      nothing updated. Gone.
#   3. With the fallback gone the card would have vanished once a shift ran
#      out, so instead it stays and shows just the match the event has moved
#      on to: "Up next / Qual 38", no station badge, no team, no button.
#   4. "now" is dropped from the distance line. A match zero away needs no
#      word for it.
#
# No schema change. assignments.mine gains `assigned` on upNext, and its
# `station` is now Station | null.
#
# Each step guards itself, so this is safe to run over an earlier version of
# the same patch — applied steps report "already patched" and are skipped.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/assignments.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
runjs() { if command -v bun >/dev/null 2>&1; then bun "$1"; else node "$1"; fi; }

say "Assignments: current match, and what comes after it"
cat > /tmp/cs-up-next.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/assignments.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
const before = s;

// --- step 1: current comes from reports only --------------------------------
if (s.includes("furthest match anyone has reported")) {
  console.log("current-match block: already patched");
} else {
  // Two shapes, depending on whether patch-stats-and-next.sh has been run.
  const withTba = `    const reportedMatchIds = new Set(allReports.map((r) => r.matchId));
    let current = 0;
    for (const match of matches) {
      const played =
        (match.redScore ?? null) !== null
        || (match.blueScore ?? null) !== null
        || (match.actualTime ?? null) !== null
        || reportedMatchIds.has(match._id);
      if (played && match.matchNumber > current) current = match.matchNumber;
    }`;
  const original = `    let current = 0;
    for (const report of allReports) {
      const match = matches.find((m) => m._id === report.matchId);
      if (match && match.matchNumber > current) current = match.matchNumber;
    }`;
  const commentWithTba = `    // "Current" is the furthest match the app can see is over, from two
    // signals, whichever is further along:
    //   - a TBA result, which is authoritative but only as fresh as the last
    //     refresh, and arrives even for matches nobody scouted;
    //   - anyone's submitted report, which is immediate and pooled across
    //     scouts, so scout 1 finishing qual 12 moves everyone on to 13.
    // Distance stays in matches rather than minutes: scheduled times drift
    // during an event, so a countdown would be confidently wrong.`;
  const commentOriginal = `    // "Current" is the furthest match anyone has scouted. Distance is measured
    // in matches rather than minutes: scheduled times drift during an event
    // and only refresh on re-import, so a countdown would be confidently wrong.`;

  const block = s.includes(withTba) ? withTba : s.includes(original) ? original : null;
  if (block === null) fail("could not find the current-match block in mine()");
  const comment = s.includes(commentWithTba)
    ? commentWithTba
    : s.includes(commentOriginal) ? commentOriginal : null;
  if (comment === null) fail("could not find the comment above it");

  s = s.replace(comment, `    // "Current" is the furthest match anyone has reported. Pooled across
    // scouts — scout 1 finishing qual 12 moves everyone on to 13 — and taken
    // from this scout's own reports too, so your own submission always
    // advances your own card. TBA results deliberately do not count: a
    // refresh landing mid-shift would jump the card past matches still
    // waiting to be scouted. Distance stays in matches rather than minutes,
    // because scheduled times drift during an event.`);

  s = s.replace(block, `    const reportedMatchIds = new Set(
      [...allReports, ...myReports].map((r) => r.matchId),
    );
    let current = 0;
    for (const match of matches) {
      if (reportedMatchIds.has(match._id) && match.matchNumber > current) {
        current = match.matchNumber;
      }
    }`);
}

// --- step 2: selection, and the card that outlives the shift -----------------
if (s.includes("upcomingNumber")) {
  console.log("up-next selection: already patched");
} else {
  const selectionOriginal = `    const next = assigned.find(
      (a) => !reportedMatchNumbers.has(a.matchNumber) && a.matchNumber > current,
    ) ?? assigned.find((a) => !reportedMatchNumbers.has(a.matchNumber)) ?? null;`;
  const selectionNoFallback = `    const next = assigned.find(
      (a) => a.matchNumber > current && !reportedMatchNumbers.has(a.matchNumber),
    ) ?? null;`;
  const selection = s.includes(selectionOriginal)
    ? selectionOriginal
    : s.includes(selectionNoFallback) ? selectionNoFallback : null;
  if (selection === null) fail("could not find the up-next selection");

  const upNextBlock = `    const upNext = next
      ? {
          matchNumber: next.matchNumber,
          station: next.station,
          teamNumber: next.teamNumber,
          nickname: next.teamNumber
            ? (teamByNumber.get(next.teamNumber)?.nickname ?? null)
            : null,
          matchesAway: Math.max(0, next.matchNumber - current),
        }
      : null;`;
  if (!s.includes(upNextBlock)) fail("could not find the upNext object");

  // No fallback. An assigned match behind the current one is over; offering
  // it back is what made the card look frozen on qual 2.
  s = s.replace(selection, `    const next = assigned.find(
      (a) => a.matchNumber > current && !reportedMatchNumbers.has(a.matchNumber),
    ) ?? null;

    // Once a shift runs out the card stays, naming the match the event has
    // moved on to. A scout whose assignment is finished should see the
    // schedule advancing rather than an empty space where the card was.
    const upcomingNumber = matches
      .map((m) => m.matchNumber)
      .filter((n) => n > current)
      .sort((a, b) => a - b)[0] ?? null;`);

  s = s.replace(upNextBlock, `    const upNext: {
      matchNumber: number;
      /** Null when nothing is assigned: no badge, no robot, no button. */
      station: Station | null;
      teamNumber: number | null;
      nickname: string | null;
      matchesAway: number;
      assigned: boolean;
    } | null = next
      ? {
          matchNumber: next.matchNumber,
          station: next.station,
          teamNumber: next.teamNumber,
          nickname: next.teamNumber
            ? (teamByNumber.get(next.teamNumber)?.nickname ?? null)
            : null,
          matchesAway: Math.max(0, next.matchNumber - current),
          assigned: true,
        }
      : upcomingNumber === null
        ? null
        : {
            matchNumber: upcomingNumber,
            station: null,
            teamNumber: null,
            nickname: null,
            matchesAway: Math.max(0, upcomingNumber - current),
            assigned: false,
          };`);
}

if (s === before) { console.log("nothing to do"); process.exit(0); }
writeFileSync(p, s);
console.log("convex/assignments.ts patched");
MJS
runjs /tmp/cs-up-next.mjs
rm -f /tmp/cs-up-next.mjs

say "Dashboard: bare card, and no 'now'"
cat > /tmp/cs-dashboard.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/dashboard.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
if (s.includes("upNext.assigned")) { console.log("already patched"); process.exit(0); }

const badge = `              <span className={[
                "rounded-md px-2 py-1 text-xs font-medium text-white",
                assignments.upNext.station.startsWith("red") ? "bg-red-600" : "bg-blue-600",
              ].join(" ")}>
                {STATION_LABELS[assignments.upNext.station as Station]}
              </span>`;
if (!s.includes(badge)) fail("could not find the station badge");

const body = `            <p className="text-muted-foreground text-sm">
              {assignments.upNext.teamNumber === null ? (
                "That station has no team in the imported schedule."
              ) : (
                <>
                  Team{" "}
                  <span className="text-foreground font-medium tabular-nums">
                    {assignments.upNext.teamNumber}
                  </span>
                  {assignments.upNext.nickname ? \` · \${assignments.upNext.nickname}\` : ""}
                  {" · "}
                  {assignments.upNext.matchesAway === 0
                    ? "now"
                    : \`\${assignments.upNext.matchesAway} match\${assignments.upNext.matchesAway === 1 ? "" : "es"} away\`}
                </>
              )}
            </p>`;
if (!s.includes(body)) fail("could not find the up-next description");

// No assignment means no station, so the badge goes with it.
s = s.replace(badge, `              {assignments.upNext.station === null ? null : (
                <span className={[
                  "rounded-md px-2 py-1 text-xs font-medium text-white",
                  assignments.upNext.station.startsWith("red") ? "bg-red-600" : "bg-blue-600",
                ].join(" ")}>
                  {STATION_LABELS[assignments.upNext.station as Station]}
                </span>
              )}`);

// Nothing assigned: the qual number is the whole message. And a match zero
// away needs no word for it — the card being there says it.
s = s.replace(body, `            {assignments.upNext.assigned ? (
              <p className="text-muted-foreground text-sm">
                {assignments.upNext.teamNumber === null ? (
                  "That station has no team in the imported schedule."
                ) : (
                  <>
                    Team{" "}
                    <span className="text-foreground font-medium tabular-nums">
                      {assignments.upNext.teamNumber}
                    </span>
                    {assignments.upNext.nickname ? \` · \${assignments.upNext.nickname}\` : ""}
                    {assignments.upNext.matchesAway === 0
                      ? ""
                      : \` · \${assignments.upNext.matchesAway} match\${assignments.upNext.matchesAway === 1 ? "" : "es"} away\`}
                  </>
                )}
              </p>
            ) : null}`);

writeFileSync(p, s);
console.log("src/routes/dashboard.tsx patched");
MJS
runjs /tmp/cs-dashboard.mjs
rm -f /tmp/cs-dashboard.mjs

say "Typecheck"
if command -v bun >/dev/null 2>&1; then
  bun run typecheck || echo "Typecheck reported issues — see above."
else
  npx tsc -b --noEmit || echo "Typecheck reported issues — see above."
fi
