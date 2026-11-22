#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-practice-mode.sh
#   1. Practice mode toggle on My profile, in a card at the top of the right
#      column beside Name and team (under Account on narrow screens)
#   2. While it is on, match reports, pit reports and notes are saved to a
#      separate practiceSubmissions table, marked as practice, instead of the
#      real ones. They never reach stats, coverage, pick lists, the merge or
#      exports, because none of those read that table.
#   3. The practising scout can view their practice submissions on My profile
#      (and delete them), in a collapsible list
#   4. A red banner at the top of every page while practice mode is on, with a
#      disclaimer and an Exit practice mode button
#
# Anything else that would change real data is refused in practice mode with
# a clear message: editing a real match report and submitting a pick list.
# A photo taken during practice pit scouting is not kept.
#
# Schema: profiles.practiceMode (optional) and a new practiceSubmissions
# table. Works with or without the other patches applied.
#
# Every edit is checked before any file is written, so a mismatch stops the
# patch with nothing half-applied. CRLF checkouts are handled.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/pit.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

if grep -qF 'practiceSubmissions' convex/schema.ts; then
  # Already applied: bring an earlier version of this patch up to date.
  cat > ".patch-practice-mode-upgrade.json" <<'PATCH_UPGRADE_JSON'
[{"file": "src/routes/profile.tsx", "old": "      {/* Right of Account on wide screens; under it (before Role) when narrow. */}\n      <PracticeCard className=\"w-full max-w-md md:col-start-2 md:row-span-2 md:row-start-2\" />", "new": "      {/* Top of the right column, beside Name and team, on wide screens;\n          under Account (before Role) when narrow. */}\n      <PracticeCard className=\"w-full max-w-md md:col-start-2 md:row-span-3 md:row-start-1\" />"}, {"file": "src/components/practice-card.tsx", "old": "import { Eye, X } from \"lucide-react\";", "new": "import { ChevronRight, Eye, X } from \"lucide-react\";"}, {"file": "src/components/practice-card.tsx", "old": "  const [viewing, setViewing] = useState<Row | null>(null);", "new": "  const [viewing, setViewing] = useState<Row | null>(null);\n  // Collapsed by default, so a long practice history does not push the page down.\n  const [open, setOpen] = useState(false);"}, {"file": "src/components/practice-card.tsx", "old": "            <div className=\"flex items-center justify-between\">\n              <span className=\"text-sm font-medium\">Your practice submissions</span>\n              <Button size=\"sm\" variant=\"ghost\"", "new": "            <div className=\"flex items-center justify-between gap-2\">\n              <button type=\"button\" aria-expanded={open} aria-controls=\"practice-submissions\"\n                onClick={() => setOpen((o) => !o)}\n                className=\"hover:text-foreground flex min-h-8 items-center gap-1.5 text-left text-sm font-medium\">\n                <ChevronRight className={[\"size-4 shrink-0 transition-transform\", open ? \"rotate-90\" : \"\"].join(\" \")} />\n                Your practice submissions\n                <span className=\"text-muted-foreground font-normal tabular-nums\">({rows.length})</span>\n              </button>\n              <Button size=\"sm\" variant=\"ghost\""}, {"file": "src/components/practice-card.tsx", "old": "            <div className=\"max-h-72 space-y-1 overflow-y-auto\">", "new": "            {open ? (\n            <div id=\"practice-submissions\" className=\"max-h-72 space-y-1 overflow-y-auto\">"}, {"file": "src/components/practice-card.tsx", "old": "              ))}\n            </div>\n          </div>\n        ) : on ? (", "new": "              ))}\n            </div>\n            ) : null}\n          </div>\n        ) : on ? ("}]
PATCH_UPGRADE_JSON
  cat > ".patch-practice-mode-upgrade.mjs" <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
