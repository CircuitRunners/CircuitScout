#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-archive-snapshots.sh
#   1. Deleting an event keeps it in Past Events: a snapshot of its list row
#      and per-team table is saved right before it goes (soft delete, purge
#      now, the hourly purge, and the no-data Remove)
#   2. Recovering an event drops its snapshot, so Past Events goes back to
#      live data. Live data always wins over a snapshot with the same key.
#   3. Past Events can be filtered by season
#
# Schema: new archiveSnapshots table. Events already sitting in the 24-hour
# recovery window show from their still-present data and are snapshotted
# when purged. Independent of the pit patches; apply in any order.
#
# Every edit is checked before any file is written, so a mismatch stops the
# patch with nothing half-applied. CRLF checkouts are handled.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/pit.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

if grep -qF 'archiveSnapshots' convex/schema.ts; then
  echo "patch-archive-snapshots already applied."
  exit 0
fi
if ! grep -qF 'defineSchema' convex/schema.ts; then
  echo "ERROR: unexpected repo layout." >&2
  exit 1
fi

# Working files live in the repo root, not /tmp: on Windows, Git Bash's /tmp
# is not where bun looks for a "/tmp/..." path written inside a script.
JSON_FILE=".patch-archive-snapshots.json"
MJS_FILE=".patch-archive-snapshots.mjs"
trap 'rm -f "$JSON_FILE" "$MJS_FILE"' EXIT

