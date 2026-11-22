#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-pit-status.sh
#   1. A completely blank pit report is not saved, so the team stays
#      "Not scouted" (the form says so; the server refuses it too)
#   2. A partial report marks the team "Partially scouted", kept apart from
#      fully scouted teams: own filter on the pit page, own badge on team
#      cards and pick list chips, and the form says what is still needed
#
# Complete = scoring capability, hopper, drivetrain (with which swerve /
# what other), robot weight and at least one battery. Not needed: climb,
# drivetrain gearing, spares, photo, notes. Under trench / over bump are
# checkboxes where unticked is a real answer, so they never block "complete".
#
# Status is worked out from the stored report every time, so reports saved
# earlier are sorted into Scouted / Partially scouted / Not scouted too.
# No schema change.
#
# Needs patch-pit-tweaks.sh applied first.
#
# Every edit is checked before any file is written, so a mismatch stops the
# patch with nothing half-applied. CRLF checkouts are handled.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/pit.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

if grep -qF 'pitStatus' convex/teams.ts; then
  echo "patch-pit-status already applied."
  exit 0
fi
if ! grep -qF 'cleanWeight' convex/pit.ts; then
  echo "ERROR: run patch-pit-tweaks.sh first." >&2
  exit 1
fi

# Working files live in the repo root, not /tmp: on Windows, Git Bash's /tmp
# is not where bun looks for a "/tmp/..." path written inside a script.
JSON_FILE=".patch-pit-status.json"
MJS_FILE=".patch-pit-status.mjs"
trap 'rm -f "$JSON_FILE" "$MJS_FILE"' EXIT

