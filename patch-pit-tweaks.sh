#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-pit-tweaks.sh
#   1. Batteries: no Condition box; Qty becomes "# in good condition"
#   2. Spares: the Other checkbox becomes "+ Add other spare", one Other row
#      per thing, like batteries
#   3. Mobility: robot weight with bumpers and battery (lbs, one decimal
#      place, 10–200)
#   4. Mobility: drivetrain gearing (free text)
#
# Schema: pitReports gains optional robotWeight and drivetrainGearing, and a
# battery's condition becomes optional (old reports keep theirs, nothing new
# writes it). Existing data stays valid; no migration.
#
# A phone still on the old bundle can keep saving mid-event: the new fields
# are optional, a stored weight/gearing survives its saves, and the condition
# it sends is ignored.
#
# Every edit is checked before any file is written, so a mismatch stops the
# patch with nothing half-applied. CRLF checkouts are handled.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/pit.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

if grep -q "cleanWeight" convex/pit.ts; then
  echo "patch-pit-tweaks already applied."
  exit 0
fi

# Working files live in the repo root, not /tmp: on Windows, Git Bash's /tmp
# is not where bun looks for a "/tmp/..." path written inside a script.
JSON_FILE=".pit-tweaks.json"
MJS_FILE=".pit-tweaks.mjs"
trap 'rm -f "$JSON_FILE" "$MJS_FILE"' EXIT