let changed = 0;
const updated = new Set();
for (const { file, old, new: next } of JSON.parse(readFileSync(process.argv[2], "utf8"))) {
  const raw = readFileSync(file, "utf8");
  const crlf = raw.includes("\r\n");
  const text = raw.replace(/\r\n/g, "\n");
  // Skip what is already up to date, so a re-run never applies twice.
  if (text.includes(next) || !text.includes(old)) continue;
  const out = text.replace(old, next);
  writeFileSync(file, crlf ? out.replace(/\n/g, "\r\n") : out);
  updated.add(file);
  changed += 1;
}
for (const file of updated) console.log(`${file} updated to the latest version of this patch`);
if (changed > 0) process.exit(10);
MJS
  set +e; bun ".patch-practice-mode-upgrade.mjs" ".patch-practice-mode-upgrade.json"; code=$?; set -e
  rm -f ".patch-practice-mode-upgrade.mjs" ".patch-practice-mode-upgrade.json"
  if [[ $code -eq 10 ]]; then echo "Updated. No need for bun run go unless the schema changed."; exit 0; fi
  if [[ $code -ne 0 ]]; then exit $code; fi
  echo "patch-practice-mode already applied."
  exit 0
fi
if ! grep -qF 'defineSchema' convex/schema.ts; then
  echo "ERROR: unexpected repo layout." >&2
  exit 1
fi

# Working files live in the repo root, not /tmp: on Windows, Git Bash's /tmp
# is not where bun looks for a "/tmp/..." path written inside a script.
JSON_FILE=".patch-practice-mode.json"
MJS_FILE=".patch-practice-mode.mjs"
trap 'rm -f "$JSON_FILE" "$MJS_FILE"' EXIT

