#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-data-plot.sh — scatter plot with selectable axes and decile bands.
#
# No new Convex functions: stats.forEvent, teams.listWithStatus and
# statbotics.forEvent already carry everything, and joining them on the client
# keeps this page from adding load to queries other screens depend on.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/teams/index.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
mkdir -p src/routes/teams

say "Plot page"
cat > src/routes/teams/plot.tsx <<'EOF'
import { useQuery } from "convex/react";
import { ArrowLeft } from "lucide-react";
import { useMemo, useState } from "react";
import { Link, useNavigate } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Button } from "@/components/ui/button";

type Source = "scouting" | "epa";

type Metric = {
  key: string;
  label: string;
  source: Source;
  get: (row: Row) => number | null;
};

type Row = {
  teamNumber: number;
  nickname: string;
  reportCount: number;
  stats: Record<string, number> | null;
  epa: { epa: number; autoEpa: number | null; teleopEpa: number | null; endgameEpa: number | null } | null;
};

const s = (key: string): Metric["get"] =>
  (row) => (row.stats && row.reportCount > 0 ? (row.stats[key] ?? null) : null);

const METRICS: ReadonlyArray<Metric> = [
  { key: "avgTotalFuel", label: "Avg total fuel", source: "scouting", get: s("avgTotalFuel") },
  { key: "avgAutoFuel", label: "Avg auto fuel", source: "scouting", get: s("avgAutoFuel") },
  { key: "avgTeleopFuel", label: "Avg teleop fuel", source: "scouting", get: s("avgTeleopFuel") },
  { key: "avgEndgameFuel", label: "Avg endgame fuel", source: "scouting", get: s("avgEndgameFuel") },
  { key: "avgUncountedFuel", label: "Avg dead-hub fuel", source: "scouting", get: s("avgUncountedFuel") },
  { key: "avgClimbPoints", label: "Avg climb points", source: "scouting", get: s("avgClimbPoints") },
  { key: "avgDriver", label: "Avg driver", source: "scouting", get: s("avgDriver") },
  { key: "avgDefense", label: "Avg defense", source: "scouting", get: s("avgDefense") },
  { key: "avgAccuracy", label: "Avg accuracy", source: "scouting", get: s("avgAccuracy") },
  { key: "avgBps", label: "Avg BPS", source: "scouting", get: s("avgBps") },
  { key: "avgAdjustedBps", label: "Adjusted BPS", source: "scouting", get: s("avgAdjustedBps") },
  { key: "reportCount", label: "Report count", source: "scouting", get: (r) => r.reportCount },
  { key: "epa", label: "EPA total", source: "epa", get: (r) => r.epa?.epa ?? null },
  { key: "epaAuto", label: "EPA auto", source: "epa", get: (r) => r.epa?.autoEpa ?? null },
  { key: "epaTeleop", label: "EPA teleop", source: "epa", get: (r) => r.epa?.teleopEpa ?? null },
  { key: "epaEndgame", label: "EPA endgame", source: "epa", get: (r) => r.epa?.endgameEpa ?? null },
];

/** Fraction of values at or below v. Rank-based, so units never matter. */
function percentile(sorted: number[], v: number): number {
  if (sorted.length <= 1) return 0.5;
  let count = 0;
  for (const x of sorted) if (x <= v) count += 1;
  return (count - 1) / (sorted.length - 1);
}

/** Value at a given percentile, linearly interpolated. */
function quantile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.max(0, p * (sorted.length - 1)));
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  const a = sorted[lo] ?? 0;
  const b = sorted[hi] ?? a;
  return a + (b - a) * (idx - lo);
}

const VIEW = { w: 520, h: 384 };
const PAD = { l: 44, r: 10, t: 10, b: 66 };