say "Applying patch-pit-status"
cat > "$JSON_FILE" <<'PATCH_EDITS_JSON'
[
 {
  "file": "convex/lib/pitStatus.ts",
  "old": null,
  "new": "/**\n * How complete a pit report is. Shared by the server (team lists, exports,\n * the blank check on save) and the pit form (live \"still needed\" hint).\n *\n * Complete needs: scoring capability, hopper, drivetrain, robot weight and at\n * least one battery. Not needed: climb, drivetrain gearing, spares, photo,\n * notes. Under trench / over bump are checkboxes where unticked is a real\n * answer, so they never make a report incomplete; ticking one does make it\n * not blank.\n */\n\nexport type PitStatus = \"none\" | \"partial\" | \"complete\";\n\nexport const PIT_STATUS_LABELS: Record<PitStatus, string> = {\n  none: \"Not scouted\",\n  partial: \"Partially scouted\",\n  complete: \"Scouted\",\n};\n\n/** The parts of a pit report the status looks at. A stored report fits. */\nexport type PitFields = {\n  scoring: {\n    turret: boolean; drumNonFullWidth: boolean; drumFullWidth: boolean;\n    fixed: boolean; kitbot: boolean; other: boolean; otherText: string;\n  };\n  climb: { low: boolean; mid: boolean; high: boolean; duringAuto: boolean };\n  drivetrain: string;\n  drivetrainGearing?: string;\n  robotWeight?: number | null;\n  underTrench: boolean;\n  overBump: boolean;\n  robotNotes: string;\n  otherNotes: string;\n  photoId?: string | null;\n  hopper?: {\n    roof: string | null;\n    capacity: number | null;\n    expandedCapacity: number | null;\n  };\n  spares?: ReadonlyArray<unknown>;\n  batteries?: ReadonlyArray<unknown>;\n};\n\n/** Drivetrains whose detail box (\"Which swerve?\", \"Describe it\") is needed. */\nconst DETAIL_NEEDED = new Set([\"Swerve\", \"Other\"]);\n\n/** What a report still needs to count as complete, in form order. */\nexport function pitMissing(r: PitFields): string[] {\n  const missing: string[] = [];\n\n  const s = r.scoring;\n  const anyScoring =\n    s.turret || s.drumNonFullWidth || s.drumFullWidth || s.fixed || s.kitbot || s.other;\n  if (!anyScoring || (s.other && s.otherText.trim() === \"\")) missing.push(\"scoring capability\");\n\n  const h = r.hopper;\n  const expands = h?.roof === \"expanding\" || h?.roof === \"net\";\n  if (!h || h.roof === null || h.capacity === null || (expands && h.expandedCapacity === null)) {\n    missing.push(\"hopper\");\n  }\n\n  const [base = \"\", ...rest] = r.drivetrain.split(\" — \");\n  const detail = rest.join(\" — \").trim();\n  if (base.trim() === \"\" || (DETAIL_NEEDED.has(base.trim()) && detail === \"\")) {\n    missing.push(\"drivetrain\");\n  }\n\n  if (r.robotWeight === undefined || r.robotWeight === null) missing.push(\"robot weight\");\n  if ((r.batteries ?? []).length === 0) missing.push(\"batteries\");\n  return missing;\n}\n\n/** True when nothing at all was filled in. */\nexport function pitIsBlank(r: PitFields): boolean {\n  const s = r.scoring;\n  const c = r.climb;\n  const h = r.hopper;\n  const filled =\n    s.turret || s.drumNonFullWidth || s.drumFullWidth || s.fixed || s.kitbot || s.other ||\n    s.otherText.trim() !== \"\" ||\n    c.low || c.mid || c.high || c.duringAuto ||\n    r.drivetrain.trim() !== \"\" ||\n    (r.drivetrainGearing ?? \"\").trim() !== \"\" ||\n    (r.robotWeight !== undefined && r.robotWeight !== null) ||\n    r.underTrench || r.overBump ||\n    r.robotNotes.trim() !== \"\" || r.otherNotes.trim() !== \"\" ||\n    (r.photoId !== undefined && r.photoId !== null) ||\n    (h !== undefined && (h.roof !== null || h.capacity !== null || h.expandedCapacity !== null)) ||\n    (r.spares ?? []).length > 0 ||\n    (r.batteries ?? []).length > 0;\n  return !filled;\n}\n\n/** No report, or a blank one, is \"none\". */\nexport function pitStatus(r: PitFields | null | undefined): PitStatus {\n  if (!r || pitIsBlank(r)) return \"none\";\n  return pitMissing(r).length === 0 ? \"complete\" : \"partial\";\n}\n"
 },
 {
  "file": "src/lib/pit-status.ts",
  "old": null,
  "new": "import type { PitStatus } from \"../../convex/lib/pitStatus\";\n\nexport * from \"../../convex/lib/pitStatus\";\n\n/** Short pit labels for team cards and pick list chips. */\nexport const PIT_BADGE: Record<PitStatus, { text: string; variant: \"default\" | \"secondary\" | \"outline\" }> = {\n  complete: { text: \"Pit\", variant: \"default\" },\n  partial: { text: \"Partial pit\", variant: \"secondary\" },\n  none: { text: \"No pit\", variant: \"outline\" },\n};\n"
 },
 {
  "file": "convex/pit.ts",
  "old": "import { MAX_OTHER_SPARES, SPARE_PARTS, type Battery, type Spare } from \"./lib/spares\";",
  "new": "import { MAX_OTHER_SPARES, SPARE_PARTS, type Battery, type Spare } from \"./lib/spares\";\nimport { pitIsBlank } from \"./lib/pitStatus\";"
 },
 {
  "file": "convex/pit.ts",
  "old": "      updatedAt: Date.now(),\n    };\n\n    if (existing) {",
  "new": "      updatedAt: Date.now(),\n    };\n\n    // A blank report would leave the team looking visited with nothing in it.\n    // The form refuses too; this covers stale and edited clients.\n    if (pitIsBlank(fields)) {\n      throw new Error(\"Nothing is filled in, so there is nothing to save.\");\n    }\n\n    if (existing) {"
 },
 {
  "file": "convex/teams.ts",
  "old": "import { reportCountsFor } from \"./lib/reportCounts\";\nimport type { Doc, Id } from \"./_generated/dataModel\";",
  "new": "import { reportCountsFor } from \"./lib/reportCounts\";\nimport { pitMissing, pitStatus, type PitStatus } from \"./lib/pitStatus\";\nimport type { Doc, Id } from \"./_generated/dataModel\";"
 },
 {
  "file": "convex/teams.ts",
  "old": "    const scouted = new Set(pit.map((p) => p.teamId));",
  "new": "    const statusByTeam = new Map(pit.map((p) => [p.teamId, pitStatus(p)]));"
 },
 {
  "file": "convex/teams.ts",
  "old": "        pitScouted: scouted.has(t._id),",
  "new": "        // pitScouted means fully scouted; pitStatus also tells partial from none.\n        pitStatus: statusByTeam.get(t._id) ?? (\"none\" as PitStatus),\n        pitScouted: statusByTeam.get(t._id) === \"complete\","
 },
 {
  "file": "convex/teams.ts",
  "old": "      pitReport,\n      photoUrl,",
  "new": "      pitReport,\n      pitStatus: pitStatus(pitReport),\n      pitMissing: pitReport ? pitMissing(pitReport) : [],\n      photoUrl,"
 },
 {
  "file": "convex/stats.ts",
  "old": "import { reportCountsFor } from \"./lib/reportCounts\";",
  "new": "import { reportCountsFor } from \"./lib/reportCounts\";\nimport { pitStatus } from \"./lib/pitStatus\";"
 },
 {
  "file": "convex/stats.ts",
  "old": "        pitScouted: pit.some((p) => p.scoutingTeamNumber === myTeam),",
  "new": "        pitScouted: pit.some((p) => p.scoutingTeamNumber === myTeam && pitStatus(p) === \"complete\"),"
 },
 {
  "file": "convex/stats.ts",
  "old": "    const pitScouted = new Set(pit.map((p) => p.teamId));",
  "new": "    // \"Never pit scouted\": blank reports do not count; partial ones hold real data.\n    const pitScouted = new Set(pit.filter((p) => pitStatus(p) !== \"none\").map((p) => p.teamId));"
 },
 {
  "file": "convex/workbook.ts",
  "old": "import { batteryText, spareText } from \"./lib/spares\";",
  "new": "import { batteryText, spareText } from \"./lib/spares\";\nimport { PIT_STATUS_LABELS, pitStatus } from \"./lib/pitStatus\";"
 },
 {
  "file": "convex/workbook.ts",
  "old": "          scout: nameByUser.get(p.scoutId) ?? \"\",\n          drivetrain: p.drivetrain,",
  "new": "          scout: nameByUser.get(p.scoutId) ?? \"\",\n          status: PIT_STATUS_LABELS[pitStatus(p)],\n          drivetrain: p.drivetrain,"
 },
 {
  "file": "convex/workbook.ts",
  "old": "    const pitScouted = new Set(\n      pit.filter((p) => p.scoutingTeamNumber === teamNumber).map((p) => p.teamId),\n    );",
  "new": "    const pitStatusByTeam = new Map(\n      pit.filter((p) => p.scoutingTeamNumber === teamNumber).map((p) => [p.teamId, pitStatus(p)]),\n    );"
 },
 {
  "file": "convex/workbook.ts",
  "old": "          pitScouted: pitScouted.has(t._id),",
  "new": "          pitStatus: PIT_STATUS_LABELS[pitStatusByTeam.get(t._id) ?? \"none\"],"
 },
 {
  "file": "src/routes/pit/index.tsx",
  "old": "import { Badge } from \"@/components/ui/badge\";\n\ntype Filter = \"all\" | \"todo\" | \"done\";\n\nconst FILTERS: ReadonlyArray<{ value: Filter; label: string }> = [\n  { value: \"todo\", label: \"Not scouted\" },\n  { value: \"done\", label: \"Scouted\" },\n  { value: \"all\", label: \"All\" },\n];",
  "new": "import { Badge } from \"@/components/ui/badge\";\nimport { PIT_STATUS_LABELS } from \"@/lib/pit-status\";\n\ntype Filter = \"all\" | \"todo\" | \"partial\" | \"done\";\n\nconst FILTERS: ReadonlyArray<{ value: Filter; label: string }> = [\n  { value: \"todo\", label: \"Not scouted\" },\n  { value: \"partial\", label: \"Partially scouted\" },\n  { value: \"done\", label: \"Scouted\" },\n  { value: \"all\", label: \"All\" },\n];"
 },
 {
  "file": "src/routes/pit/index.tsx",
  "old": "      if (filter === \"todo\" && team.pitScouted) return false;\n      if (filter === \"done\" && !team.pitScouted) return false;",
  "new": "      if (filter === \"todo\" && team.pitStatus !== \"none\") return false;\n      if (filter === \"partial\" && team.pitStatus !== \"partial\") return false;\n      if (filter === \"done\" && team.pitStatus !== \"complete\") return false;"
 },
 {
  "file": "src/routes/pit/index.tsx",
  "old": "  const done = teams?.filter((t) => t.pitScouted).length ?? 0;",
  "new": "  const done = teams?.filter((t) => t.pitStatus === \"complete\").length ?? 0;\n  const partial = teams?.filter((t) => t.pitStatus === \"partial\").length ?? 0;"
 },
 {
  "file": "src/routes/pit/index.tsx",
  "old": "          : `${done} of ${total} teams scouted. Tap a team to scout it.`",
  "new": "          : `${done} of ${total} teams scouted${partial > 0 ? `, ${partial} partially` : \"\"}. Tap a team to scout it.`"
 },
 {
  "file": "src/routes/pit/index.tsx",
  "old": "          {filter === \"todo\" && total > 0\n            ? \"Every team has been scouted.\"\n            : \"Nothing matches.\"}",
  "new": "          {filter === \"todo\" && total > 0\n            ? partial > 0\n              ? \"Every team has been visited. Partially scouted ones still need finishing.\"\n              : \"Every team has been scouted.\"\n            : \"Nothing matches.\"}"
 },
 {
  "file": "src/routes/pit/index.tsx",
  "old": "                team.pitScouted\n                  ? \"bg-primary/5 border-primary/40\"\n                  : \"hover:bg-accent/50\",",
  "new": "                team.pitStatus === \"complete\"\n                  ? \"bg-primary/5 border-primary/40\"\n                  : team.pitStatus === \"partial\"\n                    ? \"border-dashed border-primary/40 hover:bg-accent/50\"\n                    : \"hover:bg-accent/50\","
 },
 {
  "file": "src/routes/pit/index.tsx",
  "old": "                variant={team.pitScouted ? \"default\" : \"outline\"}\n                className=\"mt-1 w-fit\"\n              >\n                {team.pitScouted ? \"Scouted\" : \"Not scouted\"}",
  "new": "                variant={\n                  team.pitStatus === \"complete\" ? \"default\"\n                    : team.pitStatus === \"partial\" ? \"secondary\" : \"outline\"\n                }\n                className=\"mt-1 w-fit\"\n              >\n                {PIT_STATUS_LABELS[team.pitStatus]}"
 },
 {
  "file": "src/components/scouting/team-card.tsx",
  "old": "import { TIER_LABELS, type Tier } from \"@/lib/types\";",
  "new": "import { TIER_LABELS, type Tier } from \"@/lib/types\";\nimport { PIT_BADGE, type PitStatus } from \"@/lib/pit-status\";"
 },
 {
  "file": "src/components/scouting/team-card.tsx",
  "old": "  pitScouted,\n  reportCount,",
  "new": "  pitStatus,\n  reportCount,"
 },
 {
  "file": "src/components/scouting/team-card.tsx",
  "old": "  pitScouted: boolean;\n  reportCount: number;",
  "new": "  pitStatus: PitStatus;\n  reportCount: number;"
 },
 {
  "file": "src/components/scouting/team-card.tsx",
  "old": "        <Badge variant={pitScouted ? \"default\" : \"outline\"}>\n          {pitScouted ? \"Pit\" : \"No pit\"}\n        </Badge>",
  "new": "        <Badge variant={PIT_BADGE[pitStatus].variant}>\n          {PIT_BADGE[pitStatus].text}\n        </Badge>"
 },
 {
  "file": "src/routes/teams/index.tsx",
  "old": "                pitScouted={team.pitScouted}",
  "new": "                pitStatus={team.pitStatus}"
 },
 {
  "file": "src/routes/picklists/team-chip.tsx",
  "old": "import { Badge } from \"@/components/ui/badge\";",
  "new": "import { Badge } from \"@/components/ui/badge\";\nimport { PIT_BADGE, type PitStatus } from \"@/lib/pit-status\";"
 },
 {
  "file": "src/routes/picklists/team-chip.tsx",
  "old": "  nickname,\n  pitScouted,\n  stats,",
  "new": "  nickname,\n  pitStatus,\n  stats,"
 },
 {
  "file": "src/routes/picklists/team-chip.tsx",
  "old": "  pitScouted: boolean;\n  stats: ChipStats | null;",
  "new": "  pitStatus: PitStatus;\n  stats: ChipStats | null;"
 },
 {
  "file": "src/routes/picklists/team-chip.tsx",
  "old": "        <Badge variant={pitScouted ? \"secondary\" : \"outline\"} className=\"shrink-0 text-[10px]\">\n          {pitScouted ? \"Pit\" : \"No pit\"}\n        </Badge>",
  "new": "        <Badge\n          variant={pitStatus === \"complete\" ? \"secondary\" : \"outline\"}\n          className={[\"shrink-0 text-[10px]\", pitStatus === \"partial\" ? \"border-dashed\" : \"\"].join(\" \")}>\n          {PIT_BADGE[pitStatus].text}\n        </Badge>"
 },
 {
  "file": "src/routes/picklists/board.tsx",
  "old": "import { TeamChip, type ChipStats } from \"./team-chip\";",
  "new": "import { TeamChip, type ChipStats } from \"./team-chip\";\nimport type { PitStatus } from \"@/lib/pit-status\";"
 },
 {
  "file": "src/routes/picklists/board.tsx",
  "old": "    () => new Map<string, boolean>((teams ?? []).map((t) => [t._id, t.pitScouted])),",
  "new": "    () => new Map<string, PitStatus>((teams ?? []).map((t) => [t._id, t.pitStatus])),"
 },
 {
  "file": "src/routes/picklists/board.tsx",
  "old": "                      pitScouted={pitByTeam.get(row.teamId) ?? false}",
  "new": "                      pitStatus={pitByTeam.get(row.teamId) ?? \"none\"}"
 },
 {
  "file": "src/routes/dashboard.tsx",
  "old": "  const pitDone = teams?.filter((t) => t.pitScouted).length ?? 0;",
  "new": "  const pitDone = teams?.filter((t) => t.pitScouted).length ?? 0;\n  const pitPartial = teams?.filter((t) => t.pitStatus === \"partial\").length ?? 0;"
 },
 {
  "file": "src/routes/dashboard.tsx",
  "old": "          hint={total - pitDone > 0 ? `${total - pitDone} still to do` : \"Complete\"} />",
  "new": "          hint={total - pitDone > 0\n            ? `${total - pitDone} still to do${pitPartial > 0 ? ` (${pitPartial} partial)` : \"\"}`\n            : \"Complete\"} />"
 },
 {
  "file": "src/routes/teams/team-detail.tsx",
  "old": "            {data.pitReport === null ? (",
  "new": "            {data.pitReport === null || data.pitStatus === \"none\" ? ("
 },
 {
  "file": "src/routes/teams/team-detail.tsx",
  "old": "              <div className=\"space-y-3 rounded-lg border p-3\">\n                {data.photoUrl ? (",
  "new": "              <div className=\"space-y-3 rounded-lg border p-3\">\n                {data.pitStatus === \"partial\" ? (\n                  <p className=\"text-muted-foreground text-xs\">\n                    <Badge variant=\"outline\" className=\"mr-2 border-dashed\">Partially scouted</Badge>\n                    Still needed: {data.pitMissing.join(\", \")}.\n                  </p>\n                ) : null}\n                {data.photoUrl ? ("
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "import { LoadingWheel } from \"@/components/loading-wheel\";",
  "new": "import { LoadingWheel } from \"@/components/loading-wheel\";\nimport { pitIsBlank, pitMissing, pitStatus } from \"@/lib/pit-status\";"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "      await upsert({\n        teamId: data.team._id,\n        scoring: {\n          turret: form.turret,\n          drumNonFullWidth: form.drumNonFullWidth,\n          drumFullWidth: form.drumFullWidth,\n          fixed: form.fixed,\n          kitbot: form.kitbot,\n          other: form.other,\n          otherText: form.other ? form.otherText : \"\",\n        },\n        climb: {\n          low: form.low, mid: form.mid, high: form.high,\n          duringAuto: form.duringAuto,\n        },\n        drivetrain: form.drivetrainDetail.trim()\n          ? `${form.drivetrainBase} — ${form.drivetrainDetail.trim()}`\n          : form.drivetrainBase,\n        drivetrainGearing: form.drivetrainGearing.trim(),\n        robotWeight: form.robotWeight === \"\"\n          ? null\n          : Math.round(Number.parseFloat(form.robotWeight) * 10) / 10,\n        underTrench: form.underTrench,\n        overBump: form.overBump,\n        robotNotes: form.robotNotes,\n        otherNotes: form.otherNotes,\n        spares: [\n          ...FIXED_SPARE_PARTS\n            .filter(({ part }) => form.spares[part].on)\n            .map(({ part }) => {\n              const row = form.spares[part];\n              return {\n                part,\n                ...(row.quantity === \"\" ? {} : { quantity: Number.parseInt(row.quantity, 10) }),\n                specify: row.specify.trim(),\n              };\n            }),\n          ...form.otherSpares\n            .filter((s) => !otherSpareEmpty(s))\n            .map((s) => ({\n              part: \"other\" as const,\n              ...(s.quantity === \"\" ? {} : { quantity: Number.parseInt(s.quantity, 10) }),\n              specify: s.specify.trim(),\n            })),\n        ],\n        batteries: form.batteries\n          .filter((b) => !batteryEmpty(b))\n          .map((b) => ({\n            type: b.type as BatteryType,\n            ...(b.type === \"other\" ? { otherType: b.otherType.trim() } : {}),\n            ...(b.quantity === \"\" ? {} : { quantity: Number.parseInt(b.quantity, 10) }),\n          })),\n        photoId,\n        hopper: {\n          roof: form.hopperRoof === \"\" ? null : form.hopperRoof,\n          capacity: toCount(form.hopperCapacity),\n          expandedCapacity: roofExpands(form.hopperRoof)\n            ? toCount(form.hopperExpanded)\n            : null,\n        },\n      });\n\n      toast.success(`Saved team ${data.team.number}`);",
  "new": "      await upsert({ teamId: data.team._id, ...draft, photoId });\n\n      if (draftMissing.length === 0) {\n        toast.success(`Saved team ${data.team.number}`);\n      } else {\n        toast.success(`Saved team ${data.team.number} as partially scouted`, {\n          description: `Still needed: ${draftMissing.join(\", \")}.`,\n        });\n      }"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "export default function PitFormPage() {",
  "new": "/** The report as the server takes it, minus the team and photo. */\nfunction reportFromForm(form: FormState) {\n  return {\n    scoring: {\n      turret: form.turret,\n      drumNonFullWidth: form.drumNonFullWidth,\n      drumFullWidth: form.drumFullWidth,\n      fixed: form.fixed,\n      kitbot: form.kitbot,\n      other: form.other,\n      otherText: form.other ? form.otherText : \"\",\n    },\n    climb: {\n      low: form.low, mid: form.mid, high: form.high,\n      duringAuto: form.duringAuto,\n    },\n    drivetrain: form.drivetrainDetail.trim()\n      ? `${form.drivetrainBase} — ${form.drivetrainDetail.trim()}`\n      : form.drivetrainBase,\n    drivetrainGearing: form.drivetrainGearing.trim(),\n    robotWeight: form.robotWeight === \"\"\n      ? null\n      : Math.round(Number.parseFloat(form.robotWeight) * 10) / 10,\n    underTrench: form.underTrench,\n    overBump: form.overBump,\n    robotNotes: form.robotNotes,\n    otherNotes: form.otherNotes,\n    spares: [\n      ...FIXED_SPARE_PARTS\n        .filter(({ part }) => form.spares[part].on)\n        .map(({ part }) => {\n          const row = form.spares[part];\n          return {\n            part,\n            ...(row.quantity === \"\" ? {} : { quantity: Number.parseInt(row.quantity, 10) }),\n            specify: row.specify.trim(),\n          };\n        }),\n      ...form.otherSpares\n        .filter((s) => !otherSpareEmpty(s))\n        .map((s) => ({\n          part: \"other\" as const,\n          ...(s.quantity === \"\" ? {} : { quantity: Number.parseInt(s.quantity, 10) }),\n          specify: s.specify.trim(),\n        })),\n    ],\n    batteries: form.batteries\n      .filter((b) => !batteryEmpty(b))\n      .map((b) => ({\n        type: b.type as BatteryType,\n        ...(b.type === \"other\" ? { otherType: b.otherType.trim() } : {}),\n        ...(b.quantity === \"\" ? {} : { quantity: Number.parseInt(b.quantity, 10) }),\n      })),\n    hopper: {\n      roof: form.hopperRoof === \"\" ? null : form.hopperRoof,\n      capacity: toCount(form.hopperCapacity),\n      expandedCapacity: roofExpands(form.hopperRoof)\n        ? toCount(form.hopperExpanded)\n        : null,\n    },\n  };\n}\n\nexport default function PitFormPage() {"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "  const save = async () => {\n    if (!data) return;",
  "new": "  // What saving now would store, and so what it would count as.\n  const draft = reportFromForm(form);\n  const hasPhoto = photoFile !== null || Boolean(data?.report?.photoId);\n  const draftBlank = pitIsBlank({ ...draft, photoId: hasPhoto ? \"photo\" : null });\n  const draftMissing = pitMissing(draft);\n\n  const save = async () => {\n    if (!data) return;\n    if (draftBlank) {\n      toast.error(\"Nothing filled in yet\", {\n        description: \"A blank report would not count as scouted, so nothing was saved.\",\n      });\n      return;\n    }"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "  const existingPhoto = photoPreview ?? data.photoUrl;",
  "new": "  const existingPhoto = photoPreview ?? data.photoUrl;\n  const savedStatus = pitStatus(data.report);\n  const savedMissing = data.report ? pitMissing(data.report) : [];"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "      description={\n        data.report\n          ? \"Already scouted. Saving updates the existing report.\"\n          : \"Not yet scouted.\"\n      }",
  "new": "      description={\n        savedStatus === \"complete\"\n          ? \"Already scouted. Saving updates the existing report.\"\n          : savedStatus === \"partial\"\n            ? `Partially scouted. Still needed: ${savedMissing.join(\", \")}.`\n            : \"Not yet scouted.\"\n      }"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "      <Button className=\"h-14 w-full text-base\" disabled={saving}",
  "new": "      {!draftBlank && draftMissing.length > 0 ? (\n        <p className=\"text-muted-foreground text-sm\">\n          Saving now marks this team{\" \"}\n          <span className=\"text-foreground font-medium\">partially scouted</span>.\n          Still needed: {draftMissing.join(\", \")}.\n        </p>\n      ) : null}\n      <Button className=\"h-14 w-full text-base\" disabled={saving}"
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
  2. bun run typecheck
  3. Pit page: check the Not scouted / Partially scouted / Scouted filters.
TXT