say "Applying patch-archive-snapshots"
cat > "$JSON_FILE" <<'PATCH_EDITS_JSON'
[
 {
  "file": "convex/schema.ts",
  "old": "  /**\n   * Which event each FRC team is currently scouting.",
  "new": "  /**\n   * What Past Events shows for a deleted event: its list row and per-team\n   * table as they were right before deletion. One per event key. Live data\n   * always wins: recovering the event removes its snapshot, and a snapshot is\n   * ignored while an undeleted event with the same key exists.\n   */\n  archiveSnapshots: defineTable({\n    eventKey: v.string(),\n    name: v.string(),\n    season: v.number(),\n    teamCount: v.number(),\n    matchCount: v.number(),\n    reportCount: v.number(),\n    /** The per-team table, as JSON: { teamNumber, nickname, stats }[]. */\n    rows: v.string(),\n    takenAt: v.number(),\n  }).index(\"by_key\", [\"eventKey\"]),\n\n  /**\n   * Which event each FRC team is currently scouting."
 },
 {
  "file": "convex/lib/archiveData.ts",
  "old": null,
  "new": "import type { QueryCtx } from \"../_generated/server\";\nimport type { Doc, Id } from \"../_generated/dataModel\";\nimport { summarise, type Summary } from \"./summarise\";\n\n/**\n * What Past Events shows for one event, worked out from its live data. Read\n * only. Shared by the archive queries and by the snapshot taken on delete, so\n * a snapshot is exactly what the page showed a moment before.\n */\n\nexport type ArchiveRow = { teamNumber: number; nickname: string; stats: Summary };\n\nexport type ArchiveTable = {\n  teamCount: number;\n  matchCount: number;\n  reportCount: number;\n  rows: ArchiveRow[];\n};\n\ntype Reader = { db: QueryCtx[\"db\"] };\n\nexport const seasonOf = (eventKey: string) => Number.parseInt(eventKey.slice(0, 4), 10);\n\n/** Just the counts, for the event list. */\nexport async function liveCounts(ctx: Reader, eventId: Id<\"events\">) {\n  const [teams, matches, reports] = await Promise.all([\n    ctx.db.query(\"teams\").withIndex(\"by_event\", (q) => q.eq(\"eventId\", eventId)).collect(),\n    ctx.db.query(\"matches\").withIndex(\"by_event\", (q) => q.eq(\"eventId\", eventId)).collect(),\n    ctx.db.query(\"matchReports\").withIndex(\"by_event\", (q) => q.eq(\"eventId\", eventId)).collect(),\n  ]);\n  return { teamCount: teams.length, matchCount: matches.length, reportCount: reports.length };\n}\n\n/** The per-team table, from the event's match reports. */\nexport async function liveTable(ctx: Reader, event: Doc<\"events\">): Promise<ArchiveTable> {\n  const [teams, matches, reports] = await Promise.all([\n    ctx.db.query(\"teams\").withIndex(\"by_event\", (q) => q.eq(\"eventId\", event._id)).collect(),\n    ctx.db.query(\"matches\").withIndex(\"by_event\", (q) => q.eq(\"eventId\", event._id)).collect(),\n    ctx.db.query(\"matchReports\").withIndex(\"by_event\", (q) => q.eq(\"eventId\", event._id)).collect(),\n  ]);\n\n  const matchById = new Map(matches.map((m) => [m._id, m]));\n  const teamById = new Map(teams.map((t) => [t._id, t]));\n\n  const byTeam = new Map<\n    Id<\"teams\">,\n    { report: Doc<\"matchReports\">; isAutoWinner: boolean | null }[]\n  >();\n  for (const report of reports) {\n    const match = matchById.get(report.matchId);\n    const team = teamById.get(report.teamId);\n    let isAutoWinner: boolean | null = null;\n    if (report.autoWinner !== null && match && team) {\n      const onRed = match.redTeamNumbers.includes(team.number);\n      isAutoWinner = report.autoWinner === (onRed ? \"red\" : \"blue\");\n    }\n    const list = byTeam.get(report.teamId) ?? [];\n    list.push({ report, isAutoWinner });\n    byTeam.set(report.teamId, list);\n  }\n\n  const rows: ArchiveRow[] = teams.map((team) => ({\n    teamNumber: team.number,\n    nickname: team.nickname,\n    stats: summarise(byTeam.get(team._id) ?? []),\n  }));\n\n  return {\n    teamCount: teams.length,\n    matchCount: matches.length,\n    reportCount: reports.length,\n    rows: rows.sort((a, b) => a.teamNumber - b.teamNumber),\n  };\n}\n\nexport async function snapshotFor(ctx: Reader, eventKey: string) {\n  return await ctx.db\n    .query(\"archiveSnapshots\")\n    .withIndex(\"by_key\", (q) => q.eq(\"eventKey\", eventKey))\n    .first();\n}\n"
 },
 {
  "file": "convex/lib/archiveSnapshot.ts",
  "old": null,
  "new": "import type { MutationCtx } from \"../_generated/server\";\nimport type { Doc } from \"../_generated/dataModel\";\nimport { liveTable, seasonOf, snapshotFor } from \"./archiveData\";\n\n/**\n * Saves what Past Events shows for this event, replacing any older snapshot\n * of the same key. Called right before an event is deleted.\n */\nexport async function takeSnapshot(ctx: MutationCtx, event: Doc<\"events\">) {\n  const table = await liveTable(ctx, event);\n  await dropSnapshot(ctx, event.tbaEventKey);\n  await ctx.db.insert(\"archiveSnapshots\", {\n    eventKey: event.tbaEventKey,\n    name: event.name,\n    season: seasonOf(event.tbaEventKey),\n    teamCount: table.teamCount,\n    matchCount: table.matchCount,\n    reportCount: table.reportCount,\n    rows: JSON.stringify(table.rows),\n    takenAt: Date.now(),\n  });\n}\n\n/**\n * Before data is destroyed for good. A live event is snapshotted fresh; a\n * soft-deleted one already has its snapshot from the moment it was deleted\n * (its data cannot change while deleted), unless it was deleted before\n * snapshots existed.\n */\nexport async function ensureSnapshot(ctx: MutationCtx, event: Doc<\"events\">) {\n  if (!event.deletedAt || !(await snapshotFor(ctx, event.tbaEventKey))) {\n    await takeSnapshot(ctx, event);\n  }\n}\n\n/** On recovery, so Past Events goes back to the live data. */\nexport async function dropSnapshot(ctx: MutationCtx, eventKey: string) {\n  const rows = await ctx.db\n    .query(\"archiveSnapshots\")\n    .withIndex(\"by_key\", (q) => q.eq(\"eventKey\", eventKey))\n    .collect();\n  for (const row of rows) await ctx.db.delete(row._id);\n}\n"
 },
 {
  "file": "convex/archive.ts",
  "old": "import { v } from \"convex/values\";\nimport { query } from \"./_generated/server\";\nimport { currentTeamNumber, requireUser } from \"./lib/guards\";\nimport { summarise, type Summary } from \"./lib/summarise\";\nimport type { Doc, Id } from \"./_generated/dataModel\";\n\n/**\n * Read-only by construction. Every function here takes an explicit event key\n * and none of them can write, so nothing in this file can put scouting data\n * into the wrong competition.\n */\n\nexport const events = query({\n  args: {},\n  handler: async (ctx) => {\n    await requireUser(ctx);\n    const myTeam = await currentTeamNumber(ctx);\n\n    const all = await ctx.db.query(\"events\").collect();\n    const settings = await ctx.db.query(\"teamSettings\").collect();\n\n    const rows = [];\n    for (const event of all) {\n      if (event.deletedAt) continue;\n      const teams = await ctx.db\n        .query(\"teams\")\n        .withIndex(\"by_event\", (q) => q.eq(\"eventId\", event._id))\n        .collect();\n      const matches = await ctx.db\n        .query(\"matches\")\n        .withIndex(\"by_event\", (q) => q.eq(\"eventId\", event._id))\n        .collect();\n      const reports = await ctx.db\n        .query(\"matchReports\")\n        .withIndex(\"by_event\", (q) => q.eq(\"eventId\", event._id))\n        .collect();\n\n      const activeForTeams = settings\n        .filter((t) => t.activeEventId === event._id)\n        .map((t) => t.teamNumber);\n\n      rows.push({\n        eventKey: event.tbaEventKey,\n        name: event.name,\n        season: Number.parseInt(event.tbaEventKey.slice(0, 4), 10),\n        teamCount: teams.length,\n        matchCount: matches.length,\n        reportCount: reports.length,\n        activeForTeams,\n        isMine: myTeam !== undefined && activeForTeams.includes(myTeam),\n      });\n    }\n\n    return rows.sort((a, b) =>\n      b.season - a.season || a.name.localeCompare(b.name));\n  },\n});\n\nexport const teamTable = query({\n  args: { eventKey: v.string() },\n  handler: async (ctx, args) => {\n    await requireUser(ctx);\n\n    const event = await ctx.db\n      .query(\"events\")\n      .withIndex(\"by_key\", (q) => q.eq(\"tbaEventKey\", args.eventKey))\n      .unique();\n    if (!event) return null;\n\n    const [teams, matches, reports] = await Promise.all([\n      ctx.db.query(\"teams\").withIndex(\"by_event\", (q) => q.eq(\"eventId\", event._id)).collect(),\n      ctx.db.query(\"matches\").withIndex(\"by_event\", (q) => q.eq(\"eventId\", event._id)).collect(),\n      ctx.db.query(\"matchReports\").withIndex(\"by_event\", (q) => q.eq(\"eventId\", event._id)).collect(),\n    ]);\n\n    const matchById = new Map(matches.map((m) => [m._id, m]));\n    const teamById = new Map(teams.map((t) => [t._id, t]));\n\n    const byTeam = new Map<\n      Id<\"teams\">,\n      { report: Doc<\"matchReports\">; isAutoWinner: boolean | null }[]\n    >();\n    for (const report of reports) {\n      const match = matchById.get(report.matchId);\n      const team = teamById.get(report.teamId);\n      let isAutoWinner: boolean | null = null;\n      if (report.autoWinner !== null && match && team) {\n        const onRed = match.redTeamNumbers.includes(team.number);\n        isAutoWinner = report.autoWinner === (onRed ? \"red\" : \"blue\");\n      }\n      const list = byTeam.get(report.teamId) ?? [];\n      list.push({ report, isAutoWinner });\n      byTeam.set(report.teamId, list);\n    }\n\n    const rows: {\n      teamNumber: number;\n      nickname: string;\n      stats: Summary;\n    }[] = teams.map((team) => ({\n      teamNumber: team.number,\n      nickname: team.nickname,\n      stats: summarise(byTeam.get(team._id) ?? []),\n    }));\n\n    return {\n      eventKey: event.tbaEventKey,\n      name: event.name,\n      matchCount: matches.length,\n      rows: rows.sort((a, b) => a.teamNumber - b.teamNumber),\n    };\n  },\n});\n",
  "new": "import { v } from \"convex/values\";\nimport { query } from \"./_generated/server\";\nimport { currentTeamNumber, requireUser } from \"./lib/guards\";\nimport {\n  liveCounts, liveTable, seasonOf, snapshotFor, type ArchiveRow,\n} from \"./lib/archiveData\";\n\n/**\n * Read-only by construction. Every function here takes an explicit event key\n * and none of them can write, so nothing in this file can put scouting data\n * into the wrong competition.\n *\n * Deleted events stay listed. Their numbers come from the snapshot saved\n * right before deletion (or, inside the 24-hour recovery window for an event\n * deleted before snapshots existed, from the data still present). An event\n * that is not deleted always shows live data, so a recovered event updates\n * again.\n */\n\nexport const events = query({\n  args: {},\n  handler: async (ctx) => {\n    await requireUser(ctx);\n    const myTeam = await currentTeamNumber(ctx);\n\n    const [all, settings, snapshots] = await Promise.all([\n      ctx.db.query(\"events\").collect(),\n      ctx.db.query(\"teamSettings\").collect(),\n      ctx.db.query(\"archiveSnapshots\").collect(),\n    ]);\n    const snapshotByKey = new Map(snapshots.map((s) => [s.eventKey, s]));\n\n    const rows = [];\n    const listed = new Set<string>();\n    for (const event of all) {\n      const key = event.tbaEventKey;\n      const snapshot = event.deletedAt ? snapshotByKey.get(key) : undefined;\n      const counts = snapshot ?? await liveCounts(ctx, event._id);\n\n      const activeForTeams = event.deletedAt\n        ? []\n        : settings.filter((t) => t.activeEventId === event._id).map((t) => t.teamNumber);\n\n      listed.add(key);\n      rows.push({\n        eventKey: key,\n        name: event.name,\n        season: seasonOf(key),\n        teamCount: counts.teamCount,\n        matchCount: counts.matchCount,\n        reportCount: counts.reportCount,\n        activeForTeams,\n        isMine: myTeam !== undefined && activeForTeams.includes(myTeam),\n        deleted: Boolean(event.deletedAt),\n        snapshotAt: snapshot?.takenAt ?? null,\n      });\n    }\n\n    // Purged for good: only the snapshot is left.\n    for (const snapshot of snapshots) {\n      if (listed.has(snapshot.eventKey)) continue;\n      rows.push({\n        eventKey: snapshot.eventKey,\n        name: snapshot.name,\n        season: snapshot.season,\n        teamCount: snapshot.teamCount,\n        matchCount: snapshot.matchCount,\n        reportCount: snapshot.reportCount,\n        activeForTeams: [] as number[],\n        isMine: false,\n        deleted: true,\n        snapshotAt: snapshot.takenAt as number | null,\n      });\n    }\n\n    return rows.sort((a, b) =>\n      b.season - a.season || a.name.localeCompare(b.name));\n  },\n});\n\nexport const teamTable = query({\n  args: { eventKey: v.string() },\n  handler: async (ctx, args) => {\n    await requireUser(ctx);\n\n    const event = await ctx.db\n      .query(\"events\")\n      .withIndex(\"by_key\", (q) => q.eq(\"tbaEventKey\", args.eventKey))\n      .unique();\n\n    if (event && !event.deletedAt) {\n      const table = await liveTable(ctx, event);\n      return {\n        eventKey: event.tbaEventKey,\n        name: event.name,\n        matchCount: table.matchCount,\n        rows: table.rows,\n        deleted: false,\n        snapshotAt: null as number | null,\n      };\n    }\n\n    const snapshot = await snapshotFor(ctx, args.eventKey);\n    if (snapshot) {\n      return {\n        eventKey: snapshot.eventKey,\n        name: snapshot.name,\n        matchCount: snapshot.matchCount,\n        rows: JSON.parse(snapshot.rows) as ArchiveRow[],\n        deleted: true,\n        snapshotAt: snapshot.takenAt as number | null,\n      };\n    }\n\n    // Deleted before snapshots existed and not yet purged: the data is still here.\n    if (event) {\n      const table = await liveTable(ctx, event);\n      return {\n        eventKey: event.tbaEventKey,\n        name: event.name,\n        matchCount: table.matchCount,\n        rows: table.rows,\n        deleted: true,\n        snapshotAt: null as number | null,\n      };\n    }\n    return null;\n  },\n});\n"
 },
 {
  "file": "convex/events.ts",
  "old": "import type { MutationCtx } from \"./_generated/server\";",
  "new": "import type { MutationCtx } from \"./_generated/server\";\nimport { dropSnapshot, ensureSnapshot, takeSnapshot } from \"./lib/archiveSnapshot\";"
 },
 {
  "file": "convex/events.ts",
  "old": "      if (entries.length > 0) {\n        throw new Error(\"A pick list for that event has teams on it.\");\n      }\n    }\n",
  "new": "      if (entries.length > 0) {\n        throw new Error(\"A pick list for that event has teams on it.\");\n      }\n    }\n\n    // Keeps it in Past Events.\n    await takeSnapshot(ctx, event);\n"
 },
 {
  "file": "convex/events.ts",
  "old": "async function purgeEventData(ctx: MutationCtx, eventId: Id<\"events\">) {\n  const args = { eventId };",
  "new": "async function purgeEventData(ctx: MutationCtx, eventId: Id<\"events\">) {\n  const args = { eventId };\n  // Past Events keeps showing it after the data is gone.\n  const event = await ctx.db.get(eventId);\n  if (event) await ensureSnapshot(ctx, event);"
 },
 {
  "file": "convex/events.ts",
  "old": "      throw new Error(\"The event key does not match.\");\n    }\n    await ctx.db.patch(args.eventId, {\n      deletedAt: Date.now(),\n      deletedBy: me.userId,\n    });",
  "new": "      throw new Error(\"The event key does not match.\");\n    }\n    // Past Events shows this from now on, while the event itself is hidden.\n    await takeSnapshot(ctx, event);\n    await ctx.db.patch(args.eventId, {\n      deletedAt: Date.now(),\n      deletedBy: me.userId,\n    });"
 },
 {
  "file": "convex/events.ts",
  "old": "    if (!event) throw new Error(\"That event is gone for good.\");\n    await ctx.db.patch(args.eventId, { deletedAt: null, deletedBy: null });",
  "new": "    if (!event) throw new Error(\"That event is gone for good.\");\n    await ctx.db.patch(args.eventId, { deletedAt: null, deletedBy: null });\n    // Back to live data in Past Events, not the frozen copy.\n    await dropSnapshot(ctx, event.tbaEventKey);"
 },
 {
  "file": "src/routes/archive/index.tsx",
  "old": "import { useState } from \"react\";",
  "new": "import { useMemo, useState } from \"react\";"
 },
 {
  "file": "src/routes/archive/index.tsx",
  "old": "import { Button } from \"@/components/ui/button\";",
  "new": "import { Button } from \"@/components/ui/button\";\nimport { MenuSelect } from \"@/components/menu-select\";"
 },
 {
  "file": "src/routes/archive/index.tsx",
  "old": "  const [entered, setEntered] = useState(false);\n",
  "new": "  const [entered, setEntered] = useState(false);\n  const [season, setSeason] = useState<string>(\"all\");\n\n  const seasons = useMemo(\n    () => [...new Set((events ?? []).map((e) => e.season))].sort((a, b) => b - a),\n    [events],\n  );\n  const shown = (events ?? []).filter((e) => season === \"all\" || String(e.season) === season);\n"
 },
 {
  "file": "src/routes/archive/index.tsx",
  "old": "            <CardDescription>\n              Every event imported into this deployment, newest season first.\n            </CardDescription>\n          </CardHeader>\n          <CardContent className=\"space-y-1\">",
  "new": "            <CardDescription>\n              Every event imported into this deployment, newest season first.\n              Deleted events show a snapshot from just before they were deleted.\n            </CardDescription>\n          </CardHeader>\n          <CardContent className=\"space-y-1\">\n            {seasons.length > 1 ? (\n              <div className=\"pb-2\">\n                <MenuSelect label=\"Season\" value={season} className=\"w-40\"\n                  options={[\n                    { value: \"all\", label: \"All seasons\" },\n                    ...seasons.map((s) => ({ value: String(s), label: `${s} season` })),\n                  ]}\n                  onChange={setSeason} />\n              </div>\n            ) : null}"
 },
 {
  "file": "src/routes/archive/index.tsx",
  "old": "            ) : events.length === 0 ? (\n              <p className=\"text-muted-foreground text-sm\">Nothing imported yet.</p>\n            ) : (\n              events.map((event) => (",
  "new": "            ) : events.length === 0 ? (\n              <p className=\"text-muted-foreground text-sm\">Nothing imported yet.</p>\n            ) : shown.length === 0 ? (\n              <p className=\"text-muted-foreground text-sm\">No events in the {season} season.</p>\n            ) : (\n              shown.map((event) => ("
 },
 {
  "file": "src/routes/archive/index.tsx",
  "old": "                  {event.isMine ? (",
  "new": "                  {event.deleted ? (\n                    <Badge variant=\"outline\" className=\"shrink-0 border-dashed\">\n                      Deleted\n                    </Badge>\n                  ) : null}\n                  {event.isMine ? ("
 },
 {
  "file": "src/routes/archive/event.tsx",
  "old": "        Archived data. These numbers are not from your current competition.\n      </div>",
  "new": "        Archived data. These numbers are not from your current competition.\n      </div>\n\n      {data.deleted ? (\n        <p className=\"text-muted-foreground rounded-lg border border-dashed p-3 text-sm\">\n          This event has been deleted.{\" \"}\n          {data.snapshotAt !== null\n            ? `Showing a snapshot taken ${new Date(data.snapshotAt).toLocaleString()}, just before it was deleted.`\n            : \"Showing its data until it is purged.\"}\n        </p>\n      ) : null}"
 },
 {
  "file": "src/routes/archive/index.tsx",
  "old": "                <Button key={event.eventKey} variant=\"outline\"\n                  className=\"h-auto w-full justify-start py-3\"",
  "new": "                <Button key={event.eventKey} variant=\"outline\"\n                  className=\"h-auto w-full justify-start py-3 whitespace-normal\""
 },
 {
  "file": "src/routes/archive/index.tsx",
  "old": "                    <span className=\"text-muted-foreground ml-2 text-xs\">",
  "new": "                    <span className=\"text-muted-foreground block text-xs sm:ml-2 sm:inline\">"
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
  1. bun run go        (creates the archiveSnapshots table)
  2. bun run typecheck
  3. Admin: delete a test event, check Past Events, recover it, check again.
TXT
