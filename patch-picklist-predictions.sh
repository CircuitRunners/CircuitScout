#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-picklist-predictions.sh
#   1. Submitting a pick list with a first pick / do-not-pick missing its
#      comment now shows an error: "1002 missing comment", or
#      "3 teams missing comments". It used to fail silently.
#   2. Match preview shows Statbotics' and match13's own match predictions
#      (predicted score per alliance), not a sum of EPA/xP
#   3. Under each predicted score, smaller text with the win chance
#
# Predictions come from one request per source per event, pulled with EPA
# and xP (Admin "Refresh" button and the two-hourly cron):
#   Statbotics  /v3/matches?event=KEY   pred.red_score / blue_score / red_win_prob
#   match13     /v1/events/KEY/matches  pred.redScore / blueScore / winProb
#
# Schema: new matchPredictions table. Independent of the other patches.
#
# Every edit is checked before any file is written, so a mismatch stops the
# patch with nothing half-applied. CRLF checkouts are handled.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/pit.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

if grep -qF 'matchPredictions' convex/schema.ts; then
  echo "patch-picklist-predictions already applied."
  exit 0
fi
if ! grep -qF 'defineSchema' convex/schema.ts; then
  echo "ERROR: unexpected repo layout." >&2
  exit 1
fi

# Working files live in the repo root, not /tmp: on Windows, Git Bash's /tmp
# is not where bun looks for a "/tmp/..." path written inside a script.
JSON_FILE=".patch-picklist-predictions.json"
MJS_FILE=".patch-picklist-predictions.mjs"
trap 'rm -f "$JSON_FILE" "$MJS_FILE"' EXIT

