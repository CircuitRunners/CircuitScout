import { useState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Slider } from "@/components/ui/slider";
import { STATIONS, STATION_LABELS, stationAlliance, type Station } from "@/lib/types";

/**
 * Range plus driver station. The slider is the fast path; the two number
 * inputs beneath it are the reliable one — a two-handle slider is fiddly with
 * gloves on, and typing "12" and "34" always works.
 */
export function ShiftPicker({
  maxMatch,
  busy,
  addLabel,
  onAdd,
}: {
  maxMatch: number;
  busy: boolean;
  addLabel: string;
  onAdd: (shift: { fromMatch: number; toMatch: number; station: Station }) => void;
}) {
  const [from, setFrom] = useState(1);
  const [to, setTo] = useState(Math.max(1, maxMatch));
  const [station, setStation] = useState<Station | null>(null);

  const clamp = (n: number) => Math.min(Math.max(1, n), Math.max(1, maxMatch));

  const handleSlider = (next: number | readonly number[]) => {
    if (typeof next === "number") { setFrom(clamp(next)); return; }
    setFrom(clamp(next[0] ?? 1));
    setTo(clamp(next[1] ?? maxMatch));
  };

  return (
    <div className="space-y-4">
      <div>
        <div className="flex items-baseline justify-between">
          <span className="text-sm font-medium">Match range</span>
          <span className="text-sm font-semibold tabular-nums">
            Qual {Math.min(from, to)} – {Math.max(from, to)}
          </span>
        </div>
        <Slider
          className="py-3"
          min={1}
          max={Math.max(1, maxMatch)}
          step={1}
          value={[from, to]}
          onValueChange={handleSlider}
        />
        <div className="text-muted-foreground flex justify-between text-xs tabular-nums">
          <span>1</span>
          <span>{maxMatch}</span>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-2">
        <div className="space-y-1">
          <Label htmlFor="from-match" className="text-xs">From</Label>
          <Input id="from-match" inputMode="numeric" value={String(from)}
            onChange={(e) => setFrom(clamp(Number.parseInt(e.target.value, 10) || 1))} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="to-match" className="text-xs">To</Label>
          <Input id="to-match" inputMode="numeric" value={String(to)}
            onChange={(e) => setTo(clamp(Number.parseInt(e.target.value, 10) || 1))} />
        </div>
      </div>

      <div className="space-y-2">
        <span className="text-sm font-medium">Driver station</span>
        <div className="grid grid-cols-3 gap-2">
          {STATIONS.map((s) => {
            const red = stationAlliance(s) === "red";
            const selected = station === s;
            return (
              <Button key={s} variant={selected ? "default" : "outline"}
                className={[
                  "h-11",
                  selected
                    ? red ? "bg-red-600 hover:bg-red-600" : "bg-blue-600 hover:bg-blue-600"
                    : red ? "text-red-600 dark:text-red-400" : "text-blue-600 dark:text-blue-400",
                ].join(" ")}
                onClick={() => setStation(s)}>
                {STATION_LABELS[s]}
              </Button>
            );
          })}
        </div>
      </div>

      <Button className="w-full" disabled={busy || station === null}
        onClick={() => {
          if (station === null) return;
          onAdd({
            fromMatch: Math.min(from, to),
            toMatch: Math.max(from, to),
            station,
          });
        }}>
        {addLabel}
      </Button>
    </div>
  );
}

export function ShiftRow({
  fromMatch, toMatch, station, trailing, onRemove,
}: {
  fromMatch: number;
  toMatch: number;
  station: Station;
  trailing?: string;
  onRemove?: () => void;
}) {
  const red = stationAlliance(station) === "red";
  return (
    <div className={[
      "flex items-center gap-2 rounded-r-lg border-l-[3px] py-2 pr-2 pl-3 text-sm",
      red ? "border-red-600 bg-red-500/10" : "border-blue-600 bg-blue-500/10",
    ].join(" ")}>
      <span className="flex-1 tabular-nums">Qual {fromMatch} – {toMatch}</span>
      <span className={[
        "text-xs font-medium",
        red ? "text-red-600 dark:text-red-400" : "text-blue-600 dark:text-blue-400",
      ].join(" ")}>
        {STATION_LABELS[station]}
      </span>
      {trailing ? (
        <span className="text-muted-foreground text-xs tabular-nums">{trailing}</span>
      ) : null}
      {onRemove ? (
        <Button size="icon" variant="ghost" aria-label="Remove shift" onClick={onRemove}>
          <span aria-hidden="true">×</span>
        </Button>
      ) : null}
    </div>
  );
}
