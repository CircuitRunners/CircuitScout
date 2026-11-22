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
  invalid = false,
}: {
  label: string;
  value: number | null;
  onChange: (next: number) => void;
  min?: number;
  max?: number;
  step?: number;
  unit?: string;
  values?: ReadonlyArray<number>;
  /** Outlined in red: required and still not set when the scout tried to submit. */
  invalid?: boolean;
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
    <div className={[
      "space-y-3",
      // An outline with an offset, so the slider does not move when it appears.
      invalid ? "outline-destructive rounded-lg outline outline-offset-8" : "",
    ].join(" ")}>
      <div className="flex items-baseline justify-between">
        <span className={["text-sm font-medium", invalid ? "text-destructive" : ""].join(" ")}>
          {label}
        </span>
        <span className="text-2xl font-semibold tabular-nums">
          {value === null ? (
            <span className={[
              "text-base font-normal",
              invalid ? "text-destructive" : "text-muted-foreground",
            ].join(" ")}>
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