export default function PlotPage() {
  const teams = useQuery(api.teams.listWithStatus);
  const stats = useQuery(api.stats.forEvent);
  const epaData = useQuery(api.statbotics.forEvent);
  const navigate = useNavigate();

  const [xKey, setXKey] = useState("avgTotalFuel");
  const [yKey, setYKey] = useState("avgClimbPoints");
  const [bands, setBands] = useState(true);
  const [hover, setHover] = useState<number | null>(null);

  const xMetric = METRICS.find((m) => m.key === xKey) ?? METRICS[0]!;
  const yMetric = METRICS.find((m) => m.key === yKey) ?? METRICS[1]!;

  const rows: Row[] = useMemo(() => {
    const epaByTeam = new Map((epaData?.rows ?? []).map((r) => [r.teamNumber, r]));
    return (teams ?? []).map((t) => ({
      teamNumber: t.number,
      nickname: t.nickname,
      reportCount: t.reportCount,
      stats: (stats?.[t._id] as unknown as Record<string, number>) ?? null,
      epa: epaByTeam.get(t.number) ?? null,
    }));
  }, [teams, stats, epaData]);

  const plotted = rows.flatMap((row) => {
    const x = xMetric.get(row);
    const y = yMetric.get(row);
    return x === null || y === null ? [] : [{ row, x, y }];
  });
  const missing = rows.filter((row) => xMetric.get(row) === null || yMetric.get(row) === null);

  const xs = plotted.map((p) => p.x).sort((a, b) => a - b);
  const ys = plotted.map((p) => p.y).sort((a, b) => a - b);
  const xMin = xs[0] ?? 0;
  const xMax = xs[xs.length - 1] ?? 1;
  const yMin = ys[0] ?? 0;
  const yMax = ys[ys.length - 1] ?? 1;

  const px = (v: number) =>
    PAD.l + ((v - xMin) / (xMax - xMin || 1)) * (VIEW.w - PAD.l - PAD.r);
  const py = (v: number) =>
    VIEW.h - PAD.b - ((v - yMin) / (yMax - yMin || 1)) * (VIEW.h - PAD.t - PAD.b);

  const points = plotted.map((p) => {
    const combined = (percentile(xs, p.x) + percentile(ys, p.y)) / 2;
    return { ...p, cx: px(p.x), cy: py(p.y), combined };
  });

  // Hide a label when a neighbour is close enough that the two would collide.
  // Hovering brings it back, so nothing is unreachable.
  const showLabel = points.map((p, i) =>
    !points.some((q, j) => j !== i && Math.hypot(q.cx - p.cx, q.cy - p.cy) < 34));

  /**
   * A band boundary is the set of points where the two axes' percentiles
   * average to a threshold. Walking x and solving for y draws it exactly,
   * whatever the units or distribution.
   */
  const curve = (threshold: number): string => {
    const steps = 40;
    const parts: string[] = [];
    for (let i = 0; i <= steps; i++) {
      const xv = xMin + ((xMax - xMin) * i) / steps;
      const needed = 2 * threshold - percentile(xs, xv);
      if (needed < 0 || needed > 1) continue;
      parts.push(`${parts.length === 0 ? "M" : "L"} ${px(xv)} ${py(quantile(ys, needed))}`);
    }
    return parts.join(" ");
  };

  const hovered = points.find((p) => p.row.teamNumber === hover) ?? null;

  return (
    <PageShell
      title="Data plot"
      description="Any two numeric measures against each other. Gold is the top decile once both axes are weighed together."
      actions={
        <Button variant="outline" render={<Link to="/teams" />}>
          <ArrowLeft className="size-4" /> Teams
        </Button>
      }
    >
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-muted-foreground text-xs">X</span>
        <select value={xKey} onChange={(e) => setXKey(e.target.value)}
          className="bg-background rounded-md border px-2 py-1.5 text-sm">
          {METRICS.map((m) => <option key={m.key} value={m.key}>{m.label}</option>)}
        </select>
        <span className="text-muted-foreground ml-2 text-xs">Y</span>
        <select value={yKey} onChange={(e) => setYKey(e.target.value)}
          className="bg-background rounded-md border px-2 py-1.5 text-sm">
          {METRICS.map((m) => <option key={m.key} value={m.key}>{m.label}</option>)}
        </select>
        <Button size="sm" variant={bands ? "secondary" : "outline"} className="ml-auto"
          onClick={() => setBands(!bands)}>
          Decile bands {bands ? "✓" : ""}
        </Button>
      </div>

      <div className="grid gap-3 lg:grid-cols-[1fr_150px]">
        <div className="relative rounded-xl border p-3">
          <svg viewBox={`0 0 ${VIEW.w} ${VIEW.h}`} className="w-full select-none">
            {bands && points.length > 2 ? (
              <g>
                {[0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8].map((t, i) => (
                  <path key={t} d={curve(t)} fill="none"
                    className="stroke-muted-foreground"
                    strokeWidth={1} opacity={i % 2 === 0 ? 0.35 : 0.2} />
                ))}
                <path d={curve(0.9)} fill="none" stroke="#eab308" strokeWidth={1.75} />
                <text x={VIEW.w - PAD.r} y={PAD.t + 9} textAnchor="end"
                  fill="#eab308" fontSize="9" fontWeight="600">90th</text>
              </g>
            ) : null}

            <g className="stroke-border" strokeWidth="1">
              <line x1={PAD.l} y1={VIEW.h - PAD.b} x2={VIEW.w - PAD.r} y2={VIEW.h - PAD.b} />
              <line x1={PAD.l} y1={PAD.t} x2={PAD.l} y2={VIEW.h - PAD.b} />
            </g>

            {points.map((p, i) => {
              const gold = p.combined >= 0.9;
              const isHover = hover === p.row.teamNumber;
              return (
                <g key={p.row.teamNumber}
                  onMouseEnter={() => setHover(p.row.teamNumber)}
                  onMouseLeave={() => setHover(null)}
                  onClick={() => void navigate(`/teams?team=${p.row.teamNumber}`)}
                  className="cursor-pointer">
                  {isHover ? (
                    <circle cx={p.cx} cy={p.cy} r={13} fill="none"
                      stroke={gold ? "#eab308" : "#16a34a"} strokeWidth="1.5" opacity="0.5" />
                  ) : null}
                  <circle cx={p.cx} cy={p.cy} r={isHover ? 8 : 5.5}
                    fill={gold ? "#eab308" : "#16a34a"} />
                  {showLabel[i] || isHover ? (
                    <text x={p.cx} y={p.cy + 15} textAnchor="middle" fontSize="9"
                      opacity="0.8" fill={gold ? "#eab308" : "#16a34a"}>
                      {p.row.teamNumber}
                    </text>
                  ) : null}
                </g>
              );
            })}

            <text x={(VIEW.w + PAD.l) / 2} y={VIEW.h - 28} textAnchor="middle"
              className="fill-muted-foreground" fontSize="11">{xMetric.label}</text>
            <text x="14" y={(VIEW.h - PAD.b) / 2} textAnchor="middle"
              className="fill-muted-foreground" fontSize="11"
              transform={`rotate(-90 14 ${(VIEW.h - PAD.b) / 2})`}>{yMetric.label}</text>
            {bands ? (
              <text x={(VIEW.w + PAD.l) / 2} y={VIEW.h - 8} textAnchor="middle"
                className="fill-muted-foreground" fontSize="10">
                Bands are combined percentile across both axes
              </text>
            ) : null}
          </svg>

          {hovered ? (
            <div className="bg-background pointer-events-none absolute rounded-lg border p-3 shadow-lg"
              style={{
                left: `${(hovered.cx / VIEW.w) * 100}%`,
                top: `${(hovered.cy / VIEW.h) * 100}%`,
                transform: "translate(12px, -50%)",
                minWidth: 170,
              }}>
              <p className="font-semibold">{hovered.row.teamNumber}</p>
              <p className="text-muted-foreground mb-2 text-xs">{hovered.row.nickname}</p>
              <dl className="grid grid-cols-2 gap-x-3 gap-y-0.5 text-xs">
                <dt className="text-muted-foreground">{xMetric.label}</dt>
                <dd className="text-right tabular-nums">{hovered.x.toFixed(1)}</dd>
                <dt className="text-muted-foreground">{yMetric.label}</dt>
                <dd className="text-right tabular-nums">{hovered.y.toFixed(1)}</dd>
                <dt className="text-muted-foreground">Combined</dt>
                <dd className="text-right tabular-nums">
                  {Math.round(hovered.combined * 100)}th
                </dd>
                <dt className="text-muted-foreground">Reports</dt>
                <dd className="text-right tabular-nums">{hovered.row.reportCount}</dd>
              </dl>
              <p className="text-muted-foreground mt-2 text-[10px]">Click to open the team</p>
            </div>
          ) : null}
        </div>

        {missing.length > 0 ? (
          <div className="bg-muted/40 h-fit rounded-xl border border-dashed p-3">
            <p className="text-sm font-medium">No data</p>
            <p className="text-muted-foreground mb-2 text-xs">
              Nothing to plot on these axes.
            </p>
            <div className="flex flex-wrap gap-1">
              {missing.map((row) => (
                <button key={row.teamNumber}
                  onClick={() => void navigate(`/teams?team=${row.teamNumber}`)}
                  className="rounded-md border border-green-600 px-1.5 py-0.5 text-xs text-green-600 dark:text-green-400">
                  {row.teamNumber}
                </button>
              ))}
            </div>
            {xMetric.source === "scouting" || yMetric.source === "scouting" ? (
              <p className="text-muted-foreground mt-2 text-[10px]">
                Pick EPA on both axes and these plot too.
              </p>
            ) : null}
          </div>
        ) : null}
      </div>
    </PageShell>
  );
}
EOF

