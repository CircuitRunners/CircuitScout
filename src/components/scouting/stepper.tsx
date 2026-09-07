import { Button } from "@/components/ui/button";

const DOWN = [-10, -5, -1] as const;
const UP = [1, 5, 10] as const;

/**
 * Large counter, ordered so the buttons read as a number line: the six taps
 * run -10 -5 -1 +1 +5 +10 left to right. No keyboard entry — this is tapped
 * one-handed while watching a match.
 */
export function Stepper({
  label,
  value,
  onChange,
  min = 0,
}: {
  label: string;
  value: number;
  onChange: (next: number) => void;
  min?: number;
}) {
  const bump = (delta: number) => onChange(Math.max(min, value + delta));

  return (
    <div className="space-y-3">
      <div className="flex items-baseline justify-between">
        <span className="text-sm font-medium">{label}</span>
        <span className="text-3xl font-semibold tabular-nums">{value}</span>
      </div>
      <div className="grid grid-cols-6 gap-2">
        {DOWN.map((step) => (
          <Button
            key={step}
            variant="outline"
            className="h-14 text-base"
            disabled={value <= min}
            onClick={() => bump(step)}
            aria-label={`${step} ${label}`}
          >
            {step}
          </Button>
        ))}
        {UP.map((step) => (
          <Button
            key={step}
            variant="secondary"
            className="h-14 text-base"
            onClick={() => bump(step)}
            aria-label={`Add ${step} to ${label}`}
          >
            +{step}
          </Button>
        ))}
      </div>
    </div>
  );
}
