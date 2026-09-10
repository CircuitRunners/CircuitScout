#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-match-scores.sh
#   Pulls actual scores and predicted times from The Blue Alliance and shows
#   them on the match preview beside the projected output.
#
# SCHEMA CHANGE: matches gains redScore, blueScore, winningAlliance,
# predictedTime, actualTime — all optional, so existing rows stay valid.
#
# Scores only refresh when an admin re-imports the event. The UI says so
# rather than implying it is live.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/tba.ts ]] || { echo "ERROR: run track-a.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema"
cat > /tmp/ms1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
if (s.includes("redScore")) { console.log("already present"); process.exit(0); }
const anchor = "    scheduledTime: v.union(v.number(), v.null()),";
if (!s.includes(anchor)) { console.error("could not find scheduledTime"); process.exit(1); }
s = s.replace(anchor, `${anchor}
    // From TBA. Optional because rows imported before this existed have none.
    predictedTime: v.optional(v.union(v.number(), v.null())),
    actualTime: v.optional(v.union(v.number(), v.null())),
    redScore: v.optional(v.union(v.number(), v.null())),
    blueScore: v.optional(v.union(v.number(), v.null())),
    winningAlliance: v.optional(v.string()),`);
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/ms1.mjs

say "TBA import: scores and times"
cat > /tmp/ms2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

// --- tba.ts ---
let t = readFileSync("convex/tba.ts", "utf8");
if (!t.includes("redScore")) {
  const oldType = `  alliances: {
    red: { team_keys: string[] };
    blue: { team_keys: string[] };
  };
  time: number | null;
  predicted_time?: number | null;
};`;
  if (!t.includes(oldType)) fail("could not find the TbaMatch type");
  t = t.replace(oldType, `  alliances: {
    red: { team_keys: string[]; score: number | null };
    blue: { team_keys: string[]; score: number | null };
  };
  winning_alliance?: string | null;
  time: number | null;
  predicted_time?: number | null;
  actual_time?: number | null;
};

/** TBA sends epoch seconds, and -1 for a score that does not exist yet. */
const seconds = (v: number | null | undefined): number | null =>
  v === null || v === undefined ? null : v * 1000;
const score = (v: number | null | undefined): number | null =>
  v === null || v === undefined || v < 0 ? null : v;`);

  const oldMap = `        scheduledTime: m.time !== null && m.time !== undefined ? m.time * 1000 : null,
      })),`;
  if (!t.includes(oldMap)) fail("could not find the match mapping");
  t = t.replace(oldMap, `        scheduledTime: seconds(m.time),
        predictedTime: seconds(m.predicted_time),
        actualTime: seconds(m.actual_time),
        redScore: score(m.alliances.red.score),
        blueScore: score(m.alliances.blue.score),
        winningAlliance: m.winning_alliance ?? "",
      })),`);
  writeFileSync("convex/tba.ts", t);
  console.log("convex/tba.ts patched");
} else { console.log("tba.ts already patched"); }

// --- events.ts ---
let e = readFileSync("convex/events.ts", "utf8");
if (!e.includes("redScore")) {
  e = e.replace(`  scheduledTime: v.union(v.number(), v.null()),
});`, `  scheduledTime: v.union(v.number(), v.null()),
  predictedTime: v.union(v.number(), v.null()),
  actualTime: v.union(v.number(), v.null()),
  redScore: v.union(v.number(), v.null()),
  blueScore: v.union(v.number(), v.null()),
  winningAlliance: v.string(),
});`);
  e = e.replace(`          scheduledTime: m.scheduledTime,
        });`, `          scheduledTime: m.scheduledTime,
          predictedTime: m.predictedTime,
          actualTime: m.actualTime,
          redScore: m.redScore,
          blueScore: m.blueScore,
          winningAlliance: m.winningAlliance,
        });`);
  writeFileSync("convex/events.ts", e);
  console.log("convex/events.ts patched");
} else { console.log("events.ts already patched"); }

// --- stats.forMatch ---
let s = readFileSync("convex/stats.ts", "utf8");
if (!s.includes("redScore")) {
  const old = `    return {
      matchNumber: match.matchNumber,
      scheduledTime: match.scheduledTime,`;
  if (!s.includes(old)) fail("could not find stats.forMatch return");
  s = s.replace(old, `    return {
      matchNumber: match.matchNumber,
      scheduledTime: match.scheduledTime,
      predictedTime: match.predictedTime ?? null,
      actualTime: match.actualTime ?? null,
      redScore: match.redScore ?? null,
      blueScore: match.blueScore ?? null,
      winningAlliance: match.winningAlliance ?? "",
      importedAt: loaded.event.importedAt,`);
  writeFileSync("convex/stats.ts", s);
  console.log("convex/stats.ts patched");
} else { console.log("stats.ts already patched"); }
MJS
bun /tmp/ms2.mjs

