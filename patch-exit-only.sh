#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-exit-only.sh
#   1. Start position editable at any point in map mode.
#   2. The last cycle may be exit-only — the robot left and auto ended before
#      it came back.
#
# SCHEMA CHANGE: AutoCycle.inbound becomes Lane | null. Only the final cycle
# may be null, enforced in the mutation.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/components/field-map/auto-path-editor.tsx ]] || { echo "ERROR: run track-d.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Types and schema"
cat > /tmp/x1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

let t = readFileSync("convex/lib/types.ts", "utf8");
if (!t.includes("inbound: Lane | null")) {
  t = t.replace(`/** One neutral-zone trip: out through a lane, collect, back through a lane. */
export type AutoCycle = { outbound: Lane; inbound: Lane };`,
`/**
 * One neutral-zone trip. inbound is null when auto ended with the robot still
 * out there — only the final cycle may be exit-only.
 */
export type AutoCycle = { outbound: Lane; inbound: Lane | null };`);
  writeFileSync("convex/lib/types.ts", t);
  console.log("convex/lib/types.ts patched");
}

let s = readFileSync("convex/schema.ts", "utf8");
if (!s.includes("inbound: v.union(lane, v.null())")) {
  const old = "  cycles: v.array(v.object({ outbound: lane, inbound: lane })),";
  if (!s.includes(old)) fail("could not find the cycles validator in schema");
  s = s.replace(old, "  cycles: v.array(v.object({ outbound: lane, inbound: v.union(lane, v.null()) })),");
  writeFileSync("convex/schema.ts", s);
  console.log("convex/schema.ts patched");
}

let r = readFileSync("convex/matchReports.ts", "utf8");
if (!r.includes("inbound: v.union(lane, v.null())")) {
  const old = "      cycles: v.array(v.object({ outbound: lane, inbound: lane })),";
  if (!r.includes(old)) fail("could not find the cycles validator in matchReports");
  r = r.replace(old, "      cycles: v.array(v.object({ outbound: lane, inbound: v.union(lane, v.null()) })),");

  // Only the final cycle may be exit-only.
  const guard = `    if (args.auto.path.cycles.length > MAX_AUTO_CYCLES) {
      throw new Error(\`Autonomous allows at most \${MAX_AUTO_CYCLES} cycles.\`);
    }`;
  const withExit = `${guard}
    if (args.auto.path.cycles.slice(0, -1).some((c) => c.inbound === null)) {
      throw new Error("Only the final cycle can be exit-only.");
    }`;
  r = r.split(guard).join(withExit);
  writeFileSync("convex/matchReports.ts", r);
  console.log("convex/matchReports.ts patched");
}
MJS
bun /tmp/x1.mjs

say "Map: exit-only paths, start always editable"
cat > /tmp/x2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/components/field-map/field-map.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("exit-only")) { console.log("already patched"); process.exit(0); }

// 1. start is always editable — the markers sit on the starting line, well
//    clear of the lane targets on the wall, so there is nothing to mistap.
s = s.replace(`  const pickingLane = mode.kind === "outbound" || mode.kind === "inbound";
  // The start position stays correctable at any point except mid-cycle.
  const pickingStart = mode.kind === "start" || mode.kind === "full";`,
`  const pickingLane = mode.kind === "outbound" || mode.kind === "inbound";
  // Always editable. The start markers sit on the starting line, well clear of
  // the lane targets on the wall, so a stray tap cannot hit the wrong one.
  const pickingStart = true;`);

// 2. an exit-only cycle draws as a one-way arrow
const oldCycles = s.slice(
  s.indexOf("      {cycles.map((cycle, i) => {"),
  s.indexOf("      {/* hub */}"),
);
if (!oldCycles) fail("could not find the cycle rendering");
s = s.replace(oldCycles, `      {cycles.map((cycle, i) => {
        const offset = (i - (cycles.length - 1) / 2) * 5;
        const out = LANE_X[cycle.outbound] + offset;
        const exitOnly = cycle.inbound === null;
        const back = exitOnly ? out : LANE_X[cycle.inbound] + offset;
        return (
          <g key={i} className={accent} opacity={0.55}>
            <path d={\`M \${out} \${WALL_Y + 24} L \${out} \${WALL_Y - 34}\`}
              strokeWidth="2" fill="none" strokeLinecap="round" />
            {exitOnly ? (
              // No return leg: the arrow head marks where auto ended.
              <path d={\`M \${out - 5} \${WALL_Y - 28} L \${out} \${WALL_Y - 38} L \${out + 5} \${WALL_Y - 28}\`}
                strokeWidth="2" fill="none" strokeLinecap="round" />
            ) : (
              <>
                <path d={\`M \${out} \${WALL_Y - 34} L \${back} \${WALL_Y - 34}\`}
                  strokeWidth="2" fill="none" strokeLinecap="round" />
                <path d={\`M \${back} \${WALL_Y - 34} L \${back} \${WALL_Y + 24}\`}
                  strokeWidth="2" fill="none" strokeLinecap="round" />
              </>
            )}
            <circle cx={exitOnly ? out : back} cy={exitOnly ? WALL_Y - 48 : WALL_Y + 24} r="7"
              className="fill-background" />
            <text x={exitOnly ? out : back} y={exitOnly ? WALL_Y - 45 : WALL_Y + 27}
              textAnchor="middle" className="fill-foreground stroke-none text-[9px]">
              {i + 1}
            </text>
          </g>
        );
      })}

`);
writeFileSync(p, s);
console.log("src/components/field-map/field-map.tsx patched");
MJS
bun /tmp/x2.mjs