say "Applying patch-picklist-predictions"
cat > "$JSON_FILE" <<'PATCH_EDITS_JSON'
[
 {
  "file": "convex/pickLists.ts",
  "old": "import { v } from \"convex/values\";",
  "new": "import { ConvexError, v } from \"convex/values\";"
 },
 {
  "file": "convex/pickLists.ts",
  "old": "    if (missing.length > 0) {\n      throw new Error(\n        `Every first pick and do-not-pick needs a note before this list can be submitted. Missing: ${missing.join(\", \")}.`,\n      );\n    }",
  "new": "    if (missing.length > 0) {\n      // A ConvexError, so the message reaches the scout in production too;\n      // a plain Error is replaced by \"Server Error\" there.\n      throw new ConvexError(\n        missing.length === 1\n          ? `${missing[0]} missing comment`\n          : `${missing.length} teams missing comments`,\n      );\n    }"
 },
 {
  "file": "src/routes/picklists/index.tsx",
  "old": "import { toast } from \"sonner\";\n",
  "new": "import { toast } from \"sonner\";\nimport { ConvexError } from \"convex/values\";\n"
 },
 {
  "file": "src/routes/picklists/index.tsx",
  "old": "                    if (list.isSubmitted) void unsubmit({ listId: list._id });\n                    else void setSubmitted({ listId: list._id });",
  "new": "                    if (list.isSubmitted) {\n                      void unsubmit({ listId: list._id });\n                      return;\n                    }\n                    void setSubmitted({ listId: list._id })\n                      .then(() => toast.success(`${list.name} submitted`))\n                      .catch((error: unknown) => {\n                        if (error instanceof ConvexError) {\n                          toast.error(String(error.data), {\n                            description:\n                              \"Every first pick and do-not-pick needs a comment before the list can be submitted.\",\n                          });\n                        } else {\n                          toast.error(\"Could not submit\", {\n                            description: error instanceof Error ? error.message : String(error),\n                          });\n                        }\n                      });"
 },
 {
  "file": "convex/schema.ts",
  "old": "  /**\n   * TBA qualification rank for one team at one event.",
  "new": "  /**\n   * Statbotics' and match13's own prediction for one match, from their EPA\n   * and xP models. One row per match per source, pulled with EPA and xP.\n   */\n  matchPredictions: defineTable({\n    eventId: v.id(\"events\"),\n    /** TBA match key, e.g. 2026gaalb_qm12. All three sites use the same keys. */\n    matchKey: v.string(),\n    source: v.union(v.literal(\"statbotics\"), v.literal(\"match13\")),\n    redScore: v.number(),\n    blueScore: v.number(),\n    /** 0 to 1. Blue's chance is what is left over. */\n    redWinProb: v.number(),\n    fetchedAt: v.number(),\n  })\n    .index(\"by_event_source\", [\"eventId\", \"source\"])\n    .index(\"by_match\", [\"matchKey\"]),\n\n  /**\n   * TBA qualification rank for one team at one event."
 },
 {
  "file": "convex/statbotics.ts",
  "old": "const BASE = \"https://api-statbotics.popcornpenguins.com/v3\";",
  "new": "export const STATBOTICS_BASE = \"https://api-statbotics.popcornpenguins.com/v3\";\nconst BASE = STATBOTICS_BASE;"
 },
 {
  "file": "convex/match13.ts",
  "old": "const BASE = \"https://actions.match13.com/v1\";",
  "new": "export const MATCH13_BASE = \"https://actions.match13.com/v1\";\nconst BASE = MATCH13_BASE;"
 },
 {
  "file": "convex/predictions.ts",
  "old": null,
  "new": "/// <reference types=\"node\" />\n\nimport { v } from \"convex/values\";\nimport { internalAction, internalMutation, query } from \"./_generated/server\";\nimport { internal } from \"./_generated/api\";\nimport { requireUser } from \"./lib/guards\";\nimport { STATBOTICS_BASE } from \"./statbotics\";\nimport { MATCH13_BASE } from \"./match13\";\n\n/**\n * Match predictions straight from Statbotics (EPA model) and match13 (xP\n * model). Summing EPA or xP per alliance ignores everything those models know\n * about how robots combine; their own predictions do not.\n */\n\ntype Row = { matchKey: string; redScore: number; blueScore: number; redWinProb: number };\nconst source = v.union(v.literal(\"statbotics\"), v.literal(\"match13\"));\n\nconst num = (value: unknown): number | null =>\n  typeof value === \"number\" && Number.isFinite(value) ? value : null;\n\n/** Both sources' predictions for one match; null where a source has none. */\nexport const forMatch = query({\n  args: { matchKey: v.string() },\n  handler: async (ctx, args) => {\n    await requireUser(ctx);\n    const rows = await ctx.db\n      .query(\"matchPredictions\")\n      .withIndex(\"by_match\", (q) => q.eq(\"matchKey\", args.matchKey))\n      .collect();\n    const pick = (s: \"statbotics\" | \"match13\") => {\n      const row = rows.find((r) => r.source === s);\n      return row\n        ? { redScore: row.redScore, blueScore: row.blueScore, redWinProb: row.redWinProb, fetchedAt: row.fetchedAt }\n        : null;\n    };\n    return { statbotics: pick(\"statbotics\"), match13: pick(\"match13\") };\n  },\n});\n\n/** Replaces one source's predictions for one event. */\nexport const store = internalMutation({\n  args: {\n    eventId: v.id(\"events\"),\n    source,\n    rows: v.array(v.object({\n      matchKey: v.string(),\n      redScore: v.number(),\n      blueScore: v.number(),\n      redWinProb: v.number(),\n    })),\n  },\n  handler: async (ctx, args) => {\n    const existing = await ctx.db\n      .query(\"matchPredictions\")\n      .withIndex(\"by_event_source\", (q) => q.eq(\"eventId\", args.eventId).eq(\"source\", args.source))\n      .collect();\n    const byKey = new Map(existing.map((r) => [r.matchKey, r]));\n    const now = Date.now();\n    for (const row of args.rows) {\n      const found = byKey.get(row.matchKey);\n      if (found) {\n        await ctx.db.patch(found._id, { ...row, fetchedAt: now });\n        byKey.delete(row.matchKey);\n      } else {\n        await ctx.db.insert(\"matchPredictions\", {\n          eventId: args.eventId, source: args.source, ...row, fetchedAt: now,\n        });\n      }\n    }\n    // A match the source no longer lists (a replayed or removed match).\n    for (const stale of byKey.values()) await ctx.db.delete(stale._id);\n    return { stored: args.rows.length };\n  },\n});\n\nasync function fetchStatbotics(eventKey: string): Promise<Row[]> {\n  const response = await fetch(\n    `${STATBOTICS_BASE}/matches?event=${encodeURIComponent(eventKey)}&limit=1000`,\n    { headers: { Accept: \"application/json\" } },\n  );\n  if (!response.ok) {\n    throw new Error(`Statbotics returned ${response.status} for ${eventKey} matches.`);\n  }\n  const body = (await response.json()) as unknown;\n  const list: unknown[] = Array.isArray(body)\n    ? body\n    : Array.isArray((body as { results?: unknown[] } | null)?.results)\n      ? (body as { results: unknown[] }).results\n      : [];\n  const rows = list.flatMap((item): Row[] => {\n    const m = (item ?? {}) as { key?: unknown; pred?: Record<string, unknown> | null };\n    const pred = m.pred ?? {};\n    const redScore = num(pred.red_score);\n    const blueScore = num(pred.blue_score);\n    const redWinProb = num(pred.red_win_prob);\n    if (typeof m.key !== \"string\" || redScore === null || blueScore === null || redWinProb === null) {\n      return [];\n    }\n    return [{ matchKey: m.key, redScore, blueScore, redWinProb }];\n  });\n  if (list.length > 0 && rows.length === 0) {\n    throw new Error(\n      `Got ${list.length} matches from Statbotics but no predictions. First: ${JSON.stringify(list[0]).slice(0, 300)}`,\n    );\n  }\n  return rows;\n}\n\nasync function fetchMatch13(eventKey: string): Promise<Row[]> {\n  const key = process.env.MATCH13_API_KEY;\n  if (!key) throw new Error(\"MATCH13_API_KEY is not set on this deployment.\");\n  const response = await fetch(\n    `${MATCH13_BASE}/events/${encodeURIComponent(eventKey)}/matches`,\n    { headers: { Authorization: `Bearer ${key}`, Accept: \"application/json\" } },\n  );\n  if (response.status === 404) return [];\n  if (response.status === 401 || response.status === 403) {\n    throw new Error(\"match13 rejected the API key. Check MATCH13_API_KEY.\");\n  }\n  if (response.status === 429) {\n    const after = response.headers.get(\"Retry-After\");\n    throw new Error(`match13 rate limit reached${after ? `; try again in ${after}s` : \"\"}.`);\n  }\n  if (!response.ok) {\n    throw new Error(`match13 returned ${response.status} for ${eventKey} matches.`);\n  }\n  const body = (await response.json()) as { matches?: unknown } | null;\n  const list: unknown[] = Array.isArray(body?.matches) ? body.matches : [];\n  const rows = list.flatMap((item): Row[] => {\n    const m = (item ?? {}) as { key?: unknown; pred?: Record<string, unknown> | null };\n    const pred = m.pred ?? {};\n    const redScore = num(pred.redScore);\n    const blueScore = num(pred.blueScore);\n    // winProb is the chance red wins.\n    const redWinProb = num(pred.winProb);\n    if (typeof m.key !== \"string\" || redScore === null || blueScore === null || redWinProb === null) {\n      return [];\n    }\n    return [{ matchKey: m.key, redScore, blueScore, redWinProb }];\n  });\n  if (list.length > 0 && rows.length === 0) {\n    throw new Error(\n      `Got ${list.length} matches from match13 but no predictions. First: ${JSON.stringify(list[0]).slice(0, 300)}`,\n    );\n  }\n  return rows;\n}\n\n/** Internal only: reached through refresh.now (admin-checked) and the cron. */\nexport const refreshStatbotics = internalAction({\n  args: { eventId: v.id(\"events\"), eventKey: v.string() },\n  handler: async (ctx, args): Promise<{ stored: number }> => {\n    const rows = await fetchStatbotics(args.eventKey);\n    return await ctx.runMutation(internal.predictions.store, {\n      eventId: args.eventId, source: \"statbotics\", rows,\n    });\n  },\n});\n\nexport const refreshMatch13 = internalAction({\n  args: { eventId: v.id(\"events\"), eventKey: v.string() },\n  handler: async (ctx, args): Promise<{ stored: number }> => {\n    const rows = await fetchMatch13(args.eventKey);\n    return await ctx.runMutation(internal.predictions.store, {\n      eventId: args.eventId, source: \"match13\", rows,\n    });\n  },\n});\n"
 },
 {
  "file": "convex/refresh.ts",
  "old": "    rankedTeams: number;\n    problems: string[];\n  }> => {",
  "new": "    rankedTeams: number;\n    predictedMatches: number;\n    problems: string[];\n  }> => {"
 },
 {
  "file": "convex/refresh.ts",
  "old": "    let rankedTeams = 0;\n    const problems: string[] = [];\n",
  "new": "    let rankedTeams = 0;\n    let predictedMatches = 0;\n    const problems: string[] = [];\n"
 },
 {
  "file": "convex/refresh.ts",
  "old": "    if (epaTeams === 0 && xpTeams === 0 && matchesUpdated === 0 && rankedTeams === 0\n      && problems.length > 0) {\n      throw new Error(problems.join(\" · \"));\n    }\n    return { epaTeams, xpTeams, matchesUpdated, rankedTeams, problems };",
  "new": "    // Match predictions, one request per source.\n    for (const fn of [internal.predictions.refreshStatbotics, internal.predictions.refreshMatch13]) {\n      try {\n        const result = await ctx.runAction(fn, {\n          eventId: event.eventId as Id<\"events\">,\n          eventKey: event.eventKey,\n        });\n        predictedMatches = Math.max(predictedMatches, result.stored);\n      } catch (error) {\n        problems.push(message(error));\n      }\n    }\n\n    if (epaTeams === 0 && xpTeams === 0 && matchesUpdated === 0 && rankedTeams === 0\n      && problems.length > 0) {\n      throw new Error(problems.join(\" · \"));\n    }\n    return { epaTeams, xpTeams, matchesUpdated, rankedTeams, predictedMatches, problems };"
 },
 {
  "file": "convex/refresh.ts",
  "old": "      } catch {\n        // Nor TBA having no rankings before quals start.\n      }",
  "new": "      } catch {\n        // Nor TBA having no rankings before quals start.\n      }\n      for (const fn of [internal.predictions.refreshStatbotics, internal.predictions.refreshMatch13]) {\n        try {\n          await ctx.runAction(fn, {\n            eventId: event.eventId as Id<\"events\">,\n            eventKey: event.eventKey,\n          });\n        } catch {\n          // Nor a source having no match predictions yet.\n        }\n      }"
 },
 {
  "file": "src/routes/admin/stat-sources-card.tsx",
  "old": "                    `${r.matchesUpdated} matches updated · ${r.rankedTeams} teams ranked.`;",
  "new": "                    `${r.matchesUpdated} matches updated · ${r.rankedTeams} teams ranked · ` +\n                    `${r.predictedMatches} match predictions.`;"
 },
 {
  "file": "convex/events.ts",
  "old": "  for (const row of ranks) await ctx.db.delete(row._id);",
  "new": "  for (const row of ranks) await ctx.db.delete(row._id);\n  for (const s of [\"statbotics\", \"match13\"] as const) {\n    const predictions = await ctx.db\n      .query(\"matchPredictions\")\n      .withIndex(\"by_event_source\", (q) => q.eq(\"eventId\", eventId).eq(\"source\", s))\n      .collect();\n    for (const row of predictions) await ctx.db.delete(row._id);\n  }"
 },
 {
  "file": "src/routes/matches/preview.tsx",
  "old": "import { Badge } from \"@/components/ui/badge\";",
  "new": "import { Badge } from \"@/components/ui/badge\";\n\n/** \"3%\", with the ends shown as <1% / >99% rather than a flat 0 or 100. */\nfunction chance(p: number): string {\n  if (p < 0.01) return \"<1%\";\n  if (p > 0.99) return \">99%\";\n  return `${Math.round(p * 100)}%`;\n}"
 },
 {
  "file": "src/routes/matches/preview.tsx",
  "old": "  const data = useQuery(\n    api.stats.forMatch,\n    Number.isNaN(matchNumber) ? \"skip\" : { matchNumber },\n  );",
  "new": "  const data = useQuery(\n    api.stats.forMatch,\n    Number.isNaN(matchNumber) ? \"skip\" : { matchNumber },\n  );\n  const predictions = useQuery(\n    api.predictions.forMatch,\n    data ? { matchKey: data.tbaMatchKey } : \"skip\",\n  );"
 },
 {
  "file": "src/routes/matches/preview.tsx",
  "old": "  // EPA or xP, whichever site this team has chosen.\n  const ratingSum = (side: Robot[]) =>\n    side.reduce((sum, r) => sum + (ratings.byTeam.get(r.teamNumber)?.total ?? 0), 0);\n  const ratingCovered = (side: Robot[]) =>\n    side.filter((r) => ratings.byTeam.has(r.teamNumber)).length;\n",
  "new": "  // Statbotics or match13, whichever site this team has chosen.\n  const prediction = predictions?.[ratings.site] ?? null;\n"
 },
 {
  "file": "src/routes/matches/preview.tsx",
  "old": "            <CardTitle>Projected · {ratings.metric}</CardTitle>\n            <CardDescription>\n              {ratings.siteName} {ratings.metric} summed per alliance. Independent of your scouting,\n              so a wide gap between the two is worth a look rather than a\n              tiebreak.\n            </CardDescription>\n          </CardHeader>\n          <CardContent className=\"flex flex-wrap items-center gap-6\">\n            {ratings.loading ? (\n              <p className=\"text-muted-foreground text-sm\">Loading…</p>\n            ) : ratings.byTeam.size === 0 ? (\n              <p className=\"text-muted-foreground text-sm\">\n                No {ratings.metric} yet — an admin can pull it from the Admin page.\n              </p>\n            ) : (\n              <>\n                <div>\n                  <p className=\"text-xs text-red-600 dark:text-red-400\">Red</p>\n                  <p className=\"text-3xl font-semibold tabular-nums\">\n                    {ratingSum(data.red).toFixed(0)}\n                  </p>\n                </div>\n                <div>\n                  <p className=\"text-xs text-blue-600 dark:text-blue-400\">Blue</p>\n                  <p className=\"text-3xl font-semibold tabular-nums\">\n                    {ratingSum(data.blue).toFixed(0)}\n                  </p>\n                </div>\n                {ratingCovered(data.red) + ratingCovered(data.blue) < 6 ? (\n                  <Badge variant=\"outline\">\n                    Only {ratingCovered(data.red) + ratingCovered(data.blue)} of 6 have {ratings.metric}\n                  </Badge>\n                ) : null}\n              </>\n            )}\n          </CardContent>",
  "new": "            <CardTitle>Projected · {ratings.metric}</CardTitle>\n            <CardDescription>\n              The {ratings.siteName} prediction for this match, from its own {ratings.metric} model.\n              Independent of your scouting, so a wide gap between the two is\n              worth a look rather than a tiebreak.\n            </CardDescription>\n          </CardHeader>\n          <CardContent className=\"flex flex-wrap items-center gap-6\">\n            {ratings.loading || predictions === undefined ? (\n              <p className=\"text-muted-foreground text-sm\">Loading…</p>\n            ) : prediction === null ? (\n              <p className=\"text-muted-foreground text-sm\">\n                No {ratings.siteName} prediction for this match yet — an admin can\n                pull it from the Admin page.\n              </p>\n            ) : (\n              <>\n                <div>\n                  <p className=\"text-xs text-red-600 dark:text-red-400\">Red</p>\n                  <p className=\"text-3xl font-semibold tabular-nums\">\n                    {prediction.redScore.toFixed(0)}\n                  </p>\n                  <p className=\"text-muted-foreground text-xs tabular-nums\">\n                    {chance(prediction.redWinProb)} to win\n                  </p>\n                </div>\n                <div>\n                  <p className=\"text-xs text-blue-600 dark:text-blue-400\">Blue</p>\n                  <p className=\"text-3xl font-semibold tabular-nums\">\n                    {prediction.blueScore.toFixed(0)}\n                  </p>\n                  <p className=\"text-muted-foreground text-xs tabular-nums\">\n                    {chance(1 - prediction.redWinProb)} to win\n                  </p>\n                </div>\n              </>\n            )}\n          </CardContent>"
 }
]
PATCH_EDITS_JSON

