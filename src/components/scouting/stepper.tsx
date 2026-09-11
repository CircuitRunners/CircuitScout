import { useState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

const DOWN = [-10, -5, -1] as const;
const UP = [1, 5, 10] as const;

/**
 * Large counter. The fixed buttons read as a number line, and the typed box
 * beside the readout covers the amounts the buttons cannot reach in one tap —
 * a scout who saw eleven fuel go in should not have to tap four times.
 */
export function Stepper({
  label,
  value,
  onChange,
  min = 0,
  downSteps = DOWN,
  upSteps = UP,
}: {
  label: string;
  value: number;
  onChange: (next: number) => void;
  min?: number;
  downSteps?: ReadonlyArray<number>;
  upSteps?: ReadonlyArray<number>;
}) {
  const [custom, setCustom] = useState("");
  const bump = (delta: number) => onChange(Math.max(min, value + delta));

  const amount = Number.parseInt(custom, 10);
  const usable = Number.isFinite(amount) && amount !== 0;

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-sm font-medium">{label}</span>
        <div className="flex items-center gap-1.5">
          <Input
            className="h-9 w-16 text-center"
            inputMode="numeric"
            placeholder="±"
            aria-label={`Custom amount for ${label}`}
            value={custom}
            onChange={(e) => setCustom(e.target.value)}
          />
          <Button variant="outline" size="icon" className="h-9 w-9"
            disabled={!usable} aria-label={`Subtract ${custom || "custom"} from ${label}`}
            onClick={() => bump(-Math.abs(amount))}>
            −
          </Button>
          <Button variant="outline" size="icon" className="h-9 w-9"
            disabled={!usable} aria-label={`Add ${custom || "custom"} to ${label}`}
            onClick={() => bump(Math.abs(amount))}>
            +
          </Button>
          <span className="ml-1 w-12 text-right text-3xl font-semibold tabular-nums">
            {value}
          </span>
        </div>
      </div>
      <div
        className="grid gap-2"
        style={{ gridTemplateColumns: `repeat(${downSteps.length + upSteps.length}, minmax(0, 1fr))` }}
      >
        {downSteps.map((step) => (
          <Button key={step} variant="outline" className="h-14 text-base"
            disabled={value <= min}
            aria-label={`${step} ${label}`}
            onClick={() => bump(step)}>
            {step}
          </Button>
        ))}
        {upSteps.map((step) => (
          <Button key={step} variant="secondary" className="h-14 text-base"
            aria-label={`Add ${step} to ${label}`}
            onClick={() => bump(step)}>
            +{step}
          </Button>
        ))}
      </div>
    </div>
  );
}
