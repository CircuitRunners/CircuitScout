import { LogOut, Map, Rows3, Trash2, Undo2 } from "lucide-react";
import { useState } from "react";

import { FieldMap } from "./field-map";
import { LANE_LABEL, START_ORDER, startLabel } from "./geometry";
import { SegmentedChoice } from "@/components/scouting/segmented-choice";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { MAX_AUTO_CYCLES } from "@/lib/scoring";
import type { AutoStep, Lane, StartPosition } from "@/lib/types";
import { useUIStore } from "@/stores/ui-store";

const LANE_OPTIONS: ReadonlyArray<{ value: Lane; label: string }> = [
  { value: "trench-left", label: "Trench L" },
  { value: "trench-right", label: "Trench R" },
  { value: "bump-left", label: "Bump L" },
  { value: "bump-right", label: "Bump R" },
];

const START_OPTIONS = START_ORDER.map((value) => ({
  value,
  label: value === "hub" ? "Hub" : `${startLabel(value)} ${value.endsWith("left") ? "L" : "R"}`,
}));

const DRIVER_HINT = "left / right as that alliance's drivers see it";

const side = (lane: Lane) => (lane.endsWith("left") ? "L" : "R");

function describe(step: AutoStep): string {
  if (step.kind === "depot") return "Depot pickup";
  if (step.kind === "outpost") return "Outpost pickup";
  if (step.kind === "climb") return "Climbed L1";
  return step.inbound === null
    ? `Out ${LANE_LABEL[step.outbound]} ${side(step.outbound)} · did not return`
    : `Out ${LANE_LABEL[step.outbound]} ${side(step.outbound)} · back ${LANE_LABEL[step.inbound]} ${side(step.inbound)}`;
}

