#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-bps-steps.sh — non-uniform BPS scale.
#   even 0-10, every integer 11-23, even 24-34.  25 stops in all.
#
# A slider cannot do a variable step, so RatingScale gains an optional `values`
# list: the slider moves over the INDEX and displays the mapped value.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/components/scouting/rating-scale.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "RatingScale: explicit value lists"
cat > src/components/scouting/rating-scale.tsx <<'EOF'
import { Slider } from "@/components/ui/slider";

/**
 * `value` stays null until the scout touches it, so "not rated" is
 * distinguishable from "rated as the default" — which matters when ratings are
 * required before submit.
 *
 * Pass `values` for a non-uniform scale. The slider then moves over the index
 * and displays the mapped value, which is the only way to get a variable step.
 */
export function RatingScale({
  label,
  value,
  onChange,
  min = 1,
  max = 10,
  step = 1,
  unit = "",
  values,
}: {
  label: string;
  value: number | null;
  onChange: (next: number) => void;
  min?: number;
  max?: number;
  step?: number;
  unit?: string;
  values?: ReadonlyArray<number>;
}) {
  const useList = values !== undefined && values.length > 0;

  const first = useList ? (values[0] ?? 0) : min;
  const last = useList ? (values[values.length - 1] ?? 0) : max;

  /** Nearest stop, so a stored value that is no longer on the scale still lands somewhere sensible. */
  const nearestIndex = (target: number): number => {
    if (!useList) return 0;
    let best = 0;
    let bestGap = Infinity;
    values.forEach((candidate, i) => {
      const gap = Math.abs(candidate - target);
      if (gap < bestGap) { bestGap = gap; best = i; }
    });
    return best;
  };

  const middle = useList
    ? Math.floor(values.length / 2)
    : Math.round((min + max) / 2);

  const sliderValue = useList
    ? (value === null ? middle : nearestIndex(value))
    : (value ?? middle);

  const handle = (next: number | readonly number[]) => {
    const raw = typeof next === "number" ? next : (next[0] ?? middle);
    if (!useList) { onChange(raw); return; }
    const index = Math.min(values.length - 1, Math.max(0, Math.round(raw)));
    onChange(values[index] ?? first);
  };

  return (
    <div className="space-y-3">
      <div className="flex items-baseline justify-between">
        <span className="text-sm font-medium">{label}</span>
        <span className="text-2xl font-semibold tabular-nums">
          {value === null ? (
            <span className="text-muted-foreground text-base font-normal">
              Not set
            </span>
          ) : (
            `${value}${unit}`
          )}
        </span>
      </div>
      <Slider
        min={useList ? 0 : min}
        max={useList ? values.length - 1 : max}
        step={useList ? 1 : step}
        value={[sliderValue]}
        onValueChange={handle}
        className="py-3"
      />
      <div className="text-muted-foreground flex justify-between text-xs">
        <span>{first}{unit}</span>
        <span>{last}{unit}</span>
      </div>
    </div>
  );
}
EOF

say "Form: BPS scale"
cat > /tmp/bs.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/scout/form.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("BPS_VALUES")) { console.log("already patched"); process.exit(0); }

s = s.replace('const DRIVER_HINT =',
`/**
 * Even numbers at the extremes, every integer through the middle — resolution
 * where the readings actually cluster, coarser where they rarely land.
 */
const BPS_VALUES = [
  0, 2, 4, 6, 8, 10,
  11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
  24, 26, 28, 30, 32, 34,
] as const;

const DRIVER_HINT =`);

const anchor = `          <RatingScale
            label="Average BPS (observed)"
            value={avgBps}
            onChange={setAvgBps}
            min={0}
            max={35}
            step={1}
            unit=" bps"
          />`;
if (!s.includes(anchor)) fail("could not find the BPS slider — run patch-bps.sh first");
s = s.replace(anchor, `          <RatingScale
            label="Average BPS (observed)"
            value={avgBps}
            onChange={setAvgBps}
            values={BPS_VALUES}
            unit=" bps"
          />`);

writeFileSync(p, s);
console.log("src/routes/scout/form.tsx patched");
MJS
bun /tmp/bs.mjs
rm -f /tmp/bs.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