say "Applying patch-practice-mode"
cat > "$JSON_FILE" <<'PATCH_EDITS_JSON'
[
 {
  "file": "convex/schema.ts",
  "old": "    weightTier: v.union(v.literal(\"lead\"), v.literal(\"trusted\"), v.literal(\"normal\")),\n    createdAt: v.number(),\n  }).index(\"by_user\", [\"userId\"]),",
  "new": "    weightTier: v.union(v.literal(\"lead\"), v.literal(\"trusted\"), v.literal(\"normal\")),\n    createdAt: v.number(),\n    /** While true, scouting submissions go to practiceSubmissions instead. */\n    practiceMode: v.optional(v.boolean()),\n  }).index(\"by_user\", [\"userId\"]),\n\n  /**\n   * What a scout submitted in practice mode. Kept apart from the real tables\n   * on purpose: nothing that computes stats, coverage, pick lists or exports\n   * reads this table, so practice cannot leak into real numbers. payload is\n   * the submission as sent, as JSON. One row per thing practised; doing the\n   * same robot again replaces it.\n   */\n  practiceSubmissions: defineTable({\n    userId: v.id(\"users\"),\n    eventId: v.id(\"events\"),\n    kind: v.union(\n      v.literal(\"match\"), v.literal(\"pit\"), v.literal(\"pitNote\"), v.literal(\"matchNote\"),\n    ),\n    teamNumber: v.number(),\n    matchNumber: v.union(v.number(), v.null()),\n    payload: v.string(),\n    submittedAt: v.number(),\n  })\n    .index(\"by_user\", [\"userId\"])\n    .index(\"by_user_target\", [\"userId\", \"kind\", \"eventId\", \"teamNumber\", \"matchNumber\"]),"
 },
 {
  "file": "convex/lib/practice.ts",
  "old": null,
  "new": "import { ConvexError } from \"convex/values\";\nimport type { MutationCtx, QueryCtx } from \"../_generated/server\";\nimport { activeEvent, currentProfile } from \"./guards\";\n\nexport type PracticeKind = \"match\" | \"pit\" | \"pitNote\" | \"matchNote\";\n\n/** Whether the signed-in scout has practice mode on. */\nexport async function isPracticing(ctx: QueryCtx | MutationCtx): Promise<boolean> {\n  return (await currentProfile(ctx))?.practiceMode === true;\n}\n\n/**\n * For actions that would change real data and have no practice version.\n * A ConvexError so the message reaches the scout in production.\n */\nexport async function refuseInPractice(ctx: QueryCtx | MutationCtx, message: string) {\n  if (await isPracticing(ctx)) throw new ConvexError(message);\n}\n\n/** Saves a practice submission in place of the real one. */\nexport async function savePractice(\n  ctx: MutationCtx,\n  row: { kind: PracticeKind; teamNumber: number; matchNumber: number | null; payload: unknown },\n): Promise<null> {\n  const profile = await currentProfile(ctx);\n  if (!profile) throw new Error(\"No profile for this user.\");\n  const event = await activeEvent(ctx);\n  if (!event) throw new Error(\"No active event.\");\n\n  const existing = await ctx.db\n    .query(\"practiceSubmissions\")\n    .withIndex(\"by_user_target\", (q) =>\n      q.eq(\"userId\", profile.userId).eq(\"kind\", row.kind).eq(\"eventId\", event._id)\n        .eq(\"teamNumber\", row.teamNumber).eq(\"matchNumber\", row.matchNumber))\n    .first();\n  const fields = { payload: JSON.stringify(row.payload), submittedAt: Date.now() };\n  if (existing) {\n    await ctx.db.patch(existing._id, fields);\n  } else {\n    await ctx.db.insert(\"practiceSubmissions\", {\n      userId: profile.userId,\n      eventId: event._id,\n      kind: row.kind,\n      teamNumber: row.teamNumber,\n      matchNumber: row.matchNumber,\n      ...fields,\n    });\n  }\n  return null;\n}\n"
 },
 {
  "file": "convex/practice.ts",
  "old": null,
  "new": "import { v } from \"convex/values\";\nimport { mutation, query } from \"./_generated/server\";\nimport { currentProfile, requireUser } from \"./lib/guards\";\n\n/** Whether the signed-in scout is in practice mode. False when signed out. */\nexport const status = query({\n  args: {},\n  handler: async (ctx) => {\n    const profile = await currentProfile(ctx);\n    return { on: profile?.practiceMode === true };\n  },\n});\n\nexport const setMode = mutation({\n  args: { on: v.boolean() },\n  handler: async (ctx, args) => {\n    await requireUser(ctx);\n    const profile = await currentProfile(ctx);\n    if (!profile) throw new Error(\"Set up your profile first.\");\n    await ctx.db.patch(profile._id, { practiceMode: args.on });\n  },\n});\n\n/** Your own practice submissions, newest first. Nobody else can read them. */\nexport const mine = query({\n  args: {},\n  handler: async (ctx) => {\n    const userId = await requireUser(ctx);\n    const rows = await ctx.db\n      .query(\"practiceSubmissions\")\n      .withIndex(\"by_user\", (q) => q.eq(\"userId\", userId))\n      .collect();\n    const eventNames = new Map<string, string>();\n    for (const row of rows) {\n      if (eventNames.has(row.eventId)) continue;\n      const event = await ctx.db.get(row.eventId);\n      eventNames.set(row.eventId, event?.name ?? \"Deleted event\");\n    }\n    return rows\n      .sort((a, b) => b.submittedAt - a.submittedAt)\n      .map((row) => ({\n        _id: row._id,\n        kind: row.kind,\n        teamNumber: row.teamNumber,\n        matchNumber: row.matchNumber,\n        eventName: eventNames.get(row.eventId) ?? \"\",\n        payload: row.payload,\n        submittedAt: row.submittedAt,\n      }));\n  },\n});\n\nexport const remove = mutation({\n  args: { id: v.id(\"practiceSubmissions\") },\n  handler: async (ctx, args) => {\n    const userId = await requireUser(ctx);\n    const row = await ctx.db.get(args.id);\n    if (!row || row.userId !== userId) return;\n    await ctx.db.delete(args.id);\n  },\n});\n\nexport const clear = mutation({\n  args: {},\n  handler: async (ctx) => {\n    const userId = await requireUser(ctx);\n    const rows = await ctx.db\n      .query(\"practiceSubmissions\")\n      .withIndex(\"by_user\", (q) => q.eq(\"userId\", userId))\n      .collect();\n    for (const row of rows) await ctx.db.delete(row._id);\n    return { removed: rows.length };\n  },\n});\n"
 },
 {
  "file": "convex/matchReports.ts",
  "old": "import { mine as myPitReport } from \"./pit\";",
  "new": "import { mine as myPitReport } from \"./pit\";\nimport { isPracticing, refuseInPractice, savePractice } from \"./lib/practice\";"
 },
 {
  "file": "convex/matchReports.ts",
  "old": "    const myReport = existing.find((r) => r.scoutId === userId) ?? null;",
  "new": "    // In practice mode a robot can be practised again, even one already\n    // reported for real; the real report is not touched either way.\n    const myReport = (await isPracticing(ctx))\n      ? null\n      : (existing.find((r) => r.scoutId === userId) ?? null);"
 },
 {
  "file": "convex/matchReports.ts",
  "old": "    const { matchId, teamId, ...rest } = args;\n    const now = Date.now();",
  "new": "    // Practice: same checks as above, then saved for the scout only.\n    if (await isPracticing(ctx)) {\n      const [match, team] = await Promise.all([ctx.db.get(args.matchId), ctx.db.get(args.teamId)]);\n      if (!match || !team) throw new Error(\"That match or team is not at the active event.\");\n      return await savePractice(ctx, {\n        kind: \"match\", teamNumber: team.number, matchNumber: match.matchNumber, payload: args,\n      });\n    }\n\n    const { matchId, teamId, ...rest } = args;\n    const now = Date.now();"
 },
 {
  "file": "convex/matchReports.ts",
  "old": "    const reason = args.reason.trim();\n    if (reason === \"\") throw new Error(\"An edit reason is required.\");",
  "new": "    await refuseInPractice(ctx, \"Real reports cannot be edited in practice mode. Exit practice mode first.\");\n    const reason = args.reason.trim();\n    if (reason === \"\") throw new Error(\"An edit reason is required.\");"
 },
 {
  "file": "convex/pit.ts",
  "old": "import type { QueryCtx, MutationCtx } from \"./_generated/server\";",
  "new": "import type { QueryCtx, MutationCtx } from \"./_generated/server\";\nimport { isPracticing, savePractice } from \"./lib/practice\";"
 },
 {
  "file": "convex/pit.ts",
  "old": "    const report = await mine(ctx, event._id, team._id);\n    const photoUrl = report?.photoId ? await ctx.storage.getUrl(report.photoId) : null;",
  "new": "    // Practice starts from a blank form, not the team's real report.\n    const report = (await isPracticing(ctx)) ? null : await mine(ctx, event._id, team._id);\n    const photoUrl = report?.photoId ? await ctx.storage.getUrl(report.photoId) : null;"
 },
 {
  "file": "convex/pit.ts",
  "old": "    const scoutId = await requireUser(ctx);\n    const event = await activeEvent(ctx);\n    if (!event) throw new Error(\"No active event.\");\n",
  "new": "    const scoutId = await requireUser(ctx);\n    const event = await activeEvent(ctx);\n    if (!event) throw new Error(\"No active event.\");\n\n    if (await isPracticing(ctx)) {\n      const team = await ctx.db.get(args.teamId);\n      if (!team || team.eventId !== event._id) {\n        throw new Error(\"That team is not part of the active event.\");\n      }\n      // A practice photo is not kept.\n      if (args.photoId) await ctx.storage.delete(args.photoId);\n      return await savePractice(ctx, {\n        kind: \"pit\", teamNumber: team.number, matchNumber: null, payload: { ...args, photoId: null },\n      });\n    }\n"
 },
 {
  "file": "convex/notes.ts",
  "old": "import type { Doc, Id } from \"./_generated/dataModel\";",
  "new": "import type { Doc, Id } from \"./_generated/dataModel\";\nimport { isPracticing, savePractice } from \"./lib/practice\";"
 },
 {
  "file": "convex/notes.ts",
  "old": "export const savePit = mutation({\n  args: { teamNumber: v.number(), notes: v.string() },\n  handler: async (ctx, args) => {\n    const scoutId = await requireUser(ctx);",
  "new": "export const savePit = mutation({\n  args: { teamNumber: v.number(), notes: v.string() },\n  handler: async (ctx, args) => {\n    const scoutId = await requireUser(ctx);\n    if (await isPracticing(ctx)) {\n      return await savePractice(ctx, {\n        kind: \"pitNote\", teamNumber: args.teamNumber, matchNumber: null, payload: { notes: args.notes },\n      });\n    }"
 },
 {
  "file": "convex/notes.ts",
  "old": "export const saveMatch = mutation({\n  args: { matchNumber: v.number(), teamNumber: v.number(), notes: v.string() },\n  handler: async (ctx, args) => {\n    const scoutId = await requireUser(ctx);",
  "new": "export const saveMatch = mutation({\n  args: { matchNumber: v.number(), teamNumber: v.number(), notes: v.string() },\n  handler: async (ctx, args) => {\n    const scoutId = await requireUser(ctx);\n    if (await isPracticing(ctx)) {\n      return await savePractice(ctx, {\n        kind: \"matchNote\", teamNumber: args.teamNumber, matchNumber: args.matchNumber,\n        payload: { notes: args.notes },\n      });\n    }"
 },
 {
  "file": "convex/pickLists.ts",
  "old": "import type { Doc, Id } from \"./_generated/dataModel\";",
  "new": "import type { Doc, Id } from \"./_generated/dataModel\";\nimport { refuseInPractice } from \"./lib/practice\";"
 },
 {
  "file": "convex/pickLists.ts",
  "old": "export const setSubmitted = mutation({\n  args: { listId: v.id(\"pickLists\") },\n  handler: async (ctx, args) => {\n    const userId = await requireUser(ctx);",
  "new": "export const setSubmitted = mutation({\n  args: { listId: v.id(\"pickLists\") },\n  handler: async (ctx, args) => {\n    const userId = await requireUser(ctx);\n    await refuseInPractice(ctx, \"Pick lists cannot be submitted in practice mode.\");"
 },
 {
  "file": "src/components/practice-banner.tsx",
  "old": null,
  "new": "import { useMutation, useQuery } from \"convex/react\";\nimport { FlaskConical } from \"lucide-react\";\nimport { toast } from \"sonner\";\n\nimport { api } from \"../../convex/_generated/api\";\nimport { Button } from \"@/components/ui/button\";\n\n/** Red strip on every page while practice mode is on. */\nexport function PracticeBanner() {\n  const status = useQuery(api.practice.status);\n  const setMode = useMutation(api.practice.setMode);\n  if (!status?.on) return null;\n\n  return (\n    // A fixed dark red: the theme's destructive colour is too light under\n    // white text in dark mode.\n    <div role=\"status\" className=\"bg-red-700 text-white dark:bg-red-800\">\n      <div className=\"mx-auto flex w-full max-w-6xl flex-wrap items-center gap-x-4 gap-y-2 px-4 py-2\">\n        <FlaskConical className=\"size-4 shrink-0\" />\n        <p className=\"min-w-0 flex-1 text-sm\">\n          <strong>Practice mode.</strong> Nothing you submit counts. It is\n          saved only for you, marked as practice.\n        </p>\n        <Button size=\"sm\" variant=\"outline\"\n          className=\"border-white/70 bg-transparent text-white hover:bg-white/15 hover:text-white\"\n          onClick={() => {\n            void setMode({ on: false })\n              .then(() => toast.success(\"Practice mode off. Submissions count again.\"))\n              .catch(() => toast.error(\"Could not exit practice mode\"));\n          }}>\n          Exit practice mode\n        </Button>\n      </div>\n    </div>\n  );\n}\n"
 },
 {
  "file": "src/routes/app-layout.tsx",
  "old": "import { AppNav } from \"@/components/app-nav\";",
  "new": "import { AppNav } from \"@/components/app-nav\";\nimport { PracticeBanner } from \"@/components/practice-banner\";"
 },
 {
  "file": "src/routes/app-layout.tsx",
  "old": "      <AppNav />",
  "new": "      {/* Sticky together, so the banner stays on screen with the nav. */}\n      <div className=\"sticky top-0 z-40\">\n        <PracticeBanner />\n        <AppNav />\n      </div>"
 },
 {
  "file": "src/components/practice-card.tsx",
  "old": null,
  "new": "import { useMutation, useQuery } from \"convex/react\";\nimport { ChevronRight, Eye, X } from \"lucide-react\";\nimport { useState } from \"react\";\nimport { toast } from \"sonner\";\n\nimport { api } from \"../../convex/_generated/api\";\nimport type { Id } from \"../../convex/_generated/dataModel\";\nimport { Badge } from \"@/components/ui/badge\";\nimport { Button } from \"@/components/ui/button\";\nimport {\n  Card, CardContent, CardDescription, CardHeader, CardTitle,\n} from \"@/components/ui/card\";\nimport {\n  Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle,\n} from \"@/components/ui/dialog\";\nimport { Switch } from \"@/components/ui/switch\";\n\ntype Kind = \"match\" | \"pit\" | \"pitNote\" | \"matchNote\";\ntype Row = {\n  _id: Id<\"practiceSubmissions\">;\n  kind: Kind;\n  teamNumber: number;\n  matchNumber: number | null;\n  eventName: string;\n  payload: string;\n  submittedAt: number;\n};\n\n// ─── reading a stored payload safely ──────────────────────────────────────\ntype Obj = Record<string, unknown>;\nconst obj = (x: unknown): Obj => (x !== null && typeof x === \"object\" ? (x as Obj) : {});\nconst numAt = (x: unknown): number | null => (typeof x === \"number\" ? x : null);\nconst strAt = (x: unknown): string => (typeof x === \"string\" ? x.trim() : \"\");\nconst yes = (x: unknown) => x === true;\n\nfunction title(row: Row): string {\n  switch (row.kind) {\n    case \"match\": return `Qual ${row.matchNumber ?? \"?\"} · ${row.teamNumber}`;\n    case \"pit\": return `Pit · ${row.teamNumber}`;\n    case \"pitNote\": return `Pit note · ${row.teamNumber}`;\n    case \"matchNote\": return `Match note · Qual ${row.matchNumber ?? \"?\"} · ${row.teamNumber}`;\n  }\n}\n\n/** The fields a scout would want to check, as label/value pairs. */\nfunction summary(row: Row): Array<[string, string]> {\n  let p: Obj;\n  try { p = obj(JSON.parse(row.payload)); } catch { return [[\"Data\", \"Could not read this submission.\"]]; }\n  const out: Array<[string, string]> = [];\n  const add = (label: string, value: string | number | null) => {\n    if (value !== null && value !== \"\") out.push([label, String(value)]);\n  };\n\n  if (row.kind === \"pitNote\" || row.kind === \"matchNote\") {\n    add(\"Notes\", strAt(p.notes) || \"(empty)\");\n    return out;\n  }\n\n  if (row.kind === \"match\") {\n    const auto = obj(p.auto);\n    const teleop = obj(p.teleop);\n    const endgame = obj(p.endgame);\n    const ratings = obj(p.ratings);\n    const byShift = Object.values(obj(teleop.byShift)).reduce<number>(\n      (sum, n) => sum + (numAt(n) ?? 0), 0);\n    add(\"Auto fuel\", numAt(auto.fuel));\n    add(\"Auto fouls\", numAt(auto.fouls));\n    add(\"Auto winner\", strAt(p.autoWinner));\n    add(\"Teleop fuel\", byShift);\n    add(\"Passed\", (numAt(teleop.passedNeutral) ?? 0) + (numAt(teleop.passedFullField) ?? 0));\n    add(\"Stole fuel\", numAt(teleop.stoleFuel));\n    add(\"Defended\", yes(teleop.defended) ? \"Yes\" : \"No\");\n    add(\"Climb\", strAt(endgame.climb));\n    add(\"Driver\", numAt(ratings.driver));\n    add(\"Defense\", numAt(ratings.defense));\n    const accuracy = numAt(ratings.accuracy);\n    add(\"Accuracy\", accuracy === null ? null : `${accuracy}%`);\n    add(\"Avg BPS\", numAt(p.avgBps));\n    if (yes(ratings.broke)) add(\"Broke down\", strAt(ratings.brokeNotes) || \"Yes\");\n    if (yes(ratings.inconsistent)) add(\"Inconsistent\", strAt(ratings.inconsistentNotes) || \"Yes\");\n    add(\"Auto notes\", strAt(auto.notes));\n    add(\"Teleop notes\", strAt(teleop.notes));\n    add(\"Final notes\", strAt(p.finalNotes));\n    return out;\n  }\n\n  // Pit report.\n  const scoring = obj(p.scoring);\n  const climb = obj(p.climb);\n  const hopper = obj(p.hopper);\n  const shooters = [\n    yes(scoring.turret) ? \"Turret\" : null,\n    yes(scoring.drumFullWidth) ? \"Full-width drum\" : null,\n    yes(scoring.drumNonFullWidth) ? \"Drum\" : null,\n    yes(scoring.fixed) ? \"Fixed shooter\" : null,\n    yes(scoring.kitbot) ? \"Kitbot\" : null,\n    yes(scoring.other) ? (strAt(scoring.otherText) || \"Other\") : null,\n  ].filter((s): s is string => s !== null);\n  const climbs = [\n    yes(climb.low) ? \"L1\" : null, yes(climb.mid) ? \"L2\" : null, yes(climb.high) ? \"L3\" : null,\n    yes(climb.duringAuto) ? \"auto\" : null,\n  ].filter((s): s is string => s !== null);\n  add(\"Scoring\", shooters.join(\", \") || \"None ticked\");\n  add(\"Hopper\", [strAt(hopper.roof), numAt(hopper.capacity)].filter((s) => s !== \"\" && s !== null).join(\", \"));\n  add(\"Climb\", climbs.join(\", \") || \"None ticked\");\n  add(\"Drivetrain\", strAt(p.drivetrain));\n  add(\"Gearing\", strAt(p.drivetrainGearing));\n  const weight = numAt(p.robotWeight);\n  add(\"Weight\", weight === null ? null : `${weight} lbs`);\n  add(\"Under trench\", yes(p.underTrench) ? \"Yes\" : \"No\");\n  add(\"Over bump\", yes(p.overBump) ? \"Yes\" : \"No\");\n  const spares = Array.isArray(p.spares) ? p.spares.length : 0;\n  const batteries = Array.isArray(p.batteries) ? p.batteries.length : 0;\n  if (spares > 0) add(\"Spares listed\", spares);\n  if (batteries > 0) add(\"Battery rows\", batteries);\n  add(\"Robot notes\", strAt(p.robotNotes));\n  add(\"Other notes\", strAt(p.otherNotes));\n  return out;\n}\n\nexport function PracticeCard({ className = \"\" }: { className?: string }) {\n  const status = useQuery(api.practice.status);\n  const rows = useQuery(api.practice.mine);\n  const setMode = useMutation(api.practice.setMode);\n  const remove = useMutation(api.practice.remove);\n  const clear = useMutation(api.practice.clear);\n  const [viewing, setViewing] = useState<Row | null>(null);\n  // Collapsed by default, so a long practice history does not push the page down.\n  const [open, setOpen] = useState(false);\n  const on = status?.on ?? false;\n\n  return (\n    <Card className={className}>\n      <CardHeader>\n        <CardTitle>Practice mode</CardTitle>\n        <CardDescription>\n          Scout for practice without touching real data. While it is on,\n          match reports, pit reports and notes you submit are saved only for\n          you, marked as practice.\n        </CardDescription>\n      </CardHeader>\n      <CardContent className=\"space-y-4\">\n        <label className=\"flex cursor-pointer items-center justify-between gap-3 rounded-lg border p-3\">\n          <span className=\"text-sm font-medium\">{on ? \"Practice mode is on\" : \"Practice mode is off\"}</span>\n          <Switch checked={on} disabled={status === undefined}\n            onCheckedChange={(next: boolean) => {\n              void setMode({ on: next })\n                .then(() => toast.success(next\n                  ? \"Practice mode on. Nothing you submit will count.\"\n                  : \"Practice mode off. Submissions count again.\"))\n                .catch(() => toast.error(\"Could not change practice mode\"));\n            }} />\n        </label>\n\n        {rows && rows.length > 0 ? (\n          <div className=\"space-y-2\">\n            <div className=\"flex items-center justify-between gap-2\">\n              <button type=\"button\" aria-expanded={open} aria-controls=\"practice-submissions\"\n                onClick={() => setOpen((o) => !o)}\n                className=\"hover:text-foreground flex min-h-8 items-center gap-1.5 text-left text-sm font-medium\">\n                <ChevronRight className={[\"size-4 shrink-0 transition-transform\", open ? \"rotate-90\" : \"\"].join(\" \")} />\n                Your practice submissions\n                <span className=\"text-muted-foreground font-normal tabular-nums\">({rows.length})</span>\n              </button>\n              <Button size=\"sm\" variant=\"ghost\"\n                onClick={() => {\n                  void clear({}).then((r) => toast.success(`Cleared ${r.removed} practice submissions`));\n                }}>\n                Clear all\n              </Button>\n            </div>\n            {open ? (\n            <div id=\"practice-submissions\" className=\"max-h-72 space-y-1 overflow-y-auto\">\n              {rows.map((row) => (\n                <div key={row._id} className=\"flex items-center gap-2 rounded-lg border p-2\">\n                  <Badge variant=\"outline\" className=\"border-destructive/60 text-destructive shrink-0\">\n                    Practice\n                  </Badge>\n                  <div className=\"min-w-0 flex-1\">\n                    <p className=\"truncate text-sm\">{title(row)}</p>\n                    <p className=\"text-muted-foreground truncate text-xs\">\n                      {row.eventName} · {new Date(row.submittedAt).toLocaleString()}\n                    </p>\n                  </div>\n                  <Button size=\"icon\" variant=\"ghost\" className=\"size-8\"\n                    aria-label={`View ${title(row)}`} onClick={() => setViewing(row)}>\n                    <Eye className=\"size-4\" />\n                  </Button>\n                  <Button size=\"icon\" variant=\"ghost\" className=\"size-8\"\n                    aria-label={`Delete ${title(row)}`}\n                    onClick={() => void remove({ id: row._id })}>\n                    <X className=\"size-4\" />\n                  </Button>\n                </div>\n              ))}\n            </div>\n            ) : null}\n          </div>\n        ) : on ? (\n          <p className=\"text-muted-foreground text-sm\">\n            Nothing submitted in practice yet.\n          </p>\n        ) : null}\n      </CardContent>\n\n      <Dialog open={viewing !== null} onOpenChange={(next) => { if (!next) setViewing(null); }}>\n        <DialogContent className=\"max-w-sm\">\n          {viewing ? (\n            <>\n              <DialogHeader>\n                <DialogTitle className=\"flex items-center gap-2\">\n                  {title(viewing)}\n                  <Badge variant=\"outline\" className=\"border-destructive/60 text-destructive\">Practice</Badge>\n                </DialogTitle>\n                <DialogDescription>\n                  {viewing.eventName} · {new Date(viewing.submittedAt).toLocaleString()}.\n                  Not part of any real data.\n                </DialogDescription>\n              </DialogHeader>\n              <dl className=\"grid max-h-[60vh] grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1.5 overflow-y-auto text-sm\">\n                {summary(viewing).map(([label, value]) => (\n                  <div key={label} className=\"contents\">\n                    <dt className=\"text-muted-foreground\">{label}</dt>\n                    <dd className=\"break-words\">{value}</dd>\n                  </div>\n                ))}\n              </dl>\n            </>\n          ) : null}\n        </DialogContent>\n      </Dialog>\n    </Card>\n  );\n}\n"
 },
 {
  "file": "src/routes/profile.tsx",
  "old": "      <Card className=\"max-w-md\">\n        <CardHeader>\n          <CardTitle>Account</CardTitle>",
  "new": "      <Card className=\"w-full max-w-md md:col-start-1\">\n        <CardHeader>\n          <CardTitle>Account</CardTitle>"
 },
 {
  "file": "src/routes/profile.tsx",
  "old": "      {email ? <AccountSecurity email={email} /> : null}",
  "new": "      {email ? <AccountSecurity email={email} /> : null}\n\n      {/* Top of the right column, beside Name and team, on wide screens;\n          under Account (before Role) when narrow. */}\n      <PracticeCard className=\"w-full max-w-md md:col-start-2 md:row-span-3 md:row-start-1\" />"
 },
 {
  "file": "src/routes/profile.tsx",
  "old": "    <PageShell\n      title=\"My profile\"\n      description=\"How you appear on every report you submit.\"\n    >\n      <Card className=\"max-w-md\">\n        <CardHeader>\n          <CardTitle>Name and team</CardTitle>",
  "new": "    <PageShell\n      title=\"My profile\"\n      description=\"How you appear on every report you submit.\"\n    >\n      {/* Two columns from md up. The last row is 1fr so a tall Practice card\n          does not open a gap between Account and Role. */}\n      <div className=\"grid items-start gap-6 md:grid-cols-[minmax(0,28rem)_minmax(0,28rem)] md:grid-rows-[auto_auto_1fr]\">\n      <Card className=\"w-full max-w-md md:col-start-1\">\n        <CardHeader>\n          <CardTitle>Name and team</CardTitle>"
 },
 {
  "file": "src/routes/profile.tsx",
  "old": "      <Card className=\"max-w-md\">\n        <CardHeader>\n          <CardTitle>Role</CardTitle>",
  "new": "      <Card className=\"w-full max-w-md md:col-start-1\">\n        <CardHeader>\n          <CardTitle>Role</CardTitle>"
 },
 {
  "file": "src/routes/profile.tsx",
  "old": "      </Card>\n    </PageShell>\n  );\n}",
  "new": "      </Card>\n      </div>\n    </PageShell>\n  );\n}"
 },
 {
  "file": "src/routes/profile.tsx",
  "old": "export default function ProfilePage() {",
  "new": "import { PracticeCard } from \"@/components/practice-card\";\n\nexport default function ProfilePage() {"
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
  1. bun run go        (creates the practiceSubmissions table)
  2. bun run typecheck
  3. My profile: turn on Practice mode, scout a match, then check the
     banner and the practice list on My profile.
TXT
