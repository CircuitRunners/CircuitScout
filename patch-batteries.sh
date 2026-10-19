#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-batteries.sh — batteries on the 2026 pit form, and an optional
# spares count.
#
#   * Pit form: a Batteries section under Spares. "Add battery type" adds a
#     row with a Type dropdown (MK, Energizer, Duracell, Other), Qty and
#     Condition. Other asks which brand. Type and Qty are required; a row
#     added and never touched is dropped on save. Rows can be removed.
#   * Spares: Qty becomes "Est. Qty" and is optional. Specify is still
#     required when a part is ticked.
#   * Saved on the pit report as an optional `batteries` list. Shown in the
#     team modal and the xlsx export's pit sheet.
#
# Needs patch-spares.sh first. Every edit is checked before anything is
# written, and the script is safe to re-run. Re-running it over the first
# version of this patch (where battery Qty was optional) makes Qty required,
# and fixes the battery dropdown in dark mode.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/schema.ts && -f src/routes/pit/form.tsx ]] || {
  echo "ERROR: run from the repo root" >&2; exit 1; }
command -v bun >/dev/null || { echo "ERROR: bun not found" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# Relative on purpose: Git Bash rewrites /tmp in arguments but not inside
# the strings a script reads, so an absolute /tmp path breaks on Windows.
T=.patch-batteries-tmp
rm -rf "$T"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

say "Staging files"
cat > "$T/spares.ts" <<'PATCH_EOF'
/**
 * Spare parts and batteries a team keeps in its pit, from the 2026 pit form.
 * Shared by the form, the team modal and the export.
 */

export type SparePart = "intake" | "indexer" | "shooter" | "swerve" | "other";

/** quantity is an estimate and optional; specify is required. */
export type Spare = { part: SparePart; quantity?: number; specify: string };

/** In the order the form lists them. */
export const SPARE_PARTS: ReadonlyArray<{ part: SparePart; label: string }> = [
  { part: "intake", label: "Intake" },
  { part: "indexer", label: "Indexer rollers (if applicable)" },
  { part: "shooter", label: "Shooter parts" },
  { part: "swerve", label: "Swerve modules" },
  { part: "other", label: "Other" },
];

/** Short names for summaries, without the form's "(if applicable)". */
export const SPARE_SHORT: Record<SparePart, string> = {
  intake: "Intake",
  indexer: "Indexer rollers",
  shooter: "Shooter parts",
  swerve: "Swerve modules",
  other: "Other",
};

/** "~2× Swerve modules (MK4i corner)", or without the count when none was given. */
export function spareText(spare: Spare): string {
  const count = spare.quantity === undefined ? "" : `~${spare.quantity}× `;
  return `${count}${SPARE_SHORT[spare.part]} (${spare.specify})`;
}

// ─── Batteries ─────────────────────────────────────────────────────────────

export type BatteryType = "mk" | "energizer" | "duracell" | "other";

/**
 * One kind of battery. otherType is the typed-in brand, only for "other".
 * quantity and condition are optional. The same type can appear twice, so
 * a team can list new and worn batteries separately.
 */
export type Battery = {
  type: BatteryType;
  otherType?: string;
  quantity?: number;
  condition: string;
};

/** In the order the dropdown lists them. */
export const BATTERY_TYPES: ReadonlyArray<{ type: BatteryType; label: string }> = [
  { type: "mk", label: "MK" },
  { type: "energizer", label: "Energizer" },
  { type: "duracell", label: "Duracell" },
  { type: "other", label: "Other" },
];

export function batteryName(battery: Battery): string {
  if (battery.type === "other") return battery.otherType?.trim() || "Other";
  return BATTERY_TYPES.find((b) => b.type === battery.type)?.label ?? battery.type;
}

/** "3× MK (two new, one worn)". */
export function batteryText(battery: Battery): string {
  const count = battery.quantity === undefined ? "" : `${battery.quantity}× `;
  const condition = battery.condition.trim();
  return `${count}${batteryName(battery)}${condition ? ` (${condition})` : ""}`;
}
PATCH_EOF

cat > "$T/apply.mjs" <<'PATCH_EOF'
// Applies every edit in memory first and writes nothing unless all of them
// found their anchors. Safe to re-run: files already patched are skipped.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

const T = process.argv[2];
const staged = new Map();
const eol = new Map();
const report = [];
const fail = (message) => {
  console.error(`\nERROR: ${message}\nNothing was written.`);
  process.exit(1);
};

// Windows checkouts can carry CRLF. Match on LF, write back what was there.
function load(path) {
  if (staged.has(path)) return staged.get(path);
  if (!existsSync(path)) fail(`${path} not found. Run this from the repo root.`);
  const raw = readFileSync(path, "utf8");
  eol.set(path, raw.includes("\r\n") ? "\r\n" : "\n");
  return raw.replace(/\r\n/g, "\n");
}
const snippet = (name) => readFileSync(`${T}/${name}`, "utf8").replace(/\r\n/g, "\n");

function count(haystack, needle) {
  let n = 0;
  for (let i = haystack.indexOf(needle); i !== -1; i = haystack.indexOf(needle, i + 1)) n += 1;
  return n;
}

function once(s, find, replace, where) {
  const n = count(s, find);
  if (n !== 1) {
    fail(`${where}: expected 1 match, found ${n}, for:\n  ${find.split("\n")[0].trim()}`);
  }
  return s.replace(find, () => replace);
}

/** Replace the block from `start` up to (not including) `end`. */
function between(s, start, end, replace, where, mustContain) {
  if (count(s, start) !== 1) fail(`${where}: could not find the start of the block to replace.`);
  const from = s.indexOf(start);
  const to = s.indexOf(end, from);
  if (to === -1) fail(`${where}: could not find the end of the block to replace.`);
  if (mustContain && !s.slice(from, to).includes(mustContain)) {
    fail(`${where}: the block found does not look like the expected one.`);
  }
  return s.slice(0, from) + replace + s.slice(to);
}

/** Replace the first `find` after a unique `anchor`. */
function after(s, anchor, find, replace, where) {
  if (count(s, anchor) !== 1) fail(`${where}: anchor not unique.`);
  const at = s.indexOf(anchor);
  const i = s.indexOf(find, at);
  if (i === -1) fail(`${where}: nothing to replace after the anchor.`);
  return s.slice(0, i) + replace + s.slice(i + find.length);
}

function edit(path, doneMarker, fn) {
  const s = load(path);
  if (s.includes(doneMarker)) { report.push(`skip   ${path} (already patched)`); return; }
  staged.set(path, fn(s));
  report.push(`edit   ${path}`);
}

function create(path, name) {
  const content = snippet(name);
  if (existsSync(path)) {
    const current = readFileSync(path, "utf8").replace(/\r\n/g, "\n");
    if (current === content) { report.push(`skip   ${path} (already present)`); return; }
    fail(`${path} already exists with different content. Move it aside and re-run.`);
  }
  staged.set(path, content);
  eol.set(path, "\n");
  report.push(`create ${path}`);
}

// ─── Prerequisites ─────────────────────────────────────────────────────────
for (const needed of ["convex/lib/spares.ts", "src/lib/spares.ts"]) {
  if (!existsSync(needed)) fail(`${needed} is missing. Run patch-spares.sh first.`);
}

// ─── Convex ────────────────────────────────────────────────────────────────

edit("convex/lib/spares.ts", "BATTERY_TYPES", (s) => {
  if (!s.includes("export function spareText(") || !s.includes("export const SPARE_SHORT")) {
    fail("convex/lib/spares.ts has changed from the version this patch knows; not overwriting it.");
  }
  return snippet("spares.ts");
});

const PART = `part: v.union(
        v.literal("intake"), v.literal("indexer"), v.literal("shooter"),
        v.literal("swerve"), v.literal("other"),
      ),`;

edit("convex/schema.ts", "batteries: v.optional(", (s) => once(s,
  `    spares: v.optional(v.array(v.object({
      ${PART}
      quantity: v.number(),
      specify: v.string(),
    }))),`,
  `    spares: v.optional(v.array(v.object({
      ${PART}
      /** An estimate, and optional. Older reports always have one. */
      quantity: v.optional(v.number()),
      specify: v.string(),
    }))),
    /** Batteries the team brought, one row per kind. Optional: reports
     *  written before the batteries section existed have none. */
    batteries: v.optional(v.array(v.object({
      type: v.union(
        v.literal("mk"), v.literal("energizer"), v.literal("duracell"), v.literal("other"),
      ),
      otherType: v.optional(v.string()),
      quantity: v.optional(v.number()),
      condition: v.string(),
    }))),`,
  "schema.ts pitReports"));

edit("convex/pit.ts", "cleanBatteries", (s) => {
  const w = "pit.ts";
  s = once(s, `import { SPARE_PARTS, type Spare } from "./lib/spares";`,
    `import { SPARE_PARTS, type Battery, type Spare } from "./lib/spares";`, w);
  s = once(s,
    `  quantity: v.number(),
  specify: v.string(),
});

/**
 * A ticked spare needs both a count and what exactly it is; the form checks
 * this too, but the server is what a stale or edited client cannot skip.
 */`,
    `  quantity: v.optional(v.number()),
  specify: v.string(),
});

const batteryInput = v.object({
  type: v.union(
    v.literal("mk"), v.literal("energizer"), v.literal("duracell"), v.literal("other"),
  ),
  otherType: v.optional(v.string()),
  quantity: v.optional(v.number()),
  condition: v.string(),
});

/** An optional count: absent, or a whole number from 1 to 999. */
function optionalCount(n: number | undefined, what: string): number | undefined {
  if (n === undefined) return undefined;
  if (!Number.isInteger(n) || n < 1 || n > 999) {
    throw new Error(\`\${what} must be whole numbers from 1 to 999.\`);
  }
  return n;
}

/**
 * A ticked spare needs to say what exactly it is; the count is an optional
 * estimate. The form checks this too, but the server is what a stale or
 * edited client cannot skip.
 */`, w);
  s = once(s,
    `      if (!Number.isInteger(s.quantity) || s.quantity < 1 || s.quantity > 999) {
        throw new Error("Spare quantities must be whole numbers from 1 to 999.");
      }
      const specify = s.specify.trim();
      if (specify === "") throw new Error("Say what each spare is.");
      if (specify.length > 200) throw new Error("Spare details are limited to 200 characters.");
      return { part: s.part, quantity: s.quantity, specify };
    })
    .sort((a, b) => (order.get(a.part) ?? 0) - (order.get(b.part) ?? 0));
}`,
    `      const quantity = optionalCount(s.quantity, "Spare quantities");
      const specify = s.specify.trim();
      if (specify === "") throw new Error("Say what each spare is.");
      if (specify.length > 200) throw new Error("Spare details are limited to 200 characters.");
      // Built field by field so an absent count is left out, not stored as undefined.
      return quantity === undefined
        ? { part: s.part, specify }
        : { part: s.part, quantity, specify };
    })
    .sort((a, b) => (order.get(a.part) ?? 0) - (order.get(b.part) ?? 0));
}

/** A type on every row, and a brand when the type is Other. */
function cleanBatteries(batteries: Battery[]): Battery[] {
  if (batteries.length > 20) throw new Error("List at most 20 battery types.");
  return batteries.map((b) => {
    const quantity = optionalCount(b.quantity, "Battery quantities");
    const condition = b.condition.trim();
    if (condition.length > 200) throw new Error("Battery conditions are limited to 200 characters.");
    const row: Battery = { type: b.type, condition };
    if (b.type === "other") {
      const otherType = (b.otherType ?? "").trim();
      if (otherType === "") throw new Error("Say which brand each Other battery is.");
      if (otherType.length > 50) throw new Error("Battery brands are limited to 50 characters.");
      row.otherType = otherType;
    }
    if (quantity !== undefined) row.quantity = quantity;
    return row;
  });
}`, w);
  s = once(s, "    spares: v.optional(v.array(spareInput)),\n",
    "    spares: v.optional(v.array(spareInput)),\n    batteries: v.optional(v.array(batteryInput)),\n", w);
  s = once(s, "      spares: args.spares ? cleanSpares(args.spares) : existing?.spares,",
    "      spares: args.spares ? cleanSpares(args.spares) : existing?.spares,\n      batteries: args.batteries ? cleanBatteries(args.batteries) : existing?.batteries,", w);
  return s;
});

edit("convex/workbook.ts", "batteryText", (s) => {
  const w = "workbook.ts";
  s = once(s, `import { spareText } from "./lib/spares";`, `import { batteryText, spareText } from "./lib/spares";`, w);
  s = once(s, `          spares: (p.spares ?? []).map(spareText).join("; "),`,
    `          spares: (p.spares ?? []).map(spareText).join("; "),\n          batteries: (p.batteries ?? []).map(batteryText).join("; "),`, w);
  return s;
});

// ─── Pit form ──────────────────────────────────────────────────────────────

edit("src/routes/pit/form.tsx", "BATTERY_TYPES", (s) => {
  const w = "pit/form.tsx";
  s = once(s, `import { ArrowLeft, Camera, LoaderCircle } from "lucide-react";`,
    `import { ArrowLeft, Camera, LoaderCircle, Plus, X } from "lucide-react";`, w);
  s = once(s, `import { SPARE_PARTS, type Spare, type SparePart } from "@/lib/spares";`,
    `import {
  BATTERY_TYPES, SPARE_PARTS,
  type Battery, type BatteryType, type Spare, type SparePart,
} from "@/lib/spares";`, w);
  s = once(s, "  spares: Record<SparePart, SpareRow>;\n};",
    "  spares: Record<SparePart, SpareRow>;\n  batteries: BatteryRow[];\n};", w);
  s = once(s,
    `/** What a ticked spare is missing, or null when it is complete or unticked. */
function spareProblem(row: SpareRow): string | null {
  if (!row.on) return null;
  const missing: string[] = [];
  if (row.quantity === "") missing.push("how many");
  if (row.specify.trim() === "") missing.push("what exactly");
  return missing.length > 0 ? \`Say \${missing.join(" and ")}.\` : null;
}`,
    `/** What a ticked spare is missing, or null when it is complete or unticked. */
function spareProblem(row: SpareRow): string | null {
  if (!row.on) return null;
  return row.specify.trim() === "" ? "Say what exactly." : null;
}

type BatteryRow = {
  /** Stable React key; never saved. */
  key: number;
  type: BatteryType | "";
  otherType: string;
  quantity: string;
  condition: string;
};

let nextBatteryKey = 1;
const blankBattery = (): BatteryRow =>
  ({ key: nextBatteryKey++, type: "", otherType: "", quantity: "", condition: "" });

/** A row added by mistake and never touched is dropped on save, not an error. */
const batteryEmpty = (row: BatteryRow) =>
  row.type === "" && row.quantity === "" && row.condition.trim() === "";

/** What a battery row is missing, or null when it is complete or empty. */
function batteryProblem(row: BatteryRow): string | null {
  if (batteryEmpty(row)) return null;
  if (row.type === "") return "Pick a type.";
  if (row.type === "other" && row.otherType.trim() === "") return "Say which brand.";
  return null;
}

function batteriesFromReport(batteries: Battery[] | undefined): BatteryRow[] {
  return (batteries ?? []).map((b) => ({
    key: nextBatteryKey++,
    type: b.type,
    otherType: b.otherType ?? "",
    quantity: b.quantity === undefined ? "" : String(b.quantity),
    condition: b.condition,
  }));
}`, w);
  s = once(s,
    "    rows[s.part] = { on: true, quantity: String(s.quantity), specify: s.specify };",
    `    rows[s.part] = {
      on: true,
      quantity: s.quantity === undefined ? "" : String(s.quantity),
      specify: s.specify,
    };`, w);
  s = once(s, "  spares: BLANK_SPARES,\n};", "  spares: BLANK_SPARES,\n  batteries: [],\n};", w);
  s = once(s, "        spares: sparesFromReport(report.spares),",
    "        spares: sparesFromReport(report.spares),\n        batteries: batteriesFromReport(report.batteries),", w);
  // One switch now covers both sections' problems.
  if (count(s, "showSpareErrors") !== 2 || count(s, "setShowSpareErrors") !== 2) {
    fail(`${w}: the spares error state looks different from what this patch expects.`);
  }
  s = s.replaceAll("setShowSpareErrors", "setShowErrors").replaceAll("showSpareErrors", "showErrors");
  s = once(s,
    `    setForm((f) => ({ ...f, spares: { ...f.spares, [part]: { ...f.spares[part], ...patch } } }));`,
    `    setForm((f) => ({ ...f, spares: { ...f.spares, [part]: { ...f.spares[part], ...patch } } }));

  const setBattery = (key: number, patch: Partial<BatteryRow>) =>
    setForm((f) => ({
      ...f,
      batteries: f.batteries.map((b) => (b.key === key ? { ...b, ...patch } : b)),
    }));`, w);
  s = once(s,
    `    if (SPARE_PARTS.some(({ part }) => spareProblem(form.spares[part]) !== null)) {
      setShowErrors(true);
      toast.error("Fill in the ticked spares", {
        description: "Each ticked part needs how many and what exactly.",
      });
      return;
    }`,
    `    const badSpares = SPARE_PARTS.some(({ part }) => spareProblem(form.spares[part]) !== null);
    const badBatteries = form.batteries.some((b) => batteryProblem(b) !== null);
    if (badSpares || badBatteries) {
      setShowErrors(true);
      toast.error(
        badSpares && badBatteries ? "Fill in the spares and batteries"
          : badSpares ? "Fill in the ticked spares" : "Fill in the batteries",
        { description: "The rows that need something are outlined in red." },
      );
      return;
    }`, w);
  s = once(s,
    `          .map(({ part }) => ({
            part,
            quantity: Number.parseInt(form.spares[part].quantity, 10),
            specify: form.spares[part].specify.trim(),
          })),`,
    `          .map(({ part }) => {
            const row = form.spares[part];
            return {
              part,
              ...(row.quantity === "" ? {} : { quantity: Number.parseInt(row.quantity, 10) }),
              specify: row.specify.trim(),
            };
          }),
        batteries: form.batteries
          .filter((b) => !batteryEmpty(b))
          .map((b) => ({
            type: b.type as BatteryType,
            ...(b.type === "other" ? { otherType: b.otherType.trim() } : {}),
            ...(b.quantity === "" ? {} : { quantity: Number.parseInt(b.quantity, 10) }),
            condition: b.condition.trim(),
          })),`, w);
  s = once(s,
    `            Spare parts the team has in the pit. Tick a part, then say how many
            and what exactly.`,
    `            Spare parts the team has in the pit. Tick a part and say what
            exactly; Est. Qty is a rough count and can be left blank.`, w);
  s = once(s,
    `                <Input aria-label={\`\${label} quantity\`} inputMode="numeric" pattern="[0-9]*"
                  placeholder="Qty" disabled={!row.on} value={row.quantity}
                  aria-invalid={problem !== null && row.quantity === ""}
                  onChange`,
    `                <Input aria-label={\`\${label} estimated quantity\`} inputMode="numeric" pattern="[0-9]*"
                  placeholder="Est. Qty" disabled={!row.on} value={row.quantity}
                  onChange`, w);
  s = once(s,
    `      <Card>
        <CardHeader><CardTitle>Robot photo</CardTitle></CardHeader>`,
    `      <Card>
        <CardHeader>
          <CardTitle>Batteries</CardTitle>
          <CardDescription>
            One row per kind of battery the team brought. Only the type is required.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {form.batteries.map((row, i) => {
            const n = i + 1;
            const problem = showErrors ? batteryProblem(row) : null;
            return (
              <div key={row.key}
                className={[
                  "grid grid-cols-[4.5rem_minmax(0,1fr)_2rem] gap-2 rounded-lg border p-3",
                  "sm:grid-cols-[minmax(0,1.3fr)_4.5rem_minmax(0,2fr)_2rem] sm:items-start",
                  problem ? "border-destructive" : "",
                ].join(" ")}>
                <div className="col-span-3 grid gap-2 sm:col-span-1">
                  <select aria-label={\`Battery \${n} type\`} value={row.type}
                    aria-invalid={problem !== null && row.type === ""}
                    onChange={(e) => {
                      const type = e.target.value as BatteryType | "";
                      setBattery(row.key, { type, otherType: type === "other" ? row.otherType : "" });
                    }}
                    className={[
                      "border-input h-8 w-full rounded-lg border bg-transparent px-2 text-base md:text-sm",
                      "focus-visible:border-ring focus-visible:ring-ring/50 outline-none focus-visible:ring-3",
                      "aria-invalid:border-destructive dark:bg-input/30",
                      row.type === "" ? "text-muted-foreground" : "",
                    ].join(" ")}>
                    <option value="">Type</option>
                    {BATTERY_TYPES.map((b) => (
                      <option key={b.type} value={b.type}>{b.label}</option>
                    ))}
                  </select>
                  {row.type === "other" ? (
                    <Input aria-label={\`Battery \${n} brand\`} placeholder="Which brand?"
                      value={row.otherType} maxLength={50}
                      aria-invalid={problem !== null && row.otherType.trim() === ""}
                      onChange={(e) => setBattery(row.key, { otherType: e.target.value })} />
                  ) : null}
                </div>
                <Input aria-label={\`Battery \${n} quantity\`} inputMode="numeric" pattern="[0-9]*"
                  placeholder="Qty" value={row.quantity}
                  onChange={(e) => setBattery(row.key, { quantity: positiveDigits(e.target.value) })} />
                <Input aria-label={\`Battery \${n} condition\`} placeholder="Condition"
                  value={row.condition} maxLength={200}
                  onChange={(e) => setBattery(row.key, { condition: e.target.value })} />
                <Button size="icon" variant="ghost" className="size-8"
                  aria-label={\`Remove battery \${n}\`}
                  onClick={() => setForm((f) => ({
                    ...f, batteries: f.batteries.filter((b) => b.key !== row.key),
                  }))}>
                  <X className="size-4" />
                </Button>
                {problem ? (
                  <p className="text-destructive col-span-3 text-xs sm:col-span-4">{problem}</p>
                ) : null}
              </div>
            );
          })}
          <button type="button"
            onClick={() => setForm((f) => ({ ...f, batteries: [...f.batteries, blankBattery()] }))}
            className="text-muted-foreground hover:bg-accent/50 hover:text-foreground flex min-h-12 w-full items-center gap-2 rounded-lg border border-dashed p-3 text-left text-base transition-colors">
            <Plus className="size-4" /> Add battery type
          </button>
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle>Robot photo</CardTitle></CardHeader>`, w);
  return s;
});

// ─── Team modal ────────────────────────────────────────────────────────────

edit("src/routes/teams/team-detail.tsx", "batteryText", (s) => {
  const w = "teams/team-detail.tsx";
  s = once(s, `import { AlertTriangle, Cog, Package, Pencil, Wrench } from "lucide-react";`,
    `import { AlertTriangle, BatteryFull, Cog, Package, Pencil, Wrench } from "lucide-react";`, w);
  s = once(s, `import { spareText } from "@/lib/spares";`, `import { batteryText, spareText } from "@/lib/spares";`, w);
  s = once(s,
    `                    Spares: {(data.pitReport.spares ?? []).map(spareText).join(" · ")}
                  </p>
                ) : null}`,
    `                    Spares: {(data.pitReport.spares ?? []).map(spareText).join(" · ")}
                  </p>
                ) : null}
                {(data.pitReport.batteries ?? []).length > 0 ? (
                  <p className="text-sm">
                    <BatteryFull className="mr-1 inline size-3" />
                    Batteries: {(data.pitReport.batteries ?? []).map(batteryText).join(" · ")}
                  </p>
                ) : null}`, w);
  return s;
});

// ─── Battery Qty required ──────────────────────────────────────────────────
// Runs on a fresh repo (after the edits above) and on one that already ran
// the first version of this patch, where Qty was optional.

function upgrade(path, marker, fn) {
  const s = load(path);
  if (s.includes(marker)) return;
  const wasStaged = staged.has(path);
  staged.set(path, fn(s));
  if (!wasStaged) {
    const i = report.findIndex((l) => l === `skip   ${path} (already patched)`);
    if (i >= 0) report[i] = `update ${path}`;
    else report.push(`update ${path}`);
  }
}

upgrade("convex/lib/spares.ts", "quantity is required", (s) => once(s,
  " * quantity and condition are optional. The same type can appear twice, so",
  " * quantity is required (rows saved before that may lack it); condition is\n * optional. The same type can appear twice, so",
  "spares.ts battery comment"));

upgrade("convex/pit.ts", "Say how many of each battery.", (s) => {
  const w = "pit.ts";
  s = once(s, "/** A type on every row, and a brand when the type is Other. */",
    "/** A type and a count on every row, and a brand when the type is Other. */", w);
  s = once(s,
    `  return batteries.map((b) => {
    const quantity = optionalCount(b.quantity, "Battery quantities");`,
    `  return batteries.map((b) => {
    if (b.quantity === undefined) throw new Error("Say how many of each battery.");
    const quantity = optionalCount(b.quantity, "Battery quantities");`, w);
  return s;
});

upgrade("src/routes/pit/form.tsx", "Type and Qty are required.", (s) => {
  const w = "pit/form.tsx";
  s = once(s,
    `  if (batteryEmpty(row)) return null;
  if (row.type === "") return "Pick a type.";
  if (row.type === "other" && row.otherType.trim() === "") return "Say which brand.";
  return null;`,
    `  if (batteryEmpty(row)) return null;
  const missing: string[] = [];
  if (row.type === "") missing.push("pick a type");
  if (row.type === "other" && row.otherType.trim() === "") missing.push("say which brand");
  if (row.quantity === "") missing.push("say how many");
  if (missing.length === 0) return null;
  const text = missing.join(" and ");
  return \`\${text[0]!.toUpperCase()}\${text.slice(1)}.\`;`, w);
  s = once(s, "One row per kind of battery the team brought. Only the type is required.",
    "One row per kind of battery the team brought. Type and Qty are required.", w);
  s = once(s,
    `                  placeholder="Qty" value={row.quantity}
                  onChange={(e) => setBattery(row.key, { quantity: positiveDigits(e.target.value) })} />`,
    `                  placeholder="Qty" value={row.quantity}
                  aria-invalid={problem !== null && row.quantity === ""}
                  onChange={(e) => setBattery(row.key, { quantity: positiveDigits(e.target.value) })} />`, w);
  return s;
});

// ─── Dropdown in dark mode ─────────────────────────────────────────────────
// The app's dark mode is a .dark class, which native controls don't see: the
// dropdown list opened light while its text was the dark theme's light color.
// color-scheme makes the browser draw it dark, and the options take the app's
// own colors so they match either way.

upgrade("src/routes/pit/form.tsx", "[color-scheme:dark]", (s) => {
  const w = "pit/form.tsx battery dropdown";
  s = once(s, `                      "aria-invalid:border-destructive dark:bg-input/30",`,
    `                      "aria-invalid:border-destructive dark:bg-input/30 dark:[color-scheme:dark]",`, w);
  s = once(s, `                    <option value="">Type</option>`,
    `                    <option value="" className="bg-background text-muted-foreground">Type</option>`, w);
  s = once(s, `                      <option key={b.type} value={b.type}>{b.label}</option>`,
    `                      <option key={b.type} value={b.type} className="bg-background text-foreground">
                        {b.label}
                      </option>`, w);
  return s;
});

// ─── Write ─────────────────────────────────────────────────────────────────

for (const [path, content] of staged) {
  // Only when missing: Bun on Windows throws EEXIST for mkdir(".") even with
  // recursive set, which is the folder index.html sits in.
  const dir = dirname(path);
  if (dir !== "." && !existsSync(dir)) mkdirSync(dir, { recursive: true });
  writeFileSync(path, eol.get(path) === "\r\n" ? content.replace(/\n/g, "\r\n") : content);
}
console.log(report.join("\n"));
PATCH_EOF

say "Applying"
bun "$T/apply.mjs" "$T"

say "Typecheck"
if [[ -d node_modules ]]; then
  bunx tsc -b --noEmit && bunx tsc -p convex --noEmit && echo "Typecheck clean."
else
  echo "node_modules missing; run bun install, then bun run typecheck."
fi

cat <<'NEXT'

Next:
  bunx convex dev   (or your Convex deploy) BEFORE the frontend goes live:
  the new form sends spares without a count, which the old backend rejects.
NEXT