cat > "$MJS_FILE" <<'MJS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const edits = JSON.parse(readFileSync(process.argv[2], "utf8"));
const files = new Map(); // path -> { text, crlf }
const fail = (msg) => { console.error(`ERROR: ${msg}\nNothing was changed.`); process.exit(1); };

for (const { file, old, new: next } of edits) {
  if (old === null) {
    if (existsSync(file)) fail(`${file} already exists.`);
    files.set(file, { text: next, crlf: false });
    continue;
  }
  if (!files.has(file)) {
    if (!existsSync(file)) fail(`${file} is missing.`);
    const raw = readFileSync(file, "utf8");
    files.set(file, { text: raw.replace(/\r\n/g, "\n"), crlf: raw.includes("\r\n") });
  }
  const entry = files.get(file);
  const first = entry.text.indexOf(old);
  if (first === -1 || entry.text.indexOf(old, first + 1) !== -1) {
    fail(`${file} does not look like the expected version. Could not place this edit ` +
      `(${first === -1 ? "not found" : "found twice"}):\n` + old.split("\n").slice(0, 4).join("\n"));
  }
  entry.text = entry.text.slice(0, first) + next + entry.text.slice(first + old.length);
}

for (const [file, { text, crlf }] of files) {
  writeFileSync(file, crlf ? text.replace(/\n/g, "\r\n") : text);
  console.log(`${file} written`);
}
MJS
bun "$MJS_FILE" "$JSON_FILE"

say "Done"
cat <<'TXT'
Next:
  1. bun run go
  2. Admin page: Refresh (pulls the predictions the first time)
  3. Open a match preview; then try submitting a pick list with an empty
     first-pick comment.
TXT