say "Match preview: actual score or scheduled time"
cat > /tmp/ms3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/matches/preview.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("Actual score")) { console.log("already patched"); process.exit(0); }

const oldCard = s.slice(
  s.indexOf("      <Card>\n        <CardHeader>\n          <CardTitle>Projected alliance output</CardTitle>"),
  s.indexOf('      <h3 className="font-medium text-red-600'),
);
if (!oldCard) fail("could not find the projected output card");

const newCard = `      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Projected output</CardTitle>
            <CardDescription>
              Sum of each robot's average total fuel and climb points. A crude
              estimate that ignores defense, field interference and robots with
              no data — a starting point, not a prediction.
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap items-center gap-6">
            <div>
              <p className="text-xs text-red-600 dark:text-red-400">Red</p>
              <p className="text-3xl font-semibold tabular-nums">
                {redProjected.toFixed(0)}
              </p>
            </div>
            <div>
              <p className="text-xs text-blue-600 dark:text-blue-400">Blue</p>
              <p className="text-3xl font-semibold tabular-nums">
                {blueProjected.toFixed(0)}
              </p>
            </div>
            {data.red.concat(data.blue).some((r) => r.stats.reportCount === 0) ? (
              <Badge variant="outline">Some robots have no data</Badge>
            ) : null}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>{played ? "Actual score" : "Scheduled"}</CardTitle>
            <CardDescription>
              {played
                ? "Official result from The Blue Alliance, as of the last import."
                : "Not played yet. Times from The Blue Alliance drift during an event."}
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap items-center gap-6">
            {played ? (
              <>
                <div>
                  <p className="text-xs text-red-600 dark:text-red-400">
                    Red{data.winningAlliance === "red" ? " · won" : ""}
                  </p>
                  <p
                    className={[
                      "text-3xl tabular-nums",
                      data.winningAlliance === "red" ? "font-bold" : "font-semibold",
                    ].join(" ")}
                  >
                    {data.redScore}
                  </p>
                </div>
                <div>
                  <p className="text-xs text-blue-600 dark:text-blue-400">
                    Blue{data.winningAlliance === "blue" ? " · won" : ""}
                  </p>
                  <p
                    className={[
                      "text-3xl tabular-nums",
                      data.winningAlliance === "blue" ? "font-bold" : "font-semibold",
                    ].join(" ")}
                  >
                    {data.blueScore}
                  </p>
                </div>
                {data.winningAlliance === "" ? (
                  <Badge variant="outline">Tie</Badge>
                ) : null}
              </>
            ) : (
              <div>
                <p className="text-2xl font-semibold">
                  {when === null ? "Time unknown" : when.toLocaleTimeString([], {
                    hour: "numeric", minute: "2-digit",
                  })}
                </p>
                {when !== null ? (
                  <p className="text-muted-foreground text-xs">
                    {when.toLocaleDateString()}
                    {data.predictedTime !== null ? " · predicted" : " · scheduled"}
                  </p>
                ) : null}
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      {/* Scores are only as fresh as the last import — say so rather than
          letting a stale number read as live. */}
      <p className="text-muted-foreground text-xs">
        Scores and times come from the last TBA import
        {data.importedAt !== null
          ? \` (\${new Date(data.importedAt).toLocaleString()})\`
          : ""}
        . An admin re-importing the event refreshes them.
      </p>

`;
s = s.replace(oldCard, newCard);

// derived values
s = s.replace(`  const redProjected = projected(data.red);
  const blueProjected = projected(data.blue);`,
`  const redProjected = projected(data.red);
  const blueProjected = projected(data.blue);

  const played = data.redScore !== null && data.blueScore !== null;
  // Predicted time is TBA's live estimate and beats the original schedule
  // once an event starts running late, which they always do.
  const whenMs = data.actualTime ?? data.predictedTime ?? data.scheduledTime;
  const when = whenMs === null ? null : new Date(whenMs);`);

s = s.replace('      description="Season averages predict; the reports below record what actually happened."',
              '      description="Season averages predict; the reports below record what your scouts saw."');

writeFileSync(p, s);
console.log("src/routes/matches/preview.tsx patched");
MJS
bun /tmp/ms3.mjs
rm -f /tmp/ms1.mjs /tmp/ms2.mjs /tmp/ms3.mjs

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Done. Re-import the event on /admin to pull scores for matches already played.

DONE