say "Pit form, schema, mutation, team view and exports"
cat > "$JSON_FILE" <<'PIT_EDITS_JSON'
[
 {
  "file": "convex/lib/spares.ts",
  "old": "/** In the order the form lists them. */\nexport const SPARE_PARTS: ReadonlyArray<{ part: SparePart; label: string }> = [\n  { part: \"intake\", label: \"Intake\" },\n  { part: \"indexer\", label: \"Indexer rollers (if applicable)\" },\n  { part: \"shooter\", label: \"Shooter parts\" },\n  { part: \"swerve\", label: \"Swerve modules\" },\n  { part: \"other\", label: \"Other\" },\n];\n",
  "new": "/** In the order reports list them; Other rows come last. */\nexport const SPARE_PARTS: ReadonlyArray<{ part: SparePart; label: string }> = [\n  { part: \"intake\", label: \"Intake\" },\n  { part: \"indexer\", label: \"Indexer rollers (if applicable)\" },\n  { part: \"shooter\", label: \"Shooter parts\" },\n  { part: \"swerve\", label: \"Swerve modules\" },\n  { part: \"other\", label: \"Other\" },\n];\n\n/** The parts the form lists as checkboxes. Other is not one of them: the form\n *  adds Other rows with a plus, and a report can hold several. */\nexport type FixedSparePart = Exclude<SparePart, \"other\">;\nexport const FIXED_SPARE_PARTS = SPARE_PARTS.filter(\n  (p): p is { part: FixedSparePart; label: string } => p.part !== \"other\",\n);\n\n/** How many Other spares one report can list. */\nexport const MAX_OTHER_SPARES = 10;\n"
 },
 {
  "file": "convex/lib/spares.ts",
  "old": "/**\n * One kind of battery. otherType is the typed-in brand, only for \"other\".\n * quantity is required (rows saved before that may lack it); condition is\n * optional. The same type can appear twice, so\n * a team can list new and worn batteries separately.\n */\nexport type Battery = {\n  type: BatteryType;\n  otherType?: string;\n  quantity?: number;\n  condition: string;\n};\n",
  "new": "/**\n * One kind of battery. otherType is the typed-in brand, only for \"other\".\n * quantity is how many of that kind are in good condition, and required\n * (rows saved before that may lack it).\n *\n * condition is legacy: the form had a free-text Condition box until it was\n * replaced by counting only good batteries. Old reports still carry it, so it\n * stays in the type and schema, but nothing writes or shows it any more. On\n * those old reports quantity is the total count, not the good count.\n */\nexport type Battery = {\n  type: BatteryType;\n  otherType?: string;\n  quantity?: number;\n  condition?: string;\n};\n"
 },
 {
  "file": "convex/lib/spares.ts",
  "old": "/** \"3× MK (two new, one worn)\". */\nexport function batteryText(battery: Battery): string {\n  const count = battery.quantity === undefined ? \"\" : `${battery.quantity}× `;\n  const condition = battery.condition.trim();\n  return `${count}${batteryName(battery)}${condition ? ` (${condition})` : \"\"}`;\n}",
  "new": "/** \"3× MK\", where 3 is how many are in good condition. */\nexport function batteryText(battery: Battery): string {\n  const count = battery.quantity === undefined ? \"\" : `${battery.quantity}× `;\n  return `${count}${batteryName(battery)}`;\n}"
 },
 {
  "file": "convex/schema.ts",
  "old": "    drivetrain: v.string(),\n    underTrench: v.boolean(),",
  "new": "    drivetrain: v.string(),\n    /** Free text (\"L2\", \"6.75:1\"). Optional: reports written before the\n     *  field existed, or where the scout left it blank, have none. */\n    drivetrainGearing: v.optional(v.string()),\n    /** Pounds with bumpers and battery, to one decimal place, 10–200.\n     *  Optional, as drivetrainGearing. */\n    robotWeight: v.optional(v.number()),\n    underTrench: v.boolean(),"
 },
 {
  "file": "convex/schema.ts",
  "old": "      otherType: v.optional(v.string()),\n      quantity: v.optional(v.number()),\n      condition: v.string(),\n    }))),",
  "new": "      otherType: v.optional(v.string()),\n      /** How many are in good condition (the total, on older reports). */\n      quantity: v.optional(v.number()),\n      /** Legacy free text: only reports from before it was removed have it. */\n      condition: v.optional(v.string()),\n    }))),"
 },
 {
  "file": "convex/pit.ts",
  "old": "import { SPARE_PARTS, type Battery, type Spare } from \"./lib/spares\";",
  "new": "import { MAX_OTHER_SPARES, SPARE_PARTS, type Battery, type Spare } from \"./lib/spares\";"
 },
 {
  "file": "convex/pit.ts",
  "old": "  otherType: v.optional(v.string()),\n  quantity: v.optional(v.number()),\n  condition: v.string(),\n});",
  "new": "  otherType: v.optional(v.string()),\n  quantity: v.optional(v.number()),\n  // Phones still running the old bundle send it; it is ignored.\n  condition: v.optional(v.string()),\n});"
 },
 {
  "file": "convex/pit.ts",
  "old": "/**\n * A ticked spare needs to say what exactly it is; the count is an optional\n * estimate. The form checks this too, but the server is what a stale or\n * edited client cannot skip.\n */\nfunction cleanSpares(spares: Spare[]): Spare[] {\n  const seen = new Set<string>();\n  const order = new Map(SPARE_PARTS.map((p, i) => [p.part, i]));\n  return spares\n    .map((s) => {\n      if (seen.has(s.part)) throw new Error(\"Each spare part can only be listed once.\");\n      seen.add(s.part);\n      const quantity = optionalCount(s.quantity, \"Spare quantities\");\n      const specify = s.specify.trim();\n      if (specify === \"\") throw new Error(\"Say what each spare is.\");\n      if (specify.length > 200) throw new Error(\"Spare details are limited to 200 characters.\");\n      // Built field by field so an absent count is left out, not stored as undefined.\n      return quantity === undefined\n        ? { part: s.part, specify }\n        : { part: s.part, quantity, specify };\n    })\n    .sort((a, b) => (order.get(a.part) ?? 0) - (order.get(b.part) ?? 0));\n}\n\n/** A type and a count on every row, and a brand when the type is Other. */\nfunction cleanBatteries(batteries: Battery[]): Battery[] {\n  if (batteries.length > 20) throw new Error(\"List at most 20 battery types.\");\n  return batteries.map((b) => {\n    if (b.quantity === undefined) throw new Error(\"Say how many of each battery.\");\n    const quantity = optionalCount(b.quantity, \"Battery quantities\");\n    const condition = b.condition.trim();\n    if (condition.length > 200) throw new Error(\"Battery conditions are limited to 200 characters.\");\n    const row: Battery = { type: b.type, condition };\n    if (b.type === \"other\") {\n      const otherType = (b.otherType ?? \"\").trim();\n      if (otherType === \"\") throw new Error(\"Say which brand each Other battery is.\");\n      if (otherType.length > 50) throw new Error(\"Battery brands are limited to 50 characters.\");\n      row.otherType = otherType;\n    }\n    if (quantity !== undefined) row.quantity = quantity;\n    return row;\n  });\n}",
  "new": "/**\n * A spare needs to say what exactly it is; the count is an optional estimate.\n * Intake, indexer, shooter and swerve appear once at most; Other can repeat,\n * one row per thing. The form checks this too, but the server is what a stale\n * or edited client cannot skip.\n */\nfunction cleanSpares(spares: Spare[]): Spare[] {\n  const seen = new Set<string>();\n  const order = new Map(SPARE_PARTS.map((p, i) => [p.part, i]));\n  let others = 0;\n  return spares\n    .map((s) => {\n      if (s.part === \"other\") {\n        others += 1;\n        if (others > MAX_OTHER_SPARES) {\n          throw new Error(`List at most ${MAX_OTHER_SPARES} Other spares.`);\n        }\n      } else {\n        if (seen.has(s.part)) throw new Error(\"Each spare part can only be listed once.\");\n        seen.add(s.part);\n      }\n      const quantity = optionalCount(s.quantity, \"Spare quantities\");\n      const specify = s.specify.trim();\n      if (specify === \"\") throw new Error(\"Say what each spare is.\");\n      if (specify.length > 200) throw new Error(\"Spare details are limited to 200 characters.\");\n      // Built field by field so an absent count is left out, not stored as undefined.\n      return quantity === undefined\n        ? { part: s.part, specify }\n        : { part: s.part, quantity, specify };\n    })\n    // sort is stable, so several Other rows keep the order they were added in.\n    .sort((a, b) => (order.get(a.part) ?? 0) - (order.get(b.part) ?? 0));\n}\n\n/** A type and a good-condition count on every row, and a brand for Other. */\nfunction cleanBatteries(batteries: Battery[]): Battery[] {\n  if (batteries.length > 20) throw new Error(\"List at most 20 battery types.\");\n  return batteries.map((b) => {\n    if (b.quantity === undefined) {\n      throw new Error(\"Say how many of each battery are in good condition.\");\n    }\n    const quantity = optionalCount(b.quantity, \"Battery counts\");\n    // condition is no longer stored, even when an old client sends one.\n    const row: Battery = { type: b.type };\n    if (b.type === \"other\") {\n      const otherType = (b.otherType ?? \"\").trim();\n      if (otherType === \"\") throw new Error(\"Say which brand each Other battery is.\");\n      if (otherType.length > 50) throw new Error(\"Battery brands are limited to 50 characters.\");\n      row.otherType = otherType;\n    }\n    if (quantity !== undefined) row.quantity = quantity;\n    return row;\n  });\n}\n\n/** Pounds with bumpers and battery, rounded to one decimal place; null clears it. */\nfunction cleanWeight(pounds: number | null): number | undefined {\n  if (pounds === null) return undefined;\n  if (!Number.isFinite(pounds) || pounds < 10 || pounds > 200) {\n    throw new Error(\"Robot weight must be between 10 and 200 lbs.\");\n  }\n  return Math.round(pounds * 10) / 10;\n}\n\n/** Trimmed; blank clears it. */\nfunction cleanGearing(text: string): string | undefined {\n  const gearing = text.trim();\n  if (gearing.length > 100) throw new Error(\"Drivetrain gearing is limited to 100 characters.\");\n  return gearing === \"\" ? undefined : gearing;\n}"
 },
 {
  "file": "convex/pit.ts",
  "old": "    spares: v.optional(v.array(spareInput)),\n    batteries: v.optional(v.array(batteryInput)),\n  },",
  "new": "    spares: v.optional(v.array(spareInput)),\n    batteries: v.optional(v.array(batteryInput)),\n    // Optional for the same reason. null clears a weight that was set.\n    robotWeight: v.optional(v.union(v.number(), v.null())),\n    drivetrainGearing: v.optional(v.string()),\n  },"
 },
 {
  "file": "convex/pit.ts",
  "old": "      batteries: args.batteries ? cleanBatteries(args.batteries) : existing?.batteries,",
  "new": "      batteries: args.batteries ? cleanBatteries(args.batteries) : existing?.batteries,\n      robotWeight: args.robotWeight === undefined\n        ? existing?.robotWeight\n        : cleanWeight(args.robotWeight),\n      drivetrainGearing: args.drivetrainGearing === undefined\n        ? existing?.drivetrainGearing\n        : cleanGearing(args.drivetrainGearing),"
 },
 {
  "file": "convex/workbook.ts",
  "old": "          drivetrain: p.drivetrain,\n          turret: p.scoring.turret,",
  "new": "          drivetrain: p.drivetrain,\n          drivetrainGearing: p.drivetrainGearing ?? \"\",\n          robotWeightLbs: p.robotWeight ?? \"\",\n          turret: p.scoring.turret,"
 },
 {
  "file": "convex/workbook.ts",
  "old": "          batteries: (p.batteries ?? []).map(batteryText).join(\"; \"),",
  "new": "          batteriesInGoodCondition: (p.batteries ?? []).map(batteryText).join(\"; \"),"
 },
 {
  "file": "convex/exports.ts",
  "old": "        [\"team\", \"nickname\", \"scout\", \"drivetrain\", \"turret\", \"drumFullWidth\",",
  "new": "        [\"team\", \"nickname\", \"scout\", \"drivetrain\", \"drivetrainGearing\",\n         \"robotWeightLbs\", \"turret\", \"drumFullWidth\","
 },
 {
  "file": "convex/exports.ts",
  "old": "            p.drivetrain, p.scoring.turret, p.scoring.drumFullWidth,",
  "new": "            p.drivetrain, p.drivetrainGearing ?? \"\", p.robotWeight ?? \"\",\n            p.scoring.turret, p.scoring.drumFullWidth,"
 },
 {
  "file": "src/routes/teams/team-detail.tsx",
  "old": "                    Batteries: {(data.pitReport.batteries ?? []).map(batteryText).join(\" · \")}",
  "new": "                    Batteries in good condition:{\" \"}\n                    {(data.pitReport.batteries ?? []).map(batteryText).join(\" · \")}"
 },
 {
  "file": "src/routes/teams/team-detail.tsx",
  "old": "                  {data.pitReport.drivetrain || \"Drivetrain not recorded\"}\n                </p>",
  "new": "                  {[\n                    data.pitReport.drivetrain || \"Drivetrain not recorded\",\n                    data.pitReport.drivetrainGearing\n                      ? `Gearing ${data.pitReport.drivetrainGearing}`\n                      : null,\n                    data.pitReport.robotWeight !== undefined\n                      ? `${data.pitReport.robotWeight} lbs`\n                      : null,\n                  ].filter(Boolean).join(\" · \")}\n                </p>"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "import {\n  BATTERY_TYPES, SPARE_PARTS,\n  type Battery, type BatteryType, type Spare, type SparePart,\n} from \"@/lib/spares\";",
  "new": "import {\n  BATTERY_TYPES, FIXED_SPARE_PARTS, MAX_OTHER_SPARES,\n  type Battery, type BatteryType, type FixedSparePart, type Spare,\n} from \"@/lib/spares\";"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "const toCount = (text: string) => (text === \"\" ? null : Number.parseInt(text, 10));",
  "new": "const toCount = (text: string) => (text === \"\" ? null : Number.parseInt(text, 10));\n\n/** Pounds: three digits and one decimal place at most, e.g. \"112.5\". */\nfunction weightDigits(text: string): string {\n  const match = /^(\\d{0,3})(\\.\\d?)?/.exec(text.replace(/[^\\d.]/g, \"\"));\n  return match ? `${match[1] ?? \"\"}${match[2] ?? \"\"}` : \"\";\n}\n\n/** What is wrong with the weight, or null when it is fine or blank. */\nfunction weightProblem(text: string): string | null {\n  if (text === \"\") return null;\n  const pounds = Number.parseFloat(text);\n  return pounds >= 10 && pounds <= 200 ? null : \"Enter a weight between 10 and 200 lbs.\";\n}"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "  drivetrainBase: string;\n  drivetrainDetail: string;\n",
  "new": "  drivetrainBase: string;\n  drivetrainDetail: string;\n  drivetrainGearing: string;\n  robotWeight: string;\n"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "  spares: Record<SparePart, SpareRow>;\n  batteries: BatteryRow[];\n};\n\ntype SpareRow = { on: boolean; quantity: string; specify: string };\n\nconst BLANK_SPARES = Object.fromEntries(\n  SPARE_PARTS.map(({ part }) => [part, { on: false, quantity: \"\", specify: \"\" }]),\n) as Record<SparePart, SpareRow>;",
  "new": "  spares: Record<FixedSparePart, SpareRow>;\n  otherSpares: OtherSpareRow[];\n  batteries: BatteryRow[];\n};\n\ntype SpareRow = { on: boolean; quantity: string; specify: string };\n\n/** An Other spare, added with the plus. */\ntype OtherSpareRow = {\n  /** Stable React key; never saved. */\n  key: number;\n  quantity: string;\n  specify: string;\n};\n\nconst BLANK_SPARES = Object.fromEntries(\n  FIXED_SPARE_PARTS.map(({ part }) => [part, { on: false, quantity: \"\", specify: \"\" }]),\n) as Record<FixedSparePart, SpareRow>;"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "function spareProblem(row: SpareRow): string | null {\n  if (!row.on) return null;\n  return row.specify.trim() === \"\" ? \"Say what exactly.\" : null;\n}",
  "new": "function spareProblem(row: SpareRow): string | null {\n  if (!row.on) return null;\n  return row.specify.trim() === \"\" ? \"Say what exactly.\" : null;\n}\n\nlet nextOtherSpareKey = 1;\nconst blankOtherSpare = (): OtherSpareRow =>\n  ({ key: nextOtherSpareKey++, quantity: \"\", specify: \"\" });\n\n/** An Other row added by mistake and never touched is dropped on save, not an error. */\nconst otherSpareEmpty = (row: OtherSpareRow) =>\n  row.quantity === \"\" && row.specify.trim() === \"\";\n\n/** What an Other row is missing, or null when it is complete or empty. */\nfunction otherSpareProblem(row: OtherSpareRow): string | null {\n  if (otherSpareEmpty(row)) return null;\n  return row.specify.trim() === \"\" ? \"Say what exactly.\" : null;\n}"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "  otherType: string;\n  quantity: string;\n  condition: string;\n};\n\nlet nextBatteryKey = 1;\nconst blankBattery = (): BatteryRow =>\n  ({ key: nextBatteryKey++, type: \"\", otherType: \"\", quantity: \"\", condition: \"\" });\n\n/** A row added by mistake and never touched is dropped on save, not an error. */\nconst batteryEmpty = (row: BatteryRow) =>\n  row.type === \"\" && row.quantity === \"\" && row.condition.trim() === \"\";",
  "new": "  otherType: string;\n  /** How many are in good condition. */\n  quantity: string;\n};\n\nlet nextBatteryKey = 1;\nconst blankBattery = (): BatteryRow =>\n  ({ key: nextBatteryKey++, type: \"\", otherType: \"\", quantity: \"\" });\n\n/** A row added by mistake and never touched is dropped on save, not an error. */\nconst batteryEmpty = (row: BatteryRow) => row.type === \"\" && row.quantity === \"\";"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "  if (row.quantity === \"\") missing.push(\"say how many\");",
  "new": "  if (row.quantity === \"\") missing.push(\"say how many are in good condition\");"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "    quantity: b.quantity === undefined ? \"\" : String(b.quantity),\n    condition: b.condition,\n  }));\n}\n\nfunction sparesFromReport(spares: Spare[] | undefined): Record<SparePart, SpareRow> {\n  const rows = { ...BLANK_SPARES };\n  for (const s of spares ?? []) {\n    rows[s.part] = {\n      on: true,\n      quantity: s.quantity === undefined ? \"\" : String(s.quantity),\n      specify: s.specify,\n    };\n  }\n  return rows;\n}",
  "new": "    quantity: b.quantity === undefined ? \"\" : String(b.quantity),\n  }));\n}\n\n/** Older reports saved Other as a ticked box; it comes back as an Other row. */\nfunction sparesFromReport(spares: Spare[] | undefined): {\n  spares: Record<FixedSparePart, SpareRow>;\n  otherSpares: OtherSpareRow[];\n} {\n  const rows = { ...BLANK_SPARES };\n  const others: OtherSpareRow[] = [];\n  for (const s of spares ?? []) {\n    const quantity = s.quantity === undefined ? \"\" : String(s.quantity);\n    if (s.part === \"other\") {\n      others.push({ key: nextOtherSpareKey++, quantity, specify: s.specify });\n    } else {\n      rows[s.part] = { on: true, quantity, specify: s.specify };\n    }\n  }\n  return { spares: rows, otherSpares: others };\n}"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "  drivetrainBase: \"\", drivetrainDetail: \"\", underTrench: false, overBump: false,\n  robotNotes: \"\", otherNotes: \"\",\n  spares: BLANK_SPARES,\n  batteries: [],\n};",
  "new": "  drivetrainBase: \"\", drivetrainDetail: \"\", drivetrainGearing: \"\", robotWeight: \"\",\n  underTrench: false, overBump: false,\n  robotNotes: \"\", otherNotes: \"\",\n  spares: BLANK_SPARES,\n  otherSpares: [],\n  batteries: [],\n};"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "        spares: sparesFromReport(report.spares),\n        batteries: batteriesFromReport(report.batteries),",
  "new": "        drivetrainGearing: report.drivetrainGearing ?? \"\",\n        robotWeight: report.robotWeight?.toString() ?? \"\",\n        ...sparesFromReport(report.spares),\n        batteries: batteriesFromReport(report.batteries),"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "  const setSpare = (part: SparePart, patch: Partial<SpareRow>) =>",
  "new": "  const setSpare = (part: FixedSparePart, patch: Partial<SpareRow>) =>"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "      batteries: f.batteries.map((b) => (b.key === key ? { ...b, ...patch } : b)),\n    }));\n",
  "new": "      batteries: f.batteries.map((b) => (b.key === key ? { ...b, ...patch } : b)),\n    }));\n\n  const setOtherSpare = (key: number, patch: Partial<OtherSpareRow>) =>\n    setForm((f) => ({\n      ...f,\n      otherSpares: f.otherSpares.map((s) => (s.key === key ? { ...s, ...patch } : s)),\n    }));\n"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "    const badSpares = SPARE_PARTS.some(({ part }) => spareProblem(form.spares[part]) !== null);\n    const badBatteries = form.batteries.some((b) => batteryProblem(b) !== null);\n    if (badSpares || badBatteries) {\n      setShowErrors(true);\n      toast.error(\n        badSpares && badBatteries ? \"Fill in the spares and batteries\"\n          : badSpares ? \"Fill in the ticked spares\" : \"Fill in the batteries\",\n        { description: \"The rows that need something are outlined in red.\" },\n      );\n      return;\n    }",
  "new": "    const badSpares =\n      FIXED_SPARE_PARTS.some(({ part }) => spareProblem(form.spares[part]) !== null) ||\n      form.otherSpares.some((s) => otherSpareProblem(s) !== null);\n    const badBatteries = form.batteries.some((b) => batteryProblem(b) !== null);\n    const badWeight = weightProblem(form.robotWeight) !== null;\n    if (badSpares || badBatteries || badWeight) {\n      setShowErrors(true);\n      const sections = [\n        badWeight ? \"robot weight\" : null,\n        badSpares ? \"spares\" : null,\n        badBatteries ? \"batteries\" : null,\n      ].filter((s): s is string => s !== null);\n      const list = sections.length > 1\n        ? `${sections.slice(0, -1).join(\", \")} and ${sections[sections.length - 1]}`\n        : sections[0];\n      toast.error(`Check the ${list}`, {\n        description: \"What needs fixing is outlined in red.\",\n      });\n      return;\n    }"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "          : form.drivetrainBase,\n        underTrench: form.underTrench,",
  "new": "          : form.drivetrainBase,\n        drivetrainGearing: form.drivetrainGearing.trim(),\n        robotWeight: form.robotWeight === \"\"\n          ? null\n          : Math.round(Number.parseFloat(form.robotWeight) * 10) / 10,\n        underTrench: form.underTrench,"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "        spares: SPARE_PARTS\n          .filter(({ part }) => form.spares[part].on)\n          .map(({ part }) => {\n            const row = form.spares[part];\n            return {\n              part,\n              ...(row.quantity === \"\" ? {} : { quantity: Number.parseInt(row.quantity, 10) }),\n              specify: row.specify.trim(),\n            };\n          }),\n        batteries: form.batteries\n          .filter((b) => !batteryEmpty(b))\n          .map((b) => ({\n            type: b.type as BatteryType,\n            ...(b.type === \"other\" ? { otherType: b.otherType.trim() } : {}),\n            ...(b.quantity === \"\" ? {} : { quantity: Number.parseInt(b.quantity, 10) }),\n            condition: b.condition.trim(),\n          })),",
  "new": "        spares: [\n          ...FIXED_SPARE_PARTS\n            .filter(({ part }) => form.spares[part].on)\n            .map(({ part }) => {\n              const row = form.spares[part];\n              return {\n                part,\n                ...(row.quantity === \"\" ? {} : { quantity: Number.parseInt(row.quantity, 10) }),\n                specify: row.specify.trim(),\n              };\n            }),\n          ...form.otherSpares\n            .filter((s) => !otherSpareEmpty(s))\n            .map((s) => ({\n              part: \"other\" as const,\n              ...(s.quantity === \"\" ? {} : { quantity: Number.parseInt(s.quantity, 10) }),\n              specify: s.specify.trim(),\n            })),\n        ],\n        batteries: form.batteries\n          .filter((b) => !batteryEmpty(b))\n          .map((b) => ({\n            type: b.type as BatteryType,\n            ...(b.type === \"other\" ? { otherType: b.otherType.trim() } : {}),\n            ...(b.quantity === \"\" ? {} : { quantity: Number.parseInt(b.quantity, 10) }),\n          })),"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "            {form.drivetrainBase === \"Other\" ? (\n              <Input\n                placeholder=\"Describe the drivetrain\"\n                value={form.drivetrainDetail}\n                onChange={(e) => set(\"drivetrainDetail\", e.target.value)}\n              />\n            ) : null}\n          </div>\n\n            <CapabilityCheck id=\"trench\" label=\"Fits under the trench\"",
  "new": "            {form.drivetrainBase === \"Other\" ? (\n              <Input\n                placeholder=\"Describe the drivetrain\"\n                value={form.drivetrainDetail}\n                onChange={(e) => set(\"drivetrainDetail\", e.target.value)}\n              />\n            ) : null}\n          </div>\n\n          <div className=\"space-y-2\">\n            <Label htmlFor=\"drivetrain-gearing\">Drivetrain gearing</Label>\n            <Input\n              id=\"drivetrain-gearing\"\n              placeholder=\"e.g. L2, 6.75:1\"\n              maxLength={100}\n              value={form.drivetrainGearing}\n              onChange={(e) => set(\"drivetrainGearing\", e.target.value)}\n            />\n          </div>\n\n          <div className=\"space-y-2\">\n            <Label htmlFor=\"robot-weight\">Robot weight (with bumpers and battery)</Label>\n            <div className=\"relative\">\n              <Input\n                id=\"robot-weight\"\n                inputMode=\"decimal\"\n                placeholder=\"e.g. 112.5\"\n                className=\"pr-10\"\n                value={form.robotWeight}\n                aria-invalid={showErrors && weightProblem(form.robotWeight) !== null ? true : undefined}\n                onChange={(e) => set(\"robotWeight\", weightDigits(e.target.value))}\n              />\n              <span className=\"text-muted-foreground pointer-events-none absolute inset-y-0 right-3 flex items-center text-sm\">\n                lbs\n              </span>\n            </div>\n            {showErrors && weightProblem(form.robotWeight) !== null ? (\n              <p className=\"text-destructive text-xs\">{weightProblem(form.robotWeight)}</p>\n            ) : null}\n          </div>\n\n          <CapabilityCheck id=\"trench\" label=\"Fits under the trench\""
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "            Spare parts the team has in the pit. Tick a part and say what\n            exactly; Est. Qty is a rough count and can be left blank.\n          </CardDescription>\n        </CardHeader>\n        <CardContent className=\"space-y-2\">\n          {SPARE_PARTS.map(({ part, label }) => {\n            const row = form.spares[part];\n            const problem = showErrors ? spareProblem(row) : null;\n            return (\n              <div key={part}\n                className={[\n                  \"grid grid-cols-[4.5rem_minmax(0,1fr)] gap-2 rounded-lg border p-3\",\n                  \"sm:grid-cols-[minmax(0,1.3fr)_4.5rem_minmax(0,2fr)] sm:items-center\",\n                  problem ? \"border-destructive\" : \"\",\n                ].join(\" \")}>\n                <label htmlFor={`spare-${part}`}\n                  className=\"col-span-2 flex min-h-8 cursor-pointer items-center gap-3 sm:col-span-1\">\n                  <Checkbox id={`spare-${part}`} checked={row.on}\n                    onCheckedChange={(next: boolean) =>\n                      setSpare(part, next\n                        ? { on: true }\n                        : { on: false, quantity: \"\", specify: \"\" })} />\n                  <span className=\"text-base\">{label}</span>\n                </label>\n                <Input aria-label={`${label} estimated quantity`} inputMode=\"numeric\" pattern=\"[0-9]*\"\n                  placeholder=\"Est. Qty\" disabled={!row.on} value={row.quantity}\n                  onChange={(e) => setSpare(part, { quantity: positiveDigits(e.target.value) })} />\n                <Input aria-label={`${label} specifics`} placeholder=\"Specify\"\n                  disabled={!row.on} value={row.specify}\n                  aria-invalid={problem !== null && row.specify.trim() === \"\"}\n                  onChange={(e) => setSpare(part, { specify: e.target.value })} />\n                {problem ? (\n                  <p className=\"text-destructive col-span-2 text-xs sm:col-span-3\">{problem}</p>\n                ) : null}\n              </div>\n            );\n          })}\n        </CardContent>",
  "new": "            Spare parts the team has in the pit. Tick a part and say what\n            exactly; Est. Qty is a rough count and can be left blank. Add an\n            Other row for anything else.\n          </CardDescription>\n        </CardHeader>\n        <CardContent className=\"space-y-2\">\n          {FIXED_SPARE_PARTS.map(({ part, label }) => {\n            const row = form.spares[part];\n            const problem = showErrors ? spareProblem(row) : null;\n            return (\n              <div key={part}\n                className={[\n                  \"grid grid-cols-[4.5rem_minmax(0,1fr)] gap-2 rounded-lg border p-3\",\n                  // The empty fourth column lines these up with the Other rows' remove button.\n                  \"sm:grid-cols-[minmax(0,1.3fr)_4.5rem_minmax(0,2fr)_2rem] sm:items-center\",\n                  problem ? \"border-destructive\" : \"\",\n                ].join(\" \")}>\n                <label htmlFor={`spare-${part}`}\n                  className=\"col-span-2 flex min-h-8 cursor-pointer items-center gap-3 sm:col-span-1\">\n                  <Checkbox id={`spare-${part}`} checked={row.on}\n                    onCheckedChange={(next: boolean) =>\n                      setSpare(part, next\n                        ? { on: true }\n                        : { on: false, quantity: \"\", specify: \"\" })} />\n                  <span className=\"text-base\">{label}</span>\n                </label>\n                <Input aria-label={`${label} estimated quantity`} inputMode=\"numeric\" pattern=\"[0-9]*\"\n                  placeholder=\"Est. Qty\" disabled={!row.on} value={row.quantity}\n                  onChange={(e) => setSpare(part, { quantity: positiveDigits(e.target.value) })} />\n                <Input aria-label={`${label} specifics`} placeholder=\"Specify\"\n                  disabled={!row.on} value={row.specify}\n                  aria-invalid={problem !== null && row.specify.trim() === \"\"}\n                  onChange={(e) => setSpare(part, { specify: e.target.value })} />\n                {problem ? (\n                  <p className=\"text-destructive col-span-2 text-xs sm:col-span-4\">{problem}</p>\n                ) : null}\n              </div>\n            );\n          })}\n          {form.otherSpares.map((row, i) => {\n            const n = i + 1;\n            const problem = showErrors ? otherSpareProblem(row) : null;\n            return (\n              <div key={row.key}\n                className={[\n                  \"grid grid-cols-[4.5rem_minmax(0,1fr)_2rem] gap-2 rounded-lg border p-3\",\n                  \"sm:grid-cols-[minmax(0,1.3fr)_4.5rem_minmax(0,2fr)_2rem] sm:items-center\",\n                  problem ? \"border-destructive\" : \"\",\n                ].join(\" \")}>\n                <span className=\"col-span-3 flex min-h-8 items-center text-base sm:col-span-1\">\n                  Other\n                </span>\n                <Input aria-label={`Other spare ${n} estimated quantity`} inputMode=\"numeric\" pattern=\"[0-9]*\"\n                  placeholder=\"Est. Qty\" value={row.quantity}\n                  onChange={(e) => setOtherSpare(row.key, { quantity: positiveDigits(e.target.value) })} />\n                <Input aria-label={`Other spare ${n} specifics`} placeholder=\"Specify\"\n                  value={row.specify} maxLength={200}\n                  aria-invalid={problem !== null}\n                  onChange={(e) => setOtherSpare(row.key, { specify: e.target.value })} />\n                <Button size=\"icon\" variant=\"ghost\" className=\"size-8\"\n                  aria-label={`Remove other spare ${n}`}\n                  onClick={() => setForm((f) => ({\n                    ...f, otherSpares: f.otherSpares.filter((s) => s.key !== row.key),\n                  }))}>\n                  <X className=\"size-4\" />\n                </Button>\n                {problem ? (\n                  <p className=\"text-destructive col-span-3 text-xs sm:col-span-4\">{problem}</p>\n                ) : null}\n              </div>\n            );\n          })}\n          {form.otherSpares.length < MAX_OTHER_SPARES ? (\n            <button type=\"button\"\n              onClick={() => setForm((f) => ({ ...f, otherSpares: [...f.otherSpares, blankOtherSpare()] }))}\n              className=\"text-muted-foreground hover:bg-accent/50 hover:text-foreground flex min-h-12 w-full items-center gap-2 rounded-lg border border-dashed p-3 text-left text-base transition-colors\">\n              <Plus className=\"size-4\" /> Add other spare\n            </button>\n          ) : null}\n        </CardContent>"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "            One row per kind of battery the team brought. Type and Qty are required.\n          </CardDescription>\n        </CardHeader>\n        <CardContent className=\"space-y-2\">\n          {form.batteries.map((row, i) => {\n            const n = i + 1;\n            const problem = showErrors ? batteryProblem(row) : null;\n            return (\n              <div key={row.key}\n                className={[\n                  \"grid grid-cols-[4.5rem_minmax(0,1fr)_2rem] gap-2 rounded-lg border p-3\",\n                  \"sm:grid-cols-[minmax(0,1.3fr)_4.5rem_minmax(0,2fr)_2rem] sm:items-start\",\n                  problem ? \"border-destructive\" : \"\",\n                ].join(\" \")}>\n                <div className=\"col-span-3 grid gap-2 sm:col-span-1\">\n                  {/* A themed menu, not the browser's own select, which ignores the\n                      app's theme; [color-scheme:dark] only half fixed it. */}\n                  <MenuSelect label={`Battery ${n} type`} value={row.type} placeholder=\"Type\"\n                    options={BATTERY_TYPES.map((b) => ({ value: b.type, label: b.label }))}\n                    invalid={problem !== null && row.type === \"\"}\n                    className=\"h-8 w-full\"\n                    onChange={(type) =>\n                      setBattery(row.key, { type, otherType: type === \"other\" ? row.otherType : \"\" })} />\n                  {row.type === \"other\" ? (\n                    <Input aria-label={`Battery ${n} brand`} placeholder=\"Which brand?\"\n                      value={row.otherType} maxLength={50}\n                      aria-invalid={problem !== null && row.otherType.trim() === \"\"}\n                      onChange={(e) => setBattery(row.key, { otherType: e.target.value })} />\n                  ) : null}\n                </div>\n                <Input aria-label={`Battery ${n} quantity`} inputMode=\"numeric\" pattern=\"[0-9]*\"\n                  placeholder=\"Qty\" value={row.quantity}\n                  aria-invalid={problem !== null && row.quantity === \"\"}\n                  onChange={(e) => setBattery(row.key, { quantity: positiveDigits(e.target.value) })} />\n                <Input aria-label={`Battery ${n} condition`} placeholder=\"Condition\"\n                  value={row.condition} maxLength={200}\n                  onChange={(e) => setBattery(row.key, { condition: e.target.value })} />\n                <Button size=\"icon\" variant=\"ghost\" className=\"size-8\"\n                  aria-label={`Remove battery ${n}`}\n                  onClick={() => setForm((f) => ({\n                    ...f, batteries: f.batteries.filter((b) => b.key !== row.key),\n                  }))}>\n                  <X className=\"size-4\" />",
  "new": "            One row per kind of battery the team brought, with how many of\n            them are in good condition. Both are required.\n          </CardDescription>\n        </CardHeader>\n        <CardContent className=\"space-y-2\">\n          {form.batteries.map((row, i) => {\n            const n = i + 1;\n            const problem = showErrors ? batteryProblem(row) : null;\n            return (\n              <div key={row.key}\n                className={[\n                  // Phones: type on its own line, so \"# in good condition\" fits.\n                  \"grid grid-cols-[minmax(0,1fr)_2rem] items-start gap-2 rounded-lg border p-3\",\n                  \"sm:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)_2rem]\",\n                  problem ? \"border-destructive\" : \"\",\n                ].join(\" \")}>\n                <div className=\"col-span-2 grid gap-2 sm:col-span-1\">\n                  {/* A themed menu, not the browser's own select, which ignores the\n                      app's theme; [color-scheme:dark] only half fixed it. */}\n                  <MenuSelect label={`Battery ${n} type`} value={row.type} placeholder=\"Type\"\n                    options={BATTERY_TYPES.map((b) => ({ value: b.type, label: b.label }))}\n                    invalid={problem !== null && row.type === \"\"}\n                    className=\"h-8 w-full\"\n                    onChange={(type) =>\n                      setBattery(row.key, { type, otherType: type === \"other\" ? row.otherType : \"\" })} />\n                  {row.type === \"other\" ? (\n                    <Input aria-label={`Battery ${n} brand`} placeholder=\"Which brand?\"\n                      value={row.otherType} maxLength={50}\n                      aria-invalid={problem !== null && row.otherType.trim() === \"\"}\n                      onChange={(e) => setBattery(row.key, { otherType: e.target.value })} />\n                  ) : null}\n                </div>\n                <Input aria-label={`Battery ${n} number in good condition`} inputMode=\"numeric\"\n                  pattern=\"[0-9]*\" placeholder=\"# in good condition\" value={row.quantity}\n                  aria-invalid={problem !== null && row.quantity === \"\"}\n                  onChange={(e) => setBattery(row.key, { quantity: positiveDigits(e.target.value) })} />\n                <Button size=\"icon\" variant=\"ghost\" className=\"size-8\"\n                  aria-label={`Remove battery ${n}`}\n                  onClick={() => setForm((f) => ({\n                    ...f, batteries: f.batteries.filter((b) => b.key !== row.key),\n                  }))}>\n                  <X className=\"size-4\" />"
 },
 {
  "file": "src/routes/pit/form.tsx",
  "old": "                {problem ? (\n                  <p className=\"text-destructive col-span-3 text-xs sm:col-span-4\">{problem}</p>\n                ) : null}\n              </div>\n            );\n          })}\n          <button type=\"button\"\n            onClick={() => setForm((f) => ({ ...f, batteries: [...f.batteries, blankBattery()] }))}",
  "new": "                {problem ? (\n                  <p className=\"text-destructive col-span-2 text-xs sm:col-span-3\">{problem}</p>\n                ) : null}\n              </div>\n            );\n          })}\n          <button type=\"button\"\n            onClick={() => setForm((f) => ({ ...f, batteries: [...f.batteries, blankBattery()] }))}"
 }
]
PIT_EDITS_JSON

