#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-dropdowns.sh — every dropdown looks like the Teams page's Sort menu.
#
#   * New shared MenuSelect (src/components/menu-select.tsx): an outline
#     button with a chevron that opens a menu of choices, built from the same
#     dropdown-menu parts as the Teams Sort menu, so it follows the app's
#     light and dark themes.
#   * Plot: the X and Y axis pickers use it instead of native <select>s.
#   * Pit form: the battery Type picker uses it, once patch-batteries.sh is
#     in. Without it this says so; re-run after patch-batteries.sh.
#
# Every edit is checked before anything is written, and the script is safe
# to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/teams/plot.tsx && -f src/components/ui/dropdown-menu.tsx ]] || {
  echo "ERROR: run from the repo root" >&2; exit 1; }
command -v bun >/dev/null || { echo "ERROR: bun not found" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# Relative on purpose: Git Bash rewrites /tmp in arguments but not inside
# the strings a script reads, so an absolute /tmp path breaks on Windows.
T=.patch-dropdowns-tmp
rm -rf "$T"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

say "Staging files"
cat > "$T/menu-select.tsx" <<'PATCH_EOF'
import { ChevronDown } from "lucide-react";

import { Button } from "@/components/ui/button";
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuRadioGroup,
  DropdownMenuRadioItem, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

export type MenuOption<T extends string> = { value: T; label: string };

/**
 * The app's dropdown: an outline button with a chevron that opens a menu of
 * choices, built like the Teams page's Sort menu. Used instead of a native
 * <select>, which draws in the browser's own style and ignores the app's
 * light and dark themes.
 */
export function MenuSelect<T extends string>({
  label,
  value,
  options,
  onChange,
  placeholder = "Choose",
  invalid = false,
  className,
}: {
  /** What the menu picks, for screen readers ("X axis", "Battery 1 type"). */
  label: string;
  /** "" while nothing is picked; the placeholder shows instead. */
  value: T | "";
  options: ReadonlyArray<MenuOption<T>>;
  onChange: (next: T) => void;
  placeholder?: string;
  invalid?: boolean;
  className?: string;
}) {
  const current = options.find((o) => o.value === value);
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button size="sm" variant="outline"
            aria-label={current ? `${label}: ${current.label}` : label}
            aria-invalid={invalid || undefined}
            className={[
              "min-w-0 justify-between",
              current ? "" : "text-muted-foreground",
              invalid ? "border-destructive" : "",
              className ?? "",
            ].join(" ")} />
        }
      >
        <span className="truncate">{current?.label ?? placeholder}</span>
        <ChevronDown className="size-3 shrink-0" />
      </DropdownMenuTrigger>
      <DropdownMenuContent className="max-h-80 min-w-40">
        <DropdownMenuRadioGroup value={value}
          onValueChange={(next) => onChange(next as T)}>
          {options.map((o) => (
            <DropdownMenuRadioItem key={o.value} value={o.value} className="py-2.5">
              {o.label}
            </DropdownMenuRadioItem>
          ))}
        </DropdownMenuRadioGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  );
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

// ─── Shared dropdown ───────────────────────────────────────────────────────

create("src/components/menu-select.tsx", "menu-select.tsx");

// ─── Plot axes ─────────────────────────────────────────────────────────────

edit("src/routes/teams/plot.tsx", "MenuSelect", (s) => {
  const w = "teams/plot.tsx";
  s = once(s, `import { Button } from "@/components/ui/button";`,
    `import { Button } from "@/components/ui/button";\nimport { MenuSelect } from "@/components/menu-select";`, w);
  s = once(s, "/**\n * Dead-hub fuel is plotted negative",
    "const METRIC_OPTIONS = METRICS.map((m) => ({ value: m.key, label: m.label }));\n\n/**\n * Dead-hub fuel is plotted negative", w);
  s = once(s,
    `        <select value={xKey} onChange={(e) => setXKey(e.target.value)}
          className="bg-background rounded-md border px-2 py-1.5 text-sm">
          {METRICS.map((m) => <option key={m.key} value={m.key}>{m.label}</option>)}
        </select>`,
    `        <MenuSelect label="X axis" value={xKey} options={METRIC_OPTIONS} onChange={setXKey} />`, w);
  s = once(s,
    `        <select value={yKey} onChange={(e) => setYKey(e.target.value)}
          className="bg-background rounded-md border px-2 py-1.5 text-sm">
          {METRICS.map((m) => <option key={m.key} value={m.key}>{m.label}</option>)}
        </select>`,
    `        <MenuSelect label="Y axis" value={yKey} options={METRIC_OPTIONS} onChange={setYKey} />`, w);
  return s;
});

// ─── Battery type (only once patch-batteries.sh is in) ─────────────────────

{
  const path = "src/routes/pit/form.tsx";
  const s = load(path);
  const startMarker = "<select aria-label={`Battery ${n} type`}";
  if (s.includes("<MenuSelect label={`Battery ${n} type`}")) {
    report.push(`skip   ${path} (already patched)`);
  } else if (!s.includes(startMarker)) {
    report.push(`NOTE   ${path}: no battery dropdown yet. Run patch-batteries.sh, then re-run this.`);
  } else {
    if (count(s, startMarker) !== 1) fail(`${path}: more than one battery dropdown.`);
    const lineStart = s.lastIndexOf("\n", s.indexOf(startMarker)) + 1;
    const close = s.indexOf("</select>", lineStart);
    if (close === -1) fail(`${path}: the battery dropdown has no closing tag.`);
    const block = s.slice(lineStart, close + "</select>".length);
    if (!block.includes("BATTERY_TYPES.map") || !block.includes("setBattery(row.key")) {
      fail(`${path}: the battery dropdown looks different from what this patch expects.`);
    }
    const pad = " ".repeat(s.indexOf(startMarker) - lineStart);
    let next = s.slice(0, lineStart) + `${pad}{/* A themed menu, not the browser's own select, which ignores the
${pad}    app's theme; [color-scheme:dark] only half fixed it. */}
${pad}<MenuSelect label={\`Battery \${n} type\`} value={row.type} placeholder="Type"
${pad}  options={BATTERY_TYPES.map((b) => ({ value: b.type, label: b.label }))}
${pad}  invalid={problem !== null && row.type === ""}
${pad}  className="h-8 w-full"
${pad}  onChange={(type) =>
${pad}    setBattery(row.key, { type, otherType: type === "other" ? row.otherType : "" })} />` +
      s.slice(close + "</select>".length);
    next = once(next, `import { Checkbox } from "@/components/ui/checkbox";`,
      `import { Checkbox } from "@/components/ui/checkbox";\nimport { MenuSelect } from "@/components/menu-select";`, path);
    staged.set(path, next);
    report.push(`edit   ${path}`);
  }
}

// Nothing else should still be a native dropdown.
for (const path of ["src/routes/teams/plot.tsx", "src/routes/pit/form.tsx"]) {
  if (/<select[\s>]/.test(staged.get(path) ?? load(path))) {
    fail(`${path}: a native <select> is still there after this patch.`);
  }
}

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
  bunx tsc -b --noEmit && echo "Typecheck clean."
else
  echo "node_modules missing; run bun install, then bun run typecheck."
fi