say "Route and button"
cat > /tmp/dp.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const fail = (m) => { console.error(m); process.exit(1); };

let r = readFileSync("src/routes/router.tsx", "utf8");
if (!r.includes("PlotPage")) {
  r = r.replace('import ComparePage from "./teams/compare";',
                'import ComparePage from "./teams/compare";\nimport PlotPage from "./teams/plot";');
  const anchor = '              { path: "teams/compare", element: <ComparePage /> },';
  if (!r.includes(anchor)) fail("could not find the compare route");
  r = r.replace(anchor, `${anchor}\n              { path: "teams/plot", element: <PlotPage /> },`);
  writeFileSync("src/routes/router.tsx", r);
  console.log("src/routes/router.tsx patched");
}

let t = readFileSync("src/routes/teams/index.tsx", "utf8");
if (!t.includes("/teams/plot")) {
  const anchor = `        <Button variant="outline" render={<Link to="/teams/compare" />}>
          Compare teams
        </Button>`;
  if (!t.includes(anchor)) fail("could not find the compare button");
  t = t.replace(anchor, `        <div className="flex flex-col gap-2">
          <Button variant="outline" render={<Link to="/teams/compare" />}>
            Compare teams
          </Button>
          <Button variant="outline" render={<Link to="/teams/plot" />}>
            Data plot
          </Button>
        </div>`);
  writeFileSync("src/routes/teams/index.tsx", t);
  console.log("src/routes/teams/index.tsx patched");
}
MJS
bun /tmp/dp.mjs
rm -f /tmp/dp.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
