#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-plot-polish.sh — axis ticks, full-width bands, smoothing, shaded fills.
#
# The curves were truncating because samples whose required percentile fell
# outside 0-1 were skipped rather than clamped. Clamping runs them edge to
# edge, which is also correct: past that point no y value reaches the
# threshold, so the boundary genuinely sits at the axis limit.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/teams/plot.tsx ]] || { echo "ERROR: run patch-data-plot.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

cat > /tmp/pp.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/teams/plot.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("SAMPLES")) { console.log("already patched"); process.exit(0); }

// wider left pad so y tick labels have room
s = s.replace("const PAD = { l: 44, r: 10, t: 10, b: 66 };",
              "const PAD = { l: 58, r: 12, t: 14, b: 68 };\nconst SAMPLES = 120;\n\n/** Moving average. Quantiles on discrete data step; this reads as a curve. */\nfunction smooth(values: number[], window = 11): number[] {\n  const half = Math.floor(window / 2);\n  return values.map((_, i) => {\n    let sum = 0;\n    let n = 0;\n    for (let k = i - half; k <= i + half; k++) {\n      const v = values[k];\n      if (v === undefined) continue;\n      sum += v;\n      n += 1;\n    }\n    return n === 0 ? 0 : sum / n;\n  });\n}\n\ntype Pt = { x: number; y: number };\n\nfunction toPath(pts: Pt[]): string {\n  if (pts.length === 0) return \"\";\n  const first = pts[0]!;\n  let d = `M ${first.x} ${first.y}`;\n  for (let i = 1; i < pts.length; i++) {\n    const prev = pts[i - 1]!;\n    const cur = pts[i]!;\n    d += ` Q ${prev.x} ${prev.y} ${(prev.x + cur.x) / 2} ${(prev.y + cur.y) / 2}`;\n  }\n  const last = pts[pts.length - 1]!;\n  return `${d} L ${last.x} ${last.y}`;\n}");

// clamp instead of skip, sample more, smooth
const oldCurve = s.slice(s.indexOf("  const curve = (threshold: number): string => {"), s.indexOf("  const hovered = points.find"));
if (!oldCurve) fail("could not find the curve function");
s = s.replace(oldCurve, `  const curvePoints = (threshold: number): Pt[] => {
    const xsPix: number[] = [];
    const raw: number[] = [];
    for (let i = 0; i <= SAMPLES; i++) {
      const xv = xMin + ((xMax - xMin) * i) / SAMPLES;
      // Clamped, not skipped: outside 0-1 the boundary really is the axis
      // limit, and skipping left the curve dangling mid-plot.
      const needed = Math.min(1, Math.max(0, 2 * threshold - percentile(xs, xv)));
      xsPix.push(px(xv));
      raw.push(py(quantile(ys, needed)));
    }
    const smoothed = smooth(raw);
    return xsPix.map((x, i) => ({ x, y: smoothed[i] ?? 0 }));
  };

  const bandPath = (upper: Pt[], lower: Pt[]): string => {
    if (upper.length === 0 || lower.length === 0) return "";
    const back = [...lower].reverse().map((pt) => \`L \${pt.x} \${pt.y}\`).join(" ");
    return \`\${toPath(upper)} \${back} Z\`;
  };

  const thresholds = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9];
  const curves = points.length > 2 ? thresholds.map(curvePoints) : [];

  const ticks = (min: number, max: number) =>
    [0, 0.25, 0.5, 0.75, 1].map((f) => min + (max - min) * f);

`);

// shaded bands + smoothed strokes
const oldBands = s.slice(s.indexOf("            {bands && points.length > 2 ? ("), s.indexOf("            <g className=\"stroke-border\" strokeWidth=\"1\">"));
if (!oldBands) fail("could not find the band group");
s = s.replace(oldBands, `            {bands && curves.length === thresholds.length ? (
              <g>
                {/* Alternating fills so a decile reads as a region, not a gap
                    between two lines to squint at. */}
                {curves.slice(0, -1).map((lower, i) => (
                  <path key={\`band-\${i}\`}
                    d={bandPath(curves[i + 1] ?? [], lower)}
                    className="fill-foreground"
                    opacity={i % 2 === 0 ? 0.06 : 0.025} />
                ))}
                <path
                  d={\`\${toPath(curves[8] ?? [])} L \${VIEW.w - PAD.r} \${PAD.t} L \${PAD.l} \${PAD.t} Z\`}
                  fill="#eab308" opacity="0.1" />

                {curves.slice(0, -1).map((pts, i) => (
                  <path key={\`curve-\${i}\`} d={toPath(pts)} fill="none"
                    className="stroke-muted-foreground" strokeWidth={1}
                    opacity={i % 2 === 0 ? 0.4 : 0.22} />
                ))}
                <path d={toPath(curves[8] ?? [])} fill="none"
                  stroke="#eab308" strokeWidth={1.75} />
                <text x={VIEW.w - PAD.r} y={PAD.t + 10} textAnchor="end"
                  fill="#eab308" fontSize="9" fontWeight="600">90th</text>
              </g>
            ) : null}

`);

// axis ticks
const axisAnchor = `            {points.map((p, i) => {`;
if (!s.includes(axisAnchor)) fail("could not find the points group");
s = s.replace(axisAnchor, `            {points.length > 0 ? (
              <g className="fill-muted-foreground" fontSize="9">
                {ticks(xMin, xMax).map((v, i) => (
                  <g key={\`xt-\${i}\`}>
                    <line x1={px(v)} y1={VIEW.h - PAD.b} x2={px(v)} y2={VIEW.h - PAD.b + 4}
                      className="stroke-border" strokeWidth="1" />
                    <text x={px(v)} y={VIEW.h - PAD.b + 15} textAnchor="middle">
                      {Math.abs(v) >= 100 ? v.toFixed(0) : v.toFixed(1)}
                    </text>
                  </g>
                ))}
                {ticks(yMin, yMax).map((v, i) => (
                  <g key={\`yt-\${i}\`}>
                    <line x1={PAD.l - 4} y1={py(v)} x2={PAD.l} y2={py(v)}
                      className="stroke-border" strokeWidth="1" />
                    <text x={PAD.l - 7} y={py(v) + 3} textAnchor="end">
                      {Math.abs(v) >= 100 ? v.toFixed(0) : v.toFixed(1)}
                    </text>
                  </g>
                ))}
              </g>
            ) : null}

${axisAnchor}`);

// nudge the axis titles clear of the ticks
s = s.replace('<text x="14" y={(VIEW.h - PAD.b) / 2}', '<text x="12" y={(VIEW.h - PAD.b) / 2}');
s = s.replace('transform={`rotate(-90 14 ${(VIEW.h - PAD.b) / 2})`}',
              'transform={`rotate(-90 12 ${(VIEW.h - PAD.b) / 2})`}');

writeFileSync(p, s);
console.log("src/routes/teams/plot.tsx patched");
MJS
bun /tmp/pp.mjs
rm -f /tmp/pp.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
