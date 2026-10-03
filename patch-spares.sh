#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-spares.sh — spare parts on the 2026 pit form, and "Spare used".
#
#   * Pit form: a Spares section above Robot photo. Intake, Indexer rollers
#     (if applicable), Shooter parts, Swerve modules and Other, one column.
#     Ticking a part makes its Qty (positive whole number) and Specify
#     boxes required; the form's own save button checks them.
#   * Saved on the pit report as an optional `spares` list, so a phone on
#     the old app version can still save. Shown in the team modal and the
#     xlsx export's pit sheet.
#   * Broke down / Inconsistent cards: a gray "Spare used" button with a gear
#     next to Resolve. It asks which spare, then resolves the report with
#     "Spare used: ..." as the note.
#
# Every edit is checked before anything is written, and the script is safe
# to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/schema.ts && -f src/routes/pit/form.tsx ]] || {
  echo "ERROR: run from the repo root" >&2; exit 1; }
command -v bun >/dev/null || { echo "ERROR: bun not found" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# Relative on purpose: Git Bash rewrites /tmp in arguments but not inside
# the strings a script reads, so an absolute /tmp path breaks on Windows.
T=.patch-spares-tmp
rm -rf "$T"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

say "Staging files"
cat > "$T/spares.ts" <<'PATCH_EOF'
/**
 * Spare parts a team keeps in its pit, from the 2026 pit form. Shared by the
 * form, the team modal and the export.
 */

export type SparePart = "intake" | "indexer" | "shooter" | "swerve" | "other";

export type Spare = { part: SparePart; quantity: number; specify: string };

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

/** "2× Swerve modules (MK4i corner)". */
export function spareText(spare: Spare): string {
  return `${spare.quantity}× ${SPARE_SHORT[spare.part]} (${spare.specify})`;
}
PATCH_EOF

cat > "$T/spares-web.ts" <<'PATCH_EOF'
export * from "../../convex/lib/spares";
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

// ─── Convex ────────────────────────────────────────────────────────────────

create("convex/lib/spares.ts", "spares.ts");
create("src/lib/spares.ts", "spares-web.ts");

edit("convex/schema.ts", "spares: v.optional(", (s) => once(s,
  `    })),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"])
    // Each scouting team's own pit reports.`,
  `    })),
    /** Spare parts the team keeps in its pit. Optional: reports written
     *  before the spares section existed have none. */
    spares: v.optional(v.array(v.object({
      part: v.union(
        v.literal("intake"), v.literal("indexer"), v.literal("shooter"),
        v.literal("swerve"), v.literal("other"),
      ),
      quantity: v.number(),
      specify: v.string(),
    }))),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"])
    // Each scouting team's own pit reports.`,
  "schema.ts pitReports"));

edit("convex/pit.ts", "cleanSpares", (s) => {
  const w = "pit.ts";
  s = once(s, `import type { QueryCtx, MutationCtx } from "./_generated/server";`,
    `import type { QueryCtx, MutationCtx } from "./_generated/server";
import { SPARE_PARTS, type Spare } from "./lib/spares";`, w);
  s = once(s, "/**\n * One pit report per robot PER SCOUTING TEAM.",
    `const spareInput = v.object({
  part: v.union(
    v.literal("intake"), v.literal("indexer"), v.literal("shooter"),
    v.literal("swerve"), v.literal("other"),
  ),
  quantity: v.number(),
  specify: v.string(),
});

/**
 * A ticked spare needs both a count and what exactly it is; the form checks
 * this too, but the server is what a stale or edited client cannot skip.
 */
function cleanSpares(spares: Spare[]): Spare[] {
  const seen = new Set<string>();
  const order = new Map(SPARE_PARTS.map((p, i) => [p.part, i]));
  return spares
    .map((s) => {
      if (seen.has(s.part)) throw new Error("Each spare part can only be listed once.");
      seen.add(s.part);
      if (!Number.isInteger(s.quantity) || s.quantity < 1 || s.quantity > 999) {
        throw new Error("Spare quantities must be whole numbers from 1 to 999.");
      }
      const specify = s.specify.trim();
      if (specify === "") throw new Error("Say what each spare is.");
      if (specify.length > 200) throw new Error("Spare details are limited to 200 characters.");
      return { part: s.part, quantity: s.quantity, specify };
    })
    .sort((a, b) => (order.get(a.part) ?? 0) - (order.get(b.part) ?? 0));
}

/**
 * One pit report per robot PER SCOUTING TEAM.`, w);
  s = once(s, "    hopper: v.optional(hopperInput),\n  },",
    "    hopper: v.optional(hopperInput),\n    // Optional for the same reason as hopper.\n    spares: v.optional(v.array(spareInput)),\n  },", w);
  s = once(s, "      hopper: args.hopper ? cleanHopper(args.hopper) : existing?.hopper,",
    "      hopper: args.hopper ? cleanHopper(args.hopper) : existing?.hopper,\n      spares: args.spares ? cleanSpares(args.spares) : existing?.spares,", w);
  return s;
});

edit("convex/workbook.ts", "spareText", (s) => {
  const w = "workbook.ts";
  s = once(s, `import { v } from "convex/values";`,
    `import { v } from "convex/values";\nimport { spareText } from "./lib/spares";`, w);
  s = once(s, "          climbLow: p.climb.low,",
    `          spares: (p.spares ?? []).map(spareText).join("; "),\n          climbLow: p.climb.low,`, w);
  return s;
});

// ─── Pit form ──────────────────────────────────────────────────────────────

edit("src/routes/pit/form.tsx", "SPARE_PARTS", (s) => {
  const w = "pit/form.tsx";
  s = once(s, `import { Textarea } from "@/components/ui/textarea";`,
    `import { Textarea } from "@/components/ui/textarea";
import { Checkbox } from "@/components/ui/checkbox";
import { SPARE_PARTS, type Spare, type SparePart } from "@/lib/spares";`, w);
  s = once(s, "  Card, CardContent, CardHeader, CardTitle,",
    "  Card, CardContent, CardDescription, CardHeader, CardTitle,", w);
  s = once(s, "  robotNotes: string;\n  otherNotes: string;\n};",
    "  robotNotes: string;\n  otherNotes: string;\n  spares: Record<SparePart, SpareRow>;\n};", w);
  s = once(s, "const BLANK: FormState = {",
    `type SpareRow = { on: boolean; quantity: string; specify: string };

const BLANK_SPARES = Object.fromEntries(
  SPARE_PARTS.map(({ part }) => [part, { on: false, quantity: "", specify: "" }]),
) as Record<SparePart, SpareRow>;

/** Digits only, no leading zeros: the box can only ever hold a positive whole number. */
const positiveDigits = (text: string) => text.replace(/\\D/g, "").replace(/^0+/, "").slice(0, 3);

/** What a ticked spare is missing, or null when it is complete or unticked. */
function spareProblem(row: SpareRow): string | null {
  if (!row.on) return null;
  const missing: string[] = [];
  if (row.quantity === "") missing.push("how many");
  if (row.specify.trim() === "") missing.push("what exactly");
  return missing.length > 0 ? \`Say \${missing.join(" and ")}.\` : null;
}

function sparesFromReport(spares: Spare[] | undefined): Record<SparePart, SpareRow> {
  const rows = { ...BLANK_SPARES };
  for (const s of spares ?? []) {
    rows[s.part] = { on: true, quantity: String(s.quantity), specify: s.specify };
  }
  return rows;
}

const BLANK: FormState = {`, w);
  s = once(s, `  robotNotes: "", otherNotes: "",\n};`,
    `  robotNotes: "", otherNotes: "",\n  spares: BLANK_SPARES,\n};`, w);
  s = once(s,
    `        hopperExpanded: report.hopper?.expandedCapacity?.toString() ?? "",\n      });`,
    `        hopperExpanded: report.hopper?.expandedCapacity?.toString() ?? "",\n        spares: sparesFromReport(report.spares),\n      });`, w);
  s = once(s, "  const [saving, setSaving] = useState(false);\n",
    "  const [saving, setSaving] = useState(false);\n  // Problems show once someone tries to save, not while they are still typing.\n  const [showSpareErrors, setShowSpareErrors] = useState(false);\n", w);
  s = once(s,
    `  const set = <K extends keyof FormState>(key: K, value: FormState[K]) =>
    setForm((f) => ({ ...f, [key]: value }));`,
    `  const set = <K extends keyof FormState>(key: K, value: FormState[K]) =>
    setForm((f) => ({ ...f, [key]: value }));

  const setSpare = (part: SparePart, patch: Partial<SpareRow>) =>
    setForm((f) => ({ ...f, spares: { ...f.spares, [part]: { ...f.spares[part], ...patch } } }));`, w);
  s = once(s, "  const save = async () => {\n    if (!data) return;\n    setSaving(true);",
    `  const save = async () => {
    if (!data) return;
    if (SPARE_PARTS.some(({ part }) => spareProblem(form.spares[part]) !== null)) {
      setShowSpareErrors(true);
      toast.error("Fill in the ticked spares", {
        description: "Each ticked part needs how many and what exactly.",
      });
      return;
    }
    setSaving(true);`, w);
  s = once(s, "        photoId,\n        hopper: {",
    `        spares: SPARE_PARTS
          .filter(({ part }) => form.spares[part].on)
          .map(({ part }) => ({
            part,
            quantity: Number.parseInt(form.spares[part].quantity, 10),
            specify: form.spares[part].specify.trim(),
          })),
        photoId,
        hopper: {`, w);
  s = once(s, "      <Card>\n        <CardHeader><CardTitle>Robot photo</CardTitle></CardHeader>",
    `      <Card>
        <CardHeader>
          <CardTitle>Spares</CardTitle>
          <CardDescription>
            Spare parts the team has in the pit. Tick a part, then say how many
            and what exactly.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {SPARE_PARTS.map(({ part, label }) => {
            const row = form.spares[part];
            const problem = showSpareErrors ? spareProblem(row) : null;
            return (
              <div key={part}
                className={[
                  "grid grid-cols-[4.5rem_minmax(0,1fr)] gap-2 rounded-lg border p-3",
                  "sm:grid-cols-[minmax(0,1.3fr)_4.5rem_minmax(0,2fr)] sm:items-center",
                  problem ? "border-destructive" : "",
                ].join(" ")}>
                <label htmlFor={\`spare-\${part}\`}
                  className="col-span-2 flex min-h-8 cursor-pointer items-center gap-3 sm:col-span-1">
                  <Checkbox id={\`spare-\${part}\`} checked={row.on}
                    onCheckedChange={(next: boolean) =>
                      setSpare(part, next
                        ? { on: true }
                        : { on: false, quantity: "", specify: "" })} />
                  <span className="text-base">{label}</span>
                </label>
                <Input aria-label={\`\${label} quantity\`} inputMode="numeric" pattern="[0-9]*"
                  placeholder="Qty" disabled={!row.on} value={row.quantity}
                  aria-invalid={problem !== null && row.quantity === ""}
                  onChange={(e) => setSpare(part, { quantity: positiveDigits(e.target.value) })} />
                <Input aria-label={\`\${label} specifics\`} placeholder="Specify"
                  disabled={!row.on} value={row.specify}
                  aria-invalid={problem !== null && row.specify.trim() === ""}
                  onChange={(e) => setSpare(part, { specify: e.target.value })} />
                {problem ? (
                  <p className="text-destructive col-span-2 text-xs sm:col-span-3">{problem}</p>
                ) : null}
              </div>
            );
          })}
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle>Robot photo</CardTitle></CardHeader>`, w);
  return s;
});

// ─── Team modal ────────────────────────────────────────────────────────────

edit("src/routes/teams/team-detail.tsx", "spareText", (s) => {
  const w = "teams/team-detail.tsx";
  s = once(s, `import { AlertTriangle, Package, Pencil, Wrench } from "lucide-react";`,
    `import { AlertTriangle, Cog, Package, Pencil, Wrench } from "lucide-react";`, w);
  s = once(s, `import { TIER_LABELS, type Tier } from "@/lib/types";`,
    `import { TIER_LABELS, type Tier } from "@/lib/types";\nimport { spareText } from "@/lib/spares";`, w);
  s = once(s,
    `                <p className="text-sm">
                  <Wrench className="mr-1 inline size-3" />
                  {data.pitReport.drivetrain || "Drivetrain not recorded"}
                </p>`,
    `                {(data.pitReport.spares ?? []).length > 0 ? (
                  <p className="text-sm">
                    <Cog className="mr-1 inline size-3" />
                    Spares: {(data.pitReport.spares ?? []).map(spareText).join(" · ")}
                  </p>
                ) : null}
                <p className="text-sm">
                  <Wrench className="mr-1 inline size-3" />
                  {data.pitReport.drivetrain || "Drivetrain not recorded"}
                </p>`, w);
  return s;
});

// ─── Spare used ────────────────────────────────────────────────────────────

edit("src/components/attention-items.tsx", "Spare used", (s) => {
  const w = "attention-items.tsx";
  s = once(s, `import { AlertTriangle, Check, EyeOff, Wrench } from "lucide-react";`,
    `import { AlertTriangle, Check, EyeOff, Settings, Wrench } from "lucide-react";`, w);
  s = once(s, `useState<"none" | "dismissed" | "resolved">("none");`,
    `useState<"none" | "dismissed" | "resolved" | "spare">("none");`, w);
  s = once(s,
    `      kind: row.kind,
      state: mode,
      note,
    })
      .then(() => {
        toast.success(mode === "resolved" ? "Marked resolved" : "Dismissed");`,
    `      kind: row.kind,
      // A spare going in is a fix, so it resolves, with the spare as the note.
      state: mode === "spare" ? "resolved" : mode,
      note: mode === "spare" ? \`Spare used: \${note.trim()}\` : note,
    })
      .then(() => {
        toast.success(
          mode === "dismissed" ? "Dismissed"
            : mode === "spare" ? "Marked resolved · spare used"
              : "Marked resolved");`, w);
  s = once(s,
    `              <Wrench className="size-3" /> Resolve
            </Button>`,
    `              <Wrench className="size-3" /> Resolve
            </Button>
            <Button size="sm" variant="ghost" className="bg-muted hover:bg-muted/80"
              onClick={() => { setMode(mode === "spare" ? "none" : "spare"); setNote(""); }}>
              <Settings className="size-3" /> Spare used
            </Button>`, w);
  s = once(s,
    `                {mode === "resolved"
                  ? "Resolved says the problem was dealt with — a repair, a rematch, a conversation."
                  : "Dismissed says it was not really a problem."}{" "}
                Either way the note is what the next person reads.`,
    `                {mode === "spare"
                  ? "Which spare went in? Confirming resolves the report with this as its note."
                  : <>
                      {mode === "resolved"
                        ? "Resolved says the problem was dealt with — a repair, a rematch, a conversation."
                        : "Dismissed says it was not really a problem."}{" "}
                      Either way the note is what the next person reads.
                    </>}`, w);
  s = once(s, `<Input placeholder="What happened? (required)" value={note}`,
    `<Input placeholder={mode === "spare" ? "Which spare? (required)" : "What happened? (required)"} value={note}`, w);
  s = once(s, `<Button size="sm" variant={mode === "resolved" ? "secondary" : "default"}`,
    `<Button size="sm"
                variant={mode === "resolved" ? "secondary" : mode === "spare" ? "ghost" : "default"}
                className={mode === "spare" ? "bg-muted hover:bg-muted/80" : undefined}`, w);
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
  bunx convex dev   (pushes the new optional spares field on pit reports)
NEXT
