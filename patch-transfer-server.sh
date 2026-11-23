#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-transfer-server.sh — data transfer plan, patch 6: the server side
#   1. New table transferReceipts: one row per report that arrives from a
#      device's outbox. The id is made on the device, so the same report sent
#      twice, by any route, is written once.
#   2. New functions:
#        transfer.send      sends one held report for the signed-in scout.
#                           Answers accepted, or received when the server
#                           already had it. A refusal carries its reason.
#        transfer.receipts  which of the caller's held ids the server has.
#      Nothing in the app calls them yet. Patch 7 (the outbox) does.
#   3. The four saves a form can hold offline now run through shared
#      functions that take the author as an argument:
#        matchReports.submit    -> writeMatchReport
#        pit.upsert             -> writePitReport
#        notes.saveMatchReport  -> writeGenericMatch
#        notes.savePitReport    -> writeGenericPit
#      The mutations keep their names, arguments and behaviour. Practice
#      mode is decided for the author.
#   4. A held report was filled in without seeing what is stored, so when it
#      meets an existing pit report or note its blank fields keep the stored
#      answers (plan section 4.5). Where both have an answer the later write
#      wins. A save made online is unchanged: a blank there still clears.
#   5. A held report is refused if its author's team has moved to a
#      different event since it was saved.
#   6. Receipts are removed with their event (purge) and with their author's
#      account.
#
# Convex only: no page, no client code and no dependency changes.
# Additive: no existing table, function or argument changes, so phones on
# the current bundle keep working. Safe to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f vite.config.ts && -f convex/auth.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
[[ -f convex/lib/practice.ts && -f convex/notes.ts && -f convex/pit.ts ]] || {
  echo "ERROR: this repo is older than the patch expects; nothing was changed" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# ---- 1. Check everything before writing anything --------------------------
say "Checking"
trap 'rm -f .patch-transfer-server.mjs .patch-transfer-server.json' EXIT
cat > .patch-transfer-server.json <<'EOF_JSON'
{
 "convex/lib/guards.ts": {
  "marker": "export async function activeEventOf(",
  "edits": [
   {
    "old": "\nexport async function requireActiveEvent(",
    "new": "\n/**\n * A given user's profile, team and event. The versions above read the caller\n * from the session; these take the user as an argument, for a report that is\n * written on its author's behalf (convex/lib/transfer.ts).\n */\nexport async function profileOf(\n  ctx: QueryCtx | MutationCtx,\n  userId: Id<\"users\">,\n): Promise<Doc<\"profiles\"> | null> {\n  return await ctx.db\n    .query(\"profiles\")\n    .withIndex(\"by_user\", (q) => q.eq(\"userId\", userId))\n    .unique();\n}\n\nexport async function teamNumberOf(\n  ctx: QueryCtx | MutationCtx,\n  userId: Id<\"users\">,\n): Promise<number | undefined> {\n  return effectiveTeamNumber(await profileOf(ctx, userId));\n}\n\nexport async function activeEventOf(\n  ctx: QueryCtx | MutationCtx,\n  userId: Id<\"users\">,\n): Promise<Doc<\"events\"> | null> {\n  const teamNumber = await teamNumberOf(ctx, userId);\n  if (teamNumber === undefined) return null;\n  return await activeEventForTeam(ctx, teamNumber);\n}\n\nexport async function requireActiveEvent("
   }
  ]
 },
 "convex/lib/practice.ts": {
  "marker": "export async function savePracticeAs(",
  "edits": [
   {
    "old": "import { activeEvent, currentProfile } from \"./guards\";",
    "new": "import type { Id } from \"../_generated/dataModel\";\nimport { activeEvent, activeEventOf, currentProfile, profileOf } from \"./guards\";"
   },
   {
    "old": "\n/** Saves a practice submission in place of the real one. */",
    "new": "\n/** Whether a given scout has practice mode on. */\nexport async function isPracticingAs(\n  ctx: QueryCtx | MutationCtx,\n  userId: Id<\"users\">,\n): Promise<boolean> {\n  return (await profileOf(ctx, userId))?.practiceMode === true;\n}\n\ntype PracticeRow = {\n  kind: PracticeKind; teamNumber: number; matchNumber: number | null; payload: unknown;\n};\n\n/** Saves a practice submission in place of the real one. */"
   },
   {
    "old": "export async function savePractice(\n  ctx: MutationCtx,\n  row: { kind: PracticeKind; teamNumber: number; matchNumber: number | null; payload: unknown },\n): Promise<null> {",
    "new": "export async function savePractice(ctx: MutationCtx, row: PracticeRow): Promise<null> {"
   },
   {
    "old": "  if (!event) throw new Error(\"No active event.\");\n",
    "new": "  if (!event) throw new Error(\"No active event.\");\n  return await storePractice(ctx, profile.userId, event._id, row);\n}\n\n/** The same, for a given scout: practice is decided by who wrote the report. */\nexport async function savePracticeAs(\n  ctx: MutationCtx,\n  userId: Id<\"users\">,\n  row: PracticeRow,\n): Promise<null> {\n  const event = await activeEventOf(ctx, userId);\n  if (!event) throw new Error(\"No active event.\");\n  return await storePractice(ctx, userId, event._id, row);\n}\n\nasync function storePractice(\n  ctx: MutationCtx,\n  userId: Id<\"users\">,\n  eventId: Id<\"events\">,\n  row: PracticeRow,\n): Promise<null> {\n"
   },
   {
    "old": "      q.eq(\"userId\", profile.userId).eq(\"kind\", row.kind).eq(\"eventId\", event._id)",
    "new": "      q.eq(\"userId\", userId).eq(\"kind\", row.kind).eq(\"eventId\", eventId)"
   },
   {
    "old": "      userId: profile.userId,\n      eventId: event._id,",
    "new": "      userId,\n      eventId,"
   }
  ]
 },
 "convex/matchReports.ts": {
  "marker": "export async function writeMatchReport(",
  "edits": [
   {
    "old": "import { v } from \"convex/values\";",
    "new": "import { v, type ObjectType } from \"convex/values\";"
   },
   {
    "old": "import { activeEvent, requireUser } from \"./lib/guards\";",
    "new": "import type { MutationCtx } from \"./_generated/server\";\nimport type { Id } from \"./_generated/dataModel\";\nimport { activeEvent, activeEventOf, requireUser } from \"./lib/guards\";"
   },
   {
    "old": "import { isPracticing, refuseInPractice, savePractice } from \"./lib/practice\";",
    "new": "import { isPracticing, isPracticingAs, refuseInPractice, savePracticeAs } from \"./lib/practice\";"
   },
   {
    "old": "export const submit = mutation({\n  args: { matchId: v.id(\"matches\"), teamId: v.id(\"teams\"), ...reportInput },\n  handler: async (ctx, args) => {\n    const scoutId = await requireUser(ctx);\n    const event = await activeEvent(ctx);",
    "new": "export const submitArgs = { matchId: v.id(\"matches\"), teamId: v.id(\"teams\"), ...reportInput };\n\n/**\n * Writes one match report for the given scout. The only place a match report\n * is created: matchReports.submit calls it for the signed-in scout, and a\n * report held offline arrives through convex/lib/transfer.ts. Everything a\n * new report must update (the count, the team summary, both tallies) is here,\n * so no route can skip it.\n */\nexport async function writeMatchReport(\n  ctx: MutationCtx,\n  scoutId: Id<\"users\">,\n  args: ObjectType<typeof submitArgs>,\n) {\n    const event = await activeEventOf(ctx, scoutId);"
   },
   {
    "old": "    if (await isPracticing(ctx)) {",
    "new": "    if (await isPracticingAs(ctx, scoutId)) {"
   },
   {
    "old": "      return await savePractice(ctx, {",
    "new": "      return await savePracticeAs(ctx, scoutId, {"
   },
   {
    "old": "    return reportId;\n  },\n});",
    "new": "    return reportId;\n}\n\nexport const submit = mutation({\n  args: submitArgs,\n  handler: async (ctx, args) => await writeMatchReport(ctx, await requireUser(ctx), args),\n});"
   }
  ]
 },
 "convex/pit.ts": {
  "marker": "export async function writePitReport(",
  "edits": [
   {
    "old": "import { v, type Infer } from \"convex/values\";",
    "new": "import { v, type Infer, type ObjectType } from \"convex/values\";"
   },
   {
    "old": "import { activeEvent, currentTeamNumber, requireUser } from \"./lib/guards\";",
    "new": "import {\n  activeEvent, activeEventOf, currentTeamNumber, requireUser, teamNumberOf,\n} from \"./lib/guards\";"
   },
   {
    "old": "import { isPracticing, savePractice } from \"./lib/practice\";",
    "new": "import { isPracticing, isPracticingAs, savePracticeAs } from \"./lib/practice\";"
   },
   {
    "old": "  if (scoutingTeamNumber === undefined) return null;\n\n  const rows = await ctx.db",
    "new": "  if (scoutingTeamNumber === undefined) return null;\n  return await reportFor(ctx, eventId, teamId, scoutingTeamNumber);\n}\n\n/** A given scouting team's report on a robot. */\nasync function reportFor(\n  ctx: QueryCtx | MutationCtx,\n  eventId: Id<\"events\">,\n  teamId: Id<\"teams\">,\n  scoutingTeamNumber: number,\n): Promise<Doc<\"pitReports\"> | null> {\n  const rows = await ctx.db"
   },
   {
    "old": "export const upsert = mutation({\n  args: {",
    "new": "export const upsertArgs = {"
   },
   {
    "old": "  },\n  handler: async (ctx, args) => {\n    const scoutId = await requireUser(ctx);\n    const event = await activeEvent(ctx);",
    "new": "};\ntype UpsertArgs = ObjectType<typeof upsertArgs>;\n\n/**\n * For a report that was filled in without seeing what is stored (held\n * offline, then sent): a blank in it means \"not answered\", so it takes the\n * stored answer instead of clearing it. Where both have an answer the new one\n * wins. An unticked box is a blank, and a group of boxes is one answer.\n */\nfunction keepStoredAnswers(args: UpsertArgs, stored: Doc<\"pitReports\">): UpsertArgs {\n  const blank = (text: string) => text.trim() === \"\";\n  const s = args.scoring;\n  const noScoring = !(s.turret || s.drumNonFullWidth || s.drumFullWidth || s.fixed || s.kitbot || s.other)\n    && blank(s.otherText);\n  const c = args.climb;\n  const noClimb = !(c.low || c.mid || c.high || c.duringAuto);\n  return {\n    ...args,\n    scoring: noScoring ? stored.scoring : s,\n    climb: noClimb ? stored.climb : c,\n    drivetrain: blank(args.drivetrain) ? stored.drivetrain : args.drivetrain,\n    underTrench: args.underTrench || stored.underTrench,\n    overBump: args.overBump || stored.overBump,\n    robotNotes: blank(args.robotNotes) ? stored.robotNotes : args.robotNotes,\n    otherNotes: blank(args.otherNotes) ? stored.otherNotes : args.otherNotes,\n    hopper: args.hopper && {\n      roof: args.hopper.roof ?? stored.hopper?.roof ?? null,\n      capacity: args.hopper.capacity ?? stored.hopper?.capacity ?? null,\n      expandedCapacity: args.hopper.expandedCapacity ?? stored.hopper?.expandedCapacity ?? null,\n    },\n    // Left out, these keep what is stored (see the fields below).\n    spares: args.spares?.length ? args.spares : undefined,\n    batteries: args.batteries?.length ? args.batteries : undefined,\n    robotWeight: args.robotWeight ?? undefined,\n    drivetrainGearing: args.drivetrainGearing === undefined || blank(args.drivetrainGearing)\n      ? undefined\n      : args.drivetrainGearing,\n  };\n}\n\n/**\n * Writes one pit report for the given scout's team. pit.upsert calls it for\n * the signed-in scout; a report held offline arrives through\n * convex/lib/transfer.ts with held set, which keeps stored answers where the\n * held report is blank.\n */\nexport async function writePitReport(\n  ctx: MutationCtx,\n  scoutId: Id<\"users\">,\n  input: UpsertArgs,\n  held = false,\n) {\n    const event = await activeEventOf(ctx, scoutId);"
   },
   {
    "old": "    if (!event) throw new Error(\"No active event.\");\n",
    "new": "    if (!event) throw new Error(\"No active event.\");\n    let args = input;\n"
   },
   {
    "old": "    if (await isPracticing(ctx)) {",
    "new": "    if (await isPracticingAs(ctx, scoutId)) {"
   },
   {
    "old": "      return await savePractice(ctx, {",
    "new": "      return await savePracticeAs(ctx, scoutId, {"
   },
   {
    "old": "    const scoutingTeamNumber = await currentTeamNumber(ctx);",
    "new": "    const scoutingTeamNumber = await teamNumberOf(ctx, scoutId);"
   },
   {
    "old": "    const existing = await mine(ctx, event._id, args.teamId);",
    "new": "    const existing = await reportFor(ctx, event._id, args.teamId, scoutingTeamNumber);\n    if (held && existing) args = keepStoredAnswers(args, existing);"
   },
   {
    "old": "    });\n  },\n});",
    "new": "    });\n}\n\nexport const upsert = mutation({\n  args: upsertArgs,\n  handler: async (ctx, args) => await writePitReport(ctx, await requireUser(ctx), args),\n});"
   }
  ]
 },
 "convex/notes.ts": {
  "marker": "export async function writeGenericMatch(",
  "edits": [
   {
    "old": "import { v } from \"convex/values\";",
    "new": "import { v, type ObjectType } from \"convex/values\";"
   },
   {
    "old": "import type { QueryCtx } from \"./_generated/server\";",
    "new": "import type { MutationCtx, QueryCtx } from \"./_generated/server\";"
   },
   {
    "old": "import { isPracticing, savePractice } from \"./lib/practice\";",
    "new": "import { isPracticing, isPracticingAs, savePractice, savePracticeAs } from \"./lib/practice\";"
   },
   {
    "old": "  activeEvent, currentProfile, currentTeamNumber, managesTeam, requireTeamAdmin, requireUser,",
    "new": "  activeEvent, activeEventOf, currentProfile, currentTeamNumber, managesTeam, requireTeamAdmin,\n  requireUser, teamNumberOf,"
   },
   {
    "old": "export const savePitReport = mutation({\n  args: {",
    "new": "export const savePitReportArgs = {"
   },
   {
    "old": "    otherNotes: v.string(),\n  },\n  handler: async (ctx, args) => {\n    const scoutId = await requireUser(ctx);\n    const event = await activeEvent(ctx);\n    if (!event) throw new Error(\"No active event.\");\n    const scoutingTeamNumber = await currentTeamNumber(ctx);\n    if (scoutingTeamNumber === undefined) {\n      throw new Error(\"Set your team number on your profile first.\");\n    }\n    const team = await teamByNumber(ctx, event._id, args.teamNumber);",
    "new": "    otherNotes: v.string(),\n};\n\n/**\n * Writes one other-season pit report for the given scout's team.\n * notes.savePitReport calls it for the signed-in scout; a report held offline\n * arrives through convex/lib/transfer.ts with held set. A held report was\n * filled in without seeing what is stored, so its blanks keep the stored\n * answers; where both have an answer the new one wins.\n */\nexport async function writeGenericPit(\n  ctx: MutationCtx,\n  scoutId: Id<\"users\">,\n  args: ObjectType<typeof savePitReportArgs>,\n  held = false,\n) {\n    const event = await activeEventOf(ctx, scoutId);\n    if (!event) throw new Error(\"No active event.\");\n    const scoutingTeamNumber = await teamNumberOf(ctx, scoutId);\n    if (scoutingTeamNumber === undefined) {\n      throw new Error(\"Set your team number on your profile first.\");\n    }\n    const team = await teamByNumber(ctx, event._id, args.teamNumber);"
   },
   {
    "old": "\n    if (await isPracticing(ctx)) {\n      // A practice photo is not kept.",
    "new": "\n    if (await isPracticingAs(ctx, scoutId)) {\n      // A practice photo is not kept."
   },
   {
    "old": "      if (args.photoId) await ctx.storage.delete(args.photoId);\n      return await savePractice(ctx, {\n        kind: \"pitNote\", teamNumber: team.number, matchNumber: null, payload: fields,",
    "new": "      if (args.photoId) await ctx.storage.delete(args.photoId);\n      return await savePracticeAs(ctx, scoutId, {\n        kind: \"pitNote\", teamNumber: team.number, matchNumber: null, payload: fields,"
   },
   {
    "old": "\n    const row = {\n      ...fields,\n      // Keep the old photo when this save did not include a new one.",
    "new": "\n    const kept = held && existing\n      ? {\n          scoringText: fields.scoringText || existing.scoringText || \"\",\n          drivetrain: fields.drivetrain || existing.drivetrain || \"\",\n          drivetrainGearing: fields.drivetrainGearing || existing.drivetrainGearing || \"\",\n          robotWeight: fields.robotWeight ?? existing.robotWeight,\n          spares: fields.spares.length > 0 ? fields.spares : existing.spares ?? [],\n          batteries: fields.batteries.length > 0 ? fields.batteries : existing.batteries ?? [],\n          notes: fields.notes || existing.notes,\n          otherNotes: fields.otherNotes || existing.otherNotes || \"\",\n        }\n      : fields;\n\n    const row = {\n      ...kept,\n      // Keep the old photo when this save did not include a new one."
   },
   {
    "old": "    return await ctx.db.insert(\"pitNotes\", { eventId: event._id, teamId: team._id, ...row });\n  },\n});",
    "new": "    return await ctx.db.insert(\"pitNotes\", { eventId: event._id, teamId: team._id, ...row });\n}\n\nexport const savePitReport = mutation({\n  args: savePitReportArgs,\n  handler: async (ctx, args) => await writeGenericPit(ctx, await requireUser(ctx), args),\n});"
   },
   {
    "old": "export const saveMatchReport = mutation({\n  args: {",
    "new": "export const saveMatchReportArgs = {"
   },
   {
    "old": "    notes: v.string(),\n  },\n  handler: async (ctx, args) => {\n    const scoutId = await requireUser(ctx);\n    const event = await activeEvent(ctx);\n    if (!event) throw new Error(\"No active event.\");\n    const scoutingTeamNumber = await currentTeamNumber(ctx);\n    if (scoutingTeamNumber === undefined) {\n      throw new Error(\"Set your team number on your profile first.\");\n    }\n    const match = await matchByNumber(ctx, event._id, args.matchNumber);",
    "new": "    notes: v.string(),\n};\n\n/**\n * Writes one other-season match report for the given scout.\n * notes.saveMatchReport calls it for the signed-in scout; a report held\n * offline arrives through convex/lib/transfer.ts with held set, which keeps\n * the scout's stored answers where the held report is blank.\n */\nexport async function writeGenericMatch(\n  ctx: MutationCtx,\n  scoutId: Id<\"users\">,\n  args: ObjectType<typeof saveMatchReportArgs>,\n  held = false,\n) {\n    const event = await activeEventOf(ctx, scoutId);\n    if (!event) throw new Error(\"No active event.\");\n    const scoutingTeamNumber = await teamNumberOf(ctx, scoutId);\n    if (scoutingTeamNumber === undefined) {\n      throw new Error(\"Set your team number on your profile first.\");\n    }\n    const match = await matchByNumber(ctx, event._id, args.matchNumber);"
   },
   {
    "old": "\n    if (await isPracticing(ctx)) {\n      return await savePractice(ctx, {\n        kind: \"matchNote\", teamNumber: team.number, matchNumber: match.matchNumber, payload: fields,",
    "new": "\n    if (await isPracticingAs(ctx, scoutId)) {\n      return await savePracticeAs(ctx, scoutId, {\n        kind: \"matchNote\", teamNumber: team.number, matchNumber: match.matchNumber, payload: fields,"
   },
   {
    "old": "      await ctx.db.patch(existing._id, { ...fields, scoutingTeamNumber, updatedAt: now });",
    "new": "      // An unticked box is a blank too: it cannot untick what is stored.\n      const kept = held\n        ? {\n            ...fields,\n            autoPath: fields.autoPath || existing.autoPath || \"\",\n            autoScoring: fields.autoScoring || existing.autoScoring || \"\",\n            teleopScoring: fields.teleopScoring || existing.teleopScoring || \"\",\n            endgame: fields.endgame || existing.endgame || \"\",\n            broke: fields.broke || existing.broke === true,\n            brokeNotes: fields.brokeNotes || existing.brokeNotes || \"\",\n            inconsistent: fields.inconsistent || existing.inconsistent === true,\n            inconsistentNotes: fields.inconsistentNotes || existing.inconsistentNotes || \"\",\n          }\n        : fields;\n      await ctx.db.patch(existing._id, { ...kept, scoutingTeamNumber, updatedAt: now });"
   },
   {
    "old": "      submittedAt: now,\n      updatedAt: now,\n    });\n  },\n});\n\n/** Your match notes at this event, newest first, for \"My notes\". */",
    "new": "      submittedAt: now,\n      updatedAt: now,\n    });\n}\n\nexport const saveMatchReport = mutation({\n  args: saveMatchReportArgs,\n  handler: async (ctx, args) => await writeGenericMatch(ctx, await requireUser(ctx), args),\n});\n\n/** Your match notes at this event, newest first, for \"My notes\". */"
   }
  ]
 },
 "convex/schema.ts": {
  "marker": "transferReceipts: defineTable({",
  "edits": [
   {
    "old": "    .index(\"by_user_target\", [\"userId\", \"kind\", \"eventId\", \"teamNumber\", \"matchNumber\"]),\n",
    "new": "    .index(\"by_user_target\", [\"userId\", \"kind\", \"eventId\", \"teamNumber\", \"matchNumber\"]),\n\n  /**\n   * One row per report that arrived from a device's outbox (a report saved\n   * with no connection and sent later). reportId is made on the device when\n   * the form is saved, so the same report sent twice, by any route, is\n   * written once: the report and its receipt are written in one mutation.\n   * Reports saved online have no receipt.\n   */\n  transferReceipts: defineTable({\n    authorId: v.id(\"users\"),\n    reportId: v.string(),\n    kind: v.union(\n      v.literal(\"match\"), v.literal(\"pit\"), v.literal(\"noteMatch\"), v.literal(\"notePit\"),\n    ),\n    eventId: v.id(\"events\"),\n    /** direct: sent by the author's own device. relay: uploaded by a teammate. */\n    via: v.union(v.literal(\"direct\"), v.literal(\"relay\")),\n    relayedBy: v.optional(v.id(\"users\")),\n    receivedAt: v.number(),\n  })\n    .index(\"by_author_report\", [\"authorId\", \"reportId\"])\n    .index(\"by_event\", [\"eventId\"]),\n"
   }
  ]
 },
 "convex/events.ts": {
  "marker": "async function deleteReceipts(",
  "edits": [
   {
    "old": "\n/** Shared by the immediate purge and the scheduled one. */",
    "new": "\n/** Receipts for reports that arrived from a device's outbox. */\nasync function deleteReceipts(ctx: MutationCtx, eventId: Id<\"events\">) {\n  const receipts = await ctx.db\n    .query(\"transferReceipts\")\n    .withIndex(\"by_event\", (q) => q.eq(\"eventId\", eventId))\n    .collect();\n  for (const row of receipts) await ctx.db.delete(row._id);\n}\n\n/** Shared by the immediate purge and the scheduled one. */"
   },
   {
    "old": "    await deleteNotes(ctx, args.eventId);\n",
    "new": "    await deleteNotes(ctx, args.eventId);\n    await deleteReceipts(ctx, args.eventId);\n"
   }
  ]
 },
 "convex/account.ts": {
  "marker": ".query(\"transferReceipts\")",
  "edits": [
   {
    "old": "  for (const account of accounts) await ctx.db.delete(account._id);\n",
    "new": "  for (const account of accounts) await ctx.db.delete(account._id);\n\n  // Bookkeeping, not scouting data: the reports themselves stay.\n  const receipts = await ctx.db\n    .query(\"transferReceipts\")\n    .withIndex(\"by_author_report\", (q) => q.eq(\"authorId\", userId))\n    .collect();\n  for (const receipt of receipts) await ctx.db.delete(receipt._id);\n"
   }
  ]
 },
 "convex/_generated/api.d.ts": {
  "marker": "import type * as transfer from \"../transfer.js\";",
  "edits": [
   {
    "old": "import type * as lib_teamSummaries from \"../lib/teamSummaries.js\";\nimport type * as lib_types from \"../lib/types.js\";",
    "new": "import type * as lib_teamSummaries from \"../lib/teamSummaries.js\";\nimport type * as lib_transfer from \"../lib/transfer.js\";\nimport type * as lib_types from \"../lib/types.js\";"
   },
   {
    "old": "import type * as teams from \"../teams.js\";\nimport type * as workbook from \"../workbook.js\";",
    "new": "import type * as teams from \"../teams.js\";\nimport type * as transfer from \"../transfer.js\";\nimport type * as workbook from \"../workbook.js\";"
   },
   {
    "old": "  \"lib/teamSummaries\": typeof lib_teamSummaries;\n  \"lib/types\": typeof lib_types;",
    "new": "  \"lib/teamSummaries\": typeof lib_teamSummaries;\n  \"lib/transfer\": typeof lib_transfer;\n  \"lib/types\": typeof lib_types;"
   },
   {
    "old": "  teams: typeof teams;\n  workbook: typeof workbook;",
    "new": "  teams: typeof teams;\n  transfer: typeof transfer;\n  workbook: typeof workbook;"
   }
  ]
 }
}
EOF_JSON
cat > .patch-transfer-server.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";

const mode = process.argv[2]; // "check" | "write"
const plan = JSON.parse(readFileSync(".patch-transfer-server.json", "utf8"));
const staged = [];
let already = 0;

for (const [path, { marker, edits }] of Object.entries(plan)) {
  let source;
  try {
    source = readFileSync(path, "utf8").replace(/\r\n/g, "\n");
  } catch {
    throw new Error(`${path} is missing`);
  }
  if (source.includes(marker)) {
    already += 1;
    console.log(`  already applied  ${path}`);
    continue;
  }
  for (const { old, new: next } of edits) {
    const found = source.split(old).length - 1;
    if (found !== 1) {
      throw new Error(
        `${path} is not the version this patch expects (${found === 0 ? "not found" : "found more than once"}):\n` +
        old.split("\n").slice(0, 4).join("\n"),
      );
    }
    source = source.replace(old, () => next);
  }
  if (!source.includes(marker)) throw new Error(`${path}: the edit did not take`);
  staged.push([path, source]);
}

for (const [path, source] of staged) {
  if (mode === "write") {
    writeFileSync(path, source);
    console.log(`  patched          ${path}`);
  } else console.log(`  ok               ${path}`);
}
if (mode === "write" && staged.length === 0 && already > 0) console.log("  nothing to do");
MJS
bun .patch-transfer-server.mjs check || { echo "ERROR: nothing was changed" >&2; exit 1; }

# ---- 2. New files ----------------------------------------------------------
say "Receipts and transfer functions"
cat > convex/lib/transfer.ts <<'EOF_FILE'
import { ConvexError, v, type Infer } from "convex/values";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import type { Id } from "../_generated/dataModel";
import { activeEventOf } from "./guards";
import { submitArgs, writeMatchReport } from "../matchReports";
import { upsertArgs, writePitReport } from "../pit";
import {
  saveMatchReportArgs, savePitReportArgs, writeGenericMatch, writeGenericPit,
} from "../notes";

/**
 * Reports that were saved with no connection and sent later.
 *
 * A held report carries an id made on the device when the form was saved and
 * the event it was saved for. acceptReport writes it through the same
 * functions an online save uses, and stores a receipt for the id in the same
 * mutation. A report whose id already has a receipt is not written again, so
 * a retry, a second tab or a second route cannot duplicate it.
 */

const envelope = { id: v.string(), eventId: v.id("events") };

/** One held report: which form it came from, and that form's save arguments. */
export const heldReport = v.union(
  v.object({ ...envelope, kind: v.literal("match"), args: v.object(submitArgs) }),
  v.object({ ...envelope, kind: v.literal("pit"), args: v.object(upsertArgs) }),
  v.object({ ...envelope, kind: v.literal("noteMatch"), args: v.object(saveMatchReportArgs) }),
  v.object({ ...envelope, kind: v.literal("notePit"), args: v.object(savePitReportArgs) }),
);
export type HeldReport = Infer<typeof heldReport>;

/** How a report reached the server. */
export type Route =
  | { via: "direct" }
  | { via: "relay"; relayedBy: Id<"users"> };

/**
 * accepted: written now. received: the server already had it, and nothing was
 * written; via says which route brought it the first time.
 */
export type Arrival = { status: "accepted" | "received"; via: "direct" | "relay" };

/** Ids are made by the device. Anything of a sensible shape is accepted. */
const REPORT_ID = /^[A-Za-z0-9-]{16,64}$/;

/** The receipt for one of an author's reports, if the server has it. */
export async function receiptFor(
  ctx: QueryCtx | MutationCtx,
  authorId: Id<"users">,
  reportId: string,
) {
  return await ctx.db
    .query("transferReceipts")
    .withIndex("by_author_report", (q) => q.eq("authorId", authorId).eq("reportId", reportId))
    .first();
}

/**
 * Writes a held report for its author, once. A report that cannot be accepted
 * is refused with a ConvexError, so the reason reaches the device and nothing
 * of it is written, the receipt included.
 */
export async function acceptReport(
  ctx: MutationCtx,
  authorId: Id<"users">,
  report: HeldReport,
  route: Route,
): Promise<Arrival> {
  if (!REPORT_ID.test(report.id)) throw new ConvexError("That report has no valid id.");

  const receipt = await receiptFor(ctx, authorId, report.id);
  if (receipt) return { status: "received", via: receipt.via };

  // The writers use the author's team's active event. A report held for a
  // different one must not land in it.
  const event = await activeEventOf(ctx, authorId);
  if (!event) throw new ConvexError("No active event.");
  if (event._id !== report.eventId) {
    throw new ConvexError("This was saved for a different event, so it was not sent.");
  }

  try {
    switch (report.kind) {
      case "match": {
        const [match, team] = await Promise.all([
          ctx.db.get(report.args.matchId), ctx.db.get(report.args.teamId),
        ]);
        if (!match || !team || match.eventId !== event._id || team.eventId !== event._id) {
          throw new ConvexError("That match or team is not at the active event.");
        }
        await writeMatchReport(ctx, authorId, report.args);
        break;
      }
      case "pit":
        // A held report never carries a photo: photos need a connection.
        if (report.args.photoId !== null) throw new ConvexError("A held report cannot carry a photo.");
        await writePitReport(ctx, authorId, report.args, true);
        break;
      case "noteMatch":
        await writeGenericMatch(ctx, authorId, report.args, true);
        break;
      case "notePit":
        if (report.args.photoId !== null) throw new ConvexError("A held report cannot carry a photo.");
        await writeGenericPit(ctx, authorId, report.args, true);
        break;
    }
  } catch (error) {
    // The writers throw plain errors, which production hides from the client.
    // The device needs the reason to show beside the report it could not send.
    if (error instanceof ConvexError) throw error;
    throw new ConvexError(error instanceof Error ? error.message : "The report could not be saved.");
  }

  await ctx.db.insert("transferReceipts", {
    authorId,
    reportId: report.id,
    kind: report.kind,
    eventId: event._id,
    via: route.via,
    ...(route.via === "relay" ? { relayedBy: route.relayedBy } : {}),
    receivedAt: Date.now(),
  });
  return { status: "accepted", via: route.via };
}
EOF_FILE
echo "  wrote            convex/lib/transfer.ts"
cat > convex/transfer.ts <<'EOF_FILE'
import { ConvexError, v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { requireUser } from "./lib/guards";
import { acceptReport, heldReport, receiptFor } from "./lib/transfer";

/** The most ids one receipts call may ask about. */
const MAX_IDS = 200;

/**
 * Sends one report that was held on the caller's device. Safe to call again
 * with the same report: the second call answers "received" and writes
 * nothing. One report per call, so a refused report cannot undo a good one.
 */
export const send = mutation({
  args: { report: heldReport },
  handler: async (ctx, args) =>
    await acceptReport(ctx, await requireUser(ctx), args.report, { via: "direct" }),
});

/**
 * Which of the caller's held reports the server already has, and by which
 * route each arrived. Called once when a device reconnects with reports
 * waiting, never subscribed to.
 */
export const receipts = query({
  args: { ids: v.array(v.string()) },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    if (args.ids.length > MAX_IDS) throw new ConvexError(`Ask about at most ${MAX_IDS} reports at once.`);
    const found: Array<{ id: string; via: "direct" | "relay" }> = [];
    for (const id of new Set(args.ids)) {
      const receipt = await receiptFor(ctx, userId, id);
      if (receipt) found.push({ id, via: receipt.via });
    }
    return found;
  },
});
EOF_FILE
echo "  wrote            convex/transfer.ts"

# ---- 3. Edits --------------------------------------------------------------
say "Shared write functions, schema, cleanup"
bun .patch-transfer-server.mjs write

say "Done"
cat <<'TXT'
Next:
  1. bunx tsc -p convex && bun run typecheck && bun run lint
  2. bun run go
     Pushes the functions and creates the transferReceipts table. It also
     rewrites convex/_generated; this patch already added the two new
     modules there, so expect no difference.
  3. Online, check that saving is unchanged:
     a. Submit a match report. It appears on the team and in the counts.
     b. Submit the same robot in the same match again: still refused.
     c. Open a pit report that has answers, clear one field, save, reopen:
        the field is cleared (blanks are only kept for held reports).
     d. If an other-season event is handy: save its match and pit forms.
  4. Nothing calls transfer.send or transfer.receipts yet, so there is
     nothing new to see in the app. The transferReceipts table stays empty
     until patch 7.
TXT
