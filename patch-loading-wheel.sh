#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-loading-wheel.sh — the team's wheel spins wherever the app is loading.
#
#   * New LoadingWheel component (src/components/loading-wheel.tsx): an image
#     of the wheel that spins. If the image is missing it shows the old circle.
#   * Every spinning circle in the app is swapped for it: save/refresh buttons,
#     exports, the sign-in screen and loading toasts. Found by pattern, so it
#     also covers spinners from patches applied before or after this one —
#     re-run it after any later patch that adds one.
#   * The full-page loader (while sign-in loads) grows from 20px to 48px so
#     the wheel is recognisable; button spinners keep their size.
#
# Put the image at public/loading-wheel.png.
# Every edit is checked before anything is written, and the script is safe
# to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -d src && -d public && -f package.json ]] || {
  echo "ERROR: run from the repo root" >&2; exit 1; }
command -v bun >/dev/null || { echo "ERROR: bun not found" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# Relative on purpose: Git Bash rewrites /tmp in arguments but not inside
# the strings a script reads, so an absolute /tmp path breaks on Windows.
T=.patch-loading-wheel-tmp
rm -rf "$T"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

say "Staging files"
cat > "$T/loading-wheel.tsx" <<'PATCH_EOF'
import { LoaderCircle } from "lucide-react";
import { useState } from "react";

/**
 * The app's loading indicator: the team's wheel, spinning. Drop-in for the
 * spinning lucide circle; size it with the same classes (size-4, size-5...).
 * If public/loading-wheel.png is missing it falls back to the plain circle
 * rather than showing a broken image.
 */
export function LoadingWheel({ className }: { className?: string }) {
  const [failed, setFailed] = useState(false);
  const classes = ["shrink-0 animate-spin", className ?? ""].join(" ");
  if (failed) return <LoaderCircle aria-hidden className={classes} />;
  return (
    <img src="/loading-wheel.png" alt="" aria-hidden draggable={false}
      className={["object-contain select-none", classes].join(" ")}
      onError={() => setFailed(true)} />
  );
}
PATCH_EOF

cat > "$T/apply.mjs" <<'PATCH_EOF'
// Applies every edit in memory first and writes nothing unless all of them
// found their anchors. Safe to re-run: files already patched are skipped.
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

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

// ─── Shared component ──────────────────────────────────────────────────────

create("src/components/loading-wheel.tsx", "loading-wheel.tsx");

// ─── Every spinning circle in the app ──────────────────────────────────────
// Found by pattern rather than by file list, so it also covers spinners added
// by other patches (or not yet added) on your copy.

function tsxFiles(dir) {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name).replace(/\\/g, "/");
    if (statSync(p).isDirectory()) return tsxFiles(p);
    return p.endsWith(".tsx") ? [p] : [];
  });
}

const SPIN = /<(LoaderCircle|Loader2Icon|Loader2)\s+className="([^"]*)"\s*\/>/g;
const IMPORT = /import\s*\{([^}]*)\}\s*from\s*"lucide-react";?/;
const WHEEL_IMPORT = `import { LoadingWheel } from "@/components/loading-wheel";`;

let swapped = 0;
for (const path of tsxFiles("src")) {
  if (path === "src/components/loading-wheel.tsx") continue;
  const s = load(path);
  let n = 0;
  let next = s.replace(SPIN, (whole, _icon, cls) => {
    if (!/\banimate-spin\b/.test(cls)) return whole;      // a still icon, leave it
    n += 1;
    let rest = cls.replace(/\banimate-spin\b/, "").replace(/\s+/g, " ").trim();
    // The full-page loader was a 20px circle; the wheel needs room to read.
    if (path === "src/routes/require-auth.tsx" && /\bsize-5\b/.test(rest)) {
      rest = rest.replace(/\bsize-5\b/, "size-12").replace(/\btext-muted-foreground\b/, "").replace(/\s+/g, " ").trim();
    }
    return `<LoadingWheel className="${rest}" />`;
  });
  if (n === 0) continue;

  // Drop the lucide icons this file no longer uses.
  const m = next.match(IMPORT);
  if (m) {
    const names = m[1].split(",").map((x) => x.trim()).filter(Boolean);
    const keep = names.filter((name) =>
      !["LoaderCircle", "Loader2Icon", "Loader2"].includes(name) ||
      new RegExp(`<${name}\\b`).test(next.replace(m[0], "")));
    const replacement = keep.length > 0
      ? `import { ${keep.join(", ")} } from "lucide-react";`
      : "";
    next = next.replace(m[0], replacement);
    if (keep.length === 0) next = next.replace(/^\n/m, "");
  }
  if (!next.includes(WHEEL_IMPORT)) {
    // Right after the last import statement (single- or multi-line).
    const imports=[...next.matchAll(/^import[\s\S]*?from\s*"[^"]+";?[ \t]*$/gm)];
    if (imports.length === 0) fail(`${path}: could not find its imports.`);
    const last=imports[imports.length-1]; const at=last.index+last[0].length;
    next = next.slice(0, at) + "\n" + WHEEL_IMPORT + next.slice(at);
  }
  staged.set(path, next);
  report.push(`edit   ${path} (${n} spinner${n === 1 ? "" : "s"})`);
  swapped += n;
}

// Anything still spinning a lucide circle means the pattern missed one.
for (const path of tsxFiles("src")) {
  const s = staged.get(path) ?? load(path);
  if (/<(LoaderCircle|Loader2Icon|Loader2)\b[^>]*animate-spin/.test(s)) {
    fail(`${path}: a spinning circle was not swapped; tell Claude which line.`);
  }
}
if (swapped === 0) report.push("skip   no spinning circles left to swap");
if (!existsSync("public/loading-wheel.png")) {
  report.push("NOTE   public/loading-wheel.png is not there yet. Until it is, spinners show the old circle.");
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