cat > "$MJS_FILE" <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";

const edits = JSON.parse(readFileSync(".pit-tweaks.json", "utf8"));
const files = new Map(); // path -> { text, crlf }

for (const { file, old, new: next } of edits) {
  if (!files.has(file)) {
    const raw = readFileSync(file, "utf8");
    files.set(file, { text: raw.replace(/\r\n/g, "\n"), crlf: raw.includes("\r\n") });
  }
  const entry = files.get(file);
  const first = entry.text.indexOf(old);
  if (first === -1 || entry.text.indexOf(old, first + 1) !== -1) {
    console.error(`ERROR: ${file} does not look like the expected version.`);
    console.error(`Could not place this edit (${first === -1 ? "not found" : "found twice"}):`);
    console.error(old.split("\n").slice(0, 4).join("\n"));
    console.error("\nNothing was changed.");
    process.exit(1);
  }
  entry.text = entry.text.slice(0, first) + next + entry.text.slice(first + old.length);
}

for (const [file, { text, crlf }] of files) {
  writeFileSync(file, crlf ? text.replace(/\n/g, "\r\n") : text);
  console.log(`${file} patched`);
}
MJS
bun "$MJS_FILE"

say "Done"
cat <<'TXT'
Next:
  1. bun run go        (pushes the schema change to Convex)
  2. bun run typecheck
  3. Open a pit report and check Mobility, Spares and Batteries.
  4. Commit, push, and deploy Convex to prod with the same schema.
TXT