export function AutoPathEditor({
  alliance,
  start,
  onStartChange,
  steps,
  onStepsChange,
}: {
  alliance: "red" | "blue";
  start: StartPosition | null;
  onStartChange: (next: StartPosition) => void;
  steps: AutoStep[];
  onStepsChange: (next: AutoStep[]) => void;
}) {
  const inputMode = useUIStore((s) => s.autoInputMode);
  const setInputMode = useUIStore((s) => s.setAutoInputMode);
  const [pending, setPending] = useState<Lane | null>(null);

  const neutralCount = steps.filter((s) => s.kind === "neutral").length;
  const last = steps.at(-1);
  const endedOutside = last?.kind === "neutral" && last.inbound === null;
  const climbed = steps.some((s) => s.kind === "climb");

  // The climb is a step, but it is not a cycle — it never counts toward the cap.
  const cyclesFull = neutralCount >= MAX_AUTO_CYCLES;
  // Nothing follows an exit-only step or a climb: in one case the robot never
  // came back, in the other it is on the tower.
  const closed = endedOutside || climbed;
  // Mid-cycle the robot is in the neutral zone, so it cannot be at the depot,
  // the outpost or the tower.
  const inZone = !closed && pending === null;

  const mode = start === null
    ? ({ kind: "start" } as const)
    : pending !== null
      ? ({ kind: "inbound", outbound: pending } as const)
      : cyclesFull || closed
        ? ({ kind: "full" } as const)
        : ({ kind: "outbound" } as const);

  const pickLane = (lane: Lane) => {
    if (pending === null) {
      if (cyclesFull || closed) return;
      setPending(lane);
      return;
    }
    onStepsChange([...steps, { kind: "neutral", outbound: pending, inbound: lane }]);
    setPending(null);
  };

  const addPickup = (kind: "depot" | "outpost") => {
    if (!inZone) return;
    onStepsChange([...steps, { kind }]);
  };

  const toggleClimb = () => {
    if (climbed) {
      onStepsChange(steps.filter((s) => s.kind !== "climb"));
      return;
    }
    if (!inZone) return;
    onStepsChange([...steps, { kind: "climb" }]);
  };

  const prompt =
    start === null
      ? "Tap where the robot lined up."
      : pending !== null
        ? `Out through ${LANE_LABEL[pending]}. Tap the lane it came back through, or mark it as not returning.`
        : climbed
          ? "Climbed L1 — nothing follows a climb. Tap the tower again to undo."
          : endedOutside
            ? "Auto ended with the robot still out. Remove the last step to change it."
            : cyclesFull
              ? `${MAX_AUTO_CYCLES} neutral-zone cycles — the most auto allows. Pickups and the climb can still be added.`
              : `Tap a lane, the depot, the outpost or the tower, in the order it happened. ${neutralCount} of ${MAX_AUTO_CYCLES} cycles.`;

  return (
    <>
      <Card>
        <CardHeader className="flex-row items-center justify-between space-y-0">
          <CardTitle>Auto path</CardTitle>
          <Button variant="ghost" size="sm"
            onClick={() => setInputMode(inputMode === "map" ? "buttons" : "map")}>
            {inputMode === "map" ? <Rows3 className="size-4" /> : <Map className="size-4" />}
            {inputMode === "map" ? "Buttons" : "Map"}
          </Button>
        </CardHeader>
        <CardContent className="space-y-4">
          {inputMode === "map" ? (
            <>
              <FieldMap
                alliance={alliance}
                start={start}
                cycles={steps.flatMap((s) => (s.kind === "neutral" ? [s] : []))}
                mode={mode}
                onPickStart={onStartChange}
                onPickLane={pickLane}
                onPickPickup={addPickup}
                onToggleClimb={toggleClimb}
                climbed={climbed}
                canPickPickup={inZone}
              />
              <div className="flex flex-wrap items-center gap-2">
                <p className="text-muted-foreground min-w-0 flex-1 text-sm">{prompt}</p>
                {pending !== null ? (
                  <>
                    <Button variant="outline" size="sm"
                      onClick={() => {
                        onStepsChange([...steps,
                          { kind: "neutral", outbound: pending, inbound: null }]);
                        setPending(null);
                      }}>
                      <LogOut className="size-3" /> Did not return
                    </Button>
                    <Button variant="ghost" size="sm" onClick={() => setPending(null)}>
                      <Undo2 className="size-3" /> Cancel
                    </Button>
                  </>
                ) : null}
              </div>
            </>
          ) : (
            <>
              <SegmentedChoice label="Lined up in front of" hint={DRIVER_HINT}
                options={START_OPTIONS} value={start} onChange={onStartChange} />

              {steps.map((step, index) =>
                step.kind === "neutral" ? (
                  <div key={index} className="space-y-3 rounded-lg border p-3">
                    <div className="flex items-center justify-between">
                      <span className="text-sm font-medium">
                        {index + 1}. Neutral zone
                      </span>
                      <Button variant="ghost" size="icon"
                        aria-label={`Remove step ${index + 1}`}
                        onClick={() => onStepsChange(steps.filter((_, i) => i !== index))}>
                        <Trash2 className="size-4" />
                      </Button>
                    </div>
                    <SegmentedChoice label="Out through" hint={DRIVER_HINT}
                      options={LANE_OPTIONS} value={step.outbound}
                      onChange={(lane) => onStepsChange(steps.map((s, i) =>
                        i === index && s.kind === "neutral" ? { ...s, outbound: lane } : s))} />
                    <SegmentedChoice
                      label="Back through"
                      hint={DRIVER_HINT}
                      options={
                        index === steps.length - 1
                          ? [...LANE_OPTIONS, { value: "none" as const, label: "Did not return" }]
                          : LANE_OPTIONS
                      }
                      value={step.inbound ?? "none"}
                      onChange={(value) => onStepsChange(steps.map((s, i) =>
                        i === index && s.kind === "neutral"
                          ? { ...s, inbound: value === "none" ? null : (value as Lane) }
                          : s))} />
                  </div>
                ) : (
                  <div key={index}
                    className="flex items-center gap-2 rounded-lg border p-3 text-sm">
                    <span className="font-medium">
                      {index + 1}. {describe(step)}
                    </span>
                    <div className="flex-1" />
                    <Button variant="ghost" size="icon"
                      aria-label={`Remove step ${index + 1}`}
                      onClick={() => onStepsChange(steps.filter((_, i) => i !== index))}>
                      <Trash2 className="size-4" />
                    </Button>
                  </div>
                ),
              )}

              <div className="grid grid-cols-4 gap-2">
                <Button variant="outline" className="h-12" disabled={cyclesFull || closed}
                  onClick={() => onStepsChange([...steps,
                    { kind: "neutral", outbound: "bump-left", inbound: "bump-left" }])}>
                  Cycle
                </Button>
                <Button variant="outline" className="h-12" disabled={!inZone}
                  onClick={() => addPickup("depot")}>
                  Depot
                </Button>
                <Button variant="outline" className="h-12" disabled={!inZone}
                  onClick={() => addPickup("outpost")}>
                  Outpost
                </Button>
                <Button variant={climbed ? "default" : "outline"} className="h-12"
                  disabled={!climbed && !inZone}
                  onClick={toggleClimb}>
                  L1 climb
                </Button>
              </div>
            </>
          )}

          {/* The ordered list is the record; both modes write into it. */}
          {steps.length > 0 && inputMode === "map" ? (
            <div className="space-y-1">
              {steps.map((step, index) => (
                <div key={index}
                  className="flex items-center gap-2 rounded-md border px-3 py-2 text-sm">
                  <span className="text-muted-foreground text-xs tabular-nums">
                    {index + 1}
                  </span>
                  <span className="min-w-0 flex-1 truncate">{describe(step)}</span>
                  <Button variant="ghost" size="icon"
                    aria-label={`Remove step ${index + 1}`}
                    onClick={() => onStepsChange(steps.filter((_, i) => i !== index))}>
                    <Trash2 className="size-4" />
                  </Button>
                </div>
              ))}
            </div>
          ) : null}
        </CardContent>
      </Card>
    </>
  );
}