say "Editor: exit-only control"
cat > /tmp/x3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/components/field-map/auto-path-editor.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("exitOnly")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { Map, Rows3, Trash2, Undo2 } from "lucide-react";',
              'import { LogOut, Map, Rows3, Trash2, Undo2 } from "lucide-react";');

// A robot that never came back cannot start another cycle.
s = s.replace("  const full = cycles.length >= MAX_AUTO_CYCLES;",
`  const lastCycle = cycles.at(-1);
  const endedOutside = lastCycle?.inbound === null;
  // Nothing follows an exit-only cycle: auto ended with the robot still out.
  const full = cycles.length >= MAX_AUTO_CYCLES || endedOutside;`);

s = s.replace(`      : full && pending === null
        ? \`\${MAX_AUTO_CYCLES} cycles recorded — the most auto allows. Remove one below to change it.\`
        : pending === null`,
`      : endedOutside && pending === null
        ? "Auto ended with the robot still out. Remove the last cycle below to change it."
        : full && pending === null
          ? \`\${MAX_AUTO_CYCLES} cycles recorded — the most auto allows. Remove one below to change it.\`
          : pending === null`);

// exit-only button beside Cancel while a cycle is half-entered
s = s.replace(`                {pending !== null ? (
                  <Button variant="ghost" size="sm" onClick={() => setPending(null)}>
                    <Undo2 className="size-3" /> Cancel
                  </Button>
                ) : null}`,
`                {pending !== null ? (
                  <>
                    <Button variant="outline" size="sm"
                      onClick={() => {
                        onCyclesChange([...cycles, { outbound: pending, inbound: null }]);
                        setPending(null);
                      }}>
                      <LogOut className="size-3" /> Did not return
                    </Button>
                    <Button variant="ghost" size="sm" onClick={() => setPending(null)}>
                      <Undo2 className="size-3" /> Cancel
                    </Button>
                  </>
                ) : null}`);

// button mode: offer "did not return" on the final cycle only
const oldInbound = `                  <SegmentedChoice label="Back through" hint={DRIVER_HINT}
                    options={LANE_OPTIONS} value={cycle.inbound}
                    onChange={(lane) => onCyclesChange(
                      cycles.map((c, i) => (i === index ? { ...c, inbound: lane } : c)))} />`;
if (!s.includes(oldInbound)) fail("could not find the inbound picker");
s = s.replace(oldInbound, `                  <SegmentedChoice
                    label="Back through"
                    hint={DRIVER_HINT}
                    options={
                      index === cycles.length - 1
                        ? [...LANE_OPTIONS, { value: "none" as const, label: "Did not return" }]
                        : LANE_OPTIONS
                    }
                    value={cycle.inbound ?? "none"}
                    onChange={(value) => onCyclesChange(
                      cycles.map((c, i) =>
                        i === index
                          ? { ...c, inbound: value === "none" ? null : (value as Lane) }
                          : c))} />`);

// cycle list wording
s = s.replace(`                    out {LANE_LABEL[cycle.outbound]}
                    {cycle.outbound.endsWith("left") ? " L" : " R"} · back{" "}
                    {LANE_LABEL[cycle.inbound]}
                    {cycle.inbound.endsWith("left") ? " L" : " R"}`,
`                    out {LANE_LABEL[cycle.outbound]}
                    {cycle.outbound.endsWith("left") ? " L" : " R"}
                    {cycle.inbound === null ? (
                      <span className="text-muted-foreground"> · did not return</span>
                    ) : (
                      <>
                        {" · back "}
                        {LANE_LABEL[cycle.inbound]}
                        {cycle.inbound.endsWith("left") ? " L" : " R"}
                      </>
                    )}`);

writeFileSync(p, s);
console.log("src/components/field-map/auto-path-editor.tsx patched");
MJS
bun /tmp/x3.mjs
rm -f /tmp/x1.mjs /tmp/x2.mjs /tmp/x3.mjs

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
