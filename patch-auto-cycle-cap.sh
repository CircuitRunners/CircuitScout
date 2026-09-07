#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-auto-cycle-cap.sh — cap autonomous at 3 neutral-zone cycles.
# Enforced in the mutation as well as the UI: a client-side limit is a hint,
# not a guarantee. No schema change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/components/field-map/auto-path-editor.tsx ]] || { echo "ERROR: run track-d.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Shared constant"
cat > /tmp/c1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/lib/scoring.ts";
let s = readFileSync(p, "utf8");
if (s.includes("MAX_AUTO_CYCLES")) { console.log("already present"); process.exit(0); }
s = s.replace("export const SCOUT_WEIGHTS",
`/** Neutral-zone trips possible in a 20-second auto. */
export const MAX_AUTO_CYCLES = 3;

export const SCOUT_WEIGHTS`);
writeFileSync(p, s);
console.log("convex/lib/scoring.ts patched");
MJS
bun /tmp/c1.mjs

say "Server-side guard"
cat > /tmp/c2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/matchReports.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("MAX_AUTO_CYCLES")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { activeEvent, requireUser } from "./lib/guards";',
              'import { activeEvent, requireUser } from "./lib/guards";\nimport { MAX_AUTO_CYCLES } from "./lib/scoring";');

const submitAnchor = `    const scoutId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");`;
if (!s.includes(submitAnchor)) fail("could not find submit handler");
s = s.replace(submitAnchor, `${submitAnchor}

    if (args.auto.path.cycles.length > MAX_AUTO_CYCLES) {
      throw new Error(\`Autonomous allows at most \${MAX_AUTO_CYCLES} cycles.\`);
    }`);

const updateAnchor = `    const reason = args.reason.trim();
    if (reason === "") throw new Error("An edit reason is required.");`;
if (!s.includes(updateAnchor)) fail("could not find update handler");
s = s.replace(updateAnchor, `${updateAnchor}
    if (args.auto.path.cycles.length > MAX_AUTO_CYCLES) {
      throw new Error(\`Autonomous allows at most \${MAX_AUTO_CYCLES} cycles.\`);
    }`);

writeFileSync(p, s);
console.log("convex/matchReports.ts patched");
MJS
bun /tmp/c2.mjs

say "Map: stop accepting a fourth"
cat > /tmp/c3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

// --- field-map.tsx: a "full" mode that stops lane taps but still allows
//     correcting the start position ---
let m = readFileSync("src/components/field-map/field-map.tsx", "utf8");
if (!m.includes('kind: "full"')) {
  m = m.replace(`type Mode =
  | { kind: "start" }
  | { kind: "outbound" }
  | { kind: "inbound"; outbound: Lane };`,
`type Mode =
  | { kind: "start" }
  | { kind: "outbound" }
  | { kind: "inbound"; outbound: Lane }
  | { kind: "full" };`);
  m = m.replace("  const pickingLane = mode.kind !== \"start\";",
`  const pickingLane = mode.kind === "outbound" || mode.kind === "inbound";
  // The start position stays correctable at any point except mid-cycle.
  const pickingStart = mode.kind === "start" || mode.kind === "full";`);
  m = m.replace(`            onClick={() => mode.kind === "start" && onPickStart(position)}
            className={mode.kind === "start" ? "cursor-pointer" : ""}>`,
`            onClick={() => pickingStart && onPickStart(position)}
            className={pickingStart ? "cursor-pointer" : ""}>`);
  m = m.replace(`                mode.kind === "start" && !chosen ? "stroke-primary" : "",`,
                `                pickingStart && !chosen ? "stroke-primary" : "",`);
  writeFileSync("src/components/field-map/field-map.tsx", m);
  console.log("src/components/field-map/field-map.tsx patched");
} else { console.log("field-map already patched"); }

// --- editor ---
let e = readFileSync("src/components/field-map/auto-path-editor.tsx", "utf8");
if (e.includes("MAX_AUTO_CYCLES")) { console.log("editor already patched"); process.exit(0); }

e = e.replace('import { useUIStore } from "@/stores/ui-store";',
              'import { useUIStore } from "@/stores/ui-store";\nimport { MAX_AUTO_CYCLES } from "@/lib/scoring";');

const oldMode = `  const mode = start === null
    ? ({ kind: "start" } as const)
    : pending === null
      ? ({ kind: "outbound" } as const)
      : ({ kind: "inbound", outbound: pending } as const);

  const pickLane = (lane: Lane) => {
    if (pending === null) { setPending(lane); return; }
    onCyclesChange([...cycles, { outbound: pending, inbound: lane }]);
    setPending(null);
  };`;
if (!e.includes(oldMode)) fail("could not find the editor mode logic");
e = e.replace(oldMode, `  const full = cycles.length >= MAX_AUTO_CYCLES;

  const mode = start === null
    ? ({ kind: "start" } as const)
    : full && pending === null
      ? ({ kind: "full" } as const)
      : pending === null
        ? ({ kind: "outbound" } as const)
        : ({ kind: "inbound", outbound: pending } as const);

  const pickLane = (lane: Lane) => {
    if (pending === null) {
      if (full) return;
      setPending(lane);
      return;
    }
    onCyclesChange([...cycles, { outbound: pending, inbound: lane }]);
    setPending(null);
  };`);

const oldPrompt = `  const prompt =
    start === null
      ? "Tap where the robot lined up."
      : pending === null
        ? \`Tap the lane it went out through. \${cycles.length} cycle\${cycles.length === 1 ? "" : "s"} so far.\`
        : \`Out through \${LANE_LABEL[pending]}. Now tap the lane it came back through.\`;`;
if (!e.includes(oldPrompt)) fail("could not find the prompt");
e = e.replace(oldPrompt, `  const prompt =
    start === null
      ? "Tap where the robot lined up."
      : full && pending === null
        ? \`\${MAX_AUTO_CYCLES} cycles recorded — the most auto allows. Remove one below to change it.\`
        : pending === null
          ? \`Tap the lane it went out through. \${cycles.length} of \${MAX_AUTO_CYCLES} cycles.\`
          : \`Out through \${LANE_LABEL[pending]}. Now tap the lane it came back through.\`;`);

const oldAdd = `              <Button variant="outline" className="h-12 w-full"
                onClick={() => onCyclesChange([...cycles,
                  { outbound: "bump-left", inbound: "bump-left" }])}>
                Add cycle
              </Button>`;
if (!e.includes(oldAdd)) fail("could not find the add cycle button");
e = e.replace(oldAdd, `              <Button variant="outline" className="h-12 w-full" disabled={full}
                onClick={() => onCyclesChange([...cycles,
                  { outbound: "bump-left", inbound: "bump-left" }])}>
                {full ? \`Maximum \${MAX_AUTO_CYCLES} cycles\` : "Add cycle"}
              </Button>`);

writeFileSync("src/components/field-map/auto-path-editor.tsx", e);
console.log("src/components/field-map/auto-path-editor.tsx patched");
MJS
bun /tmp/c3.mjs
rm -f /tmp/c1.mjs /tmp/c2.mjs /tmp/c3.mjs

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
