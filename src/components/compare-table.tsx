type Summary = {
  reportCount: number;
  avgAutoFuel: number;
  avgTeleopFuel: number;
  avgUncountedFuel: number;
  avgEndgameFuel: number;
  avgTotalFuel: number;
  avgClimbPoints: number;
  avgDriver: number;
  avgDefense: number;
  avgAccuracy: number;
  avgBps: number;
  avgAdjustedBps: number;
  bpsReportCount: number;
  minTotalFuel: number;
  maxTotalFuel: number;
  brokeCount: number;
  inconsistentCount: number;
};

export type CompareColumn = {
  teamNumber: number;
  nickname: string;
  stats: Summary;
};

type Metric = {
  label: string;
  get: (s: Summary) => number;
  higherIsBetter: boolean;
  decimals?: number;
  suffix?: string;
};

const METRICS: ReadonlyArray<Metric> = [
  { label: "Reports", get: (s) => s.reportCount, higherIsBetter: true, decimals: 0 },
  { label: "Total fuel", get: (s) => s.avgTotalFuel, higherIsBetter: true },
  { label: "Auto fuel", get: (s) => s.avgAutoFuel, higherIsBetter: true },
  { label: "Teleop fuel", get: (s) => s.avgTeleopFuel, higherIsBetter: true },
  { label: "Endgame fuel", get: (s) => s.avgEndgameFuel, higherIsBetter: true },
  { label: "Dead-hub fuel", get: (s) => s.avgUncountedFuel, higherIsBetter: false },
  { label: "Climb points", get: (s) => s.avgClimbPoints, higherIsBetter: true },
  { label: "Driver", get: (s) => s.avgDriver, higherIsBetter: true },
  { label: "Defense", get: (s) => s.avgDefense, higherIsBetter: true },
  { label: "Accuracy", get: (s) => s.avgAccuracy, higherIsBetter: true, suffix: "%" },
  { label: "BPS", get: (s) => s.avgBps, higherIsBetter: true },
  { label: "Adjusted BPS", get: (s) => s.avgAdjustedBps, higherIsBetter: true },
  { label: "Broke", get: (s) => s.brokeCount, higherIsBetter: false, decimals: 0 },
  { label: "Inconsistent", get: (s) => s.inconsistentCount, higherIsBetter: false, decimals: 0 },
];

export function CompareTable({ columns }: { columns: CompareColumn[] }) {
  if (columns.length === 0) return null;

  return (
    <div className="overflow-x-auto rounded-lg border">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b">
            <th className="p-3 text-left font-medium">Metric</th>
            {columns.map((c) => (
              <th key={c.teamNumber} className="p-3 text-right font-medium">
                <div className="tabular-nums">{c.teamNumber}</div>
                <div className="text-muted-foreground max-w-32 truncate text-xs font-normal">
                  {c.nickname}
                </div>
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {METRICS.map((metric) => {
            const values = columns.map((c) => metric.get(c.stats));
            // Only mark a winner when the column actually differ; highlighting
            // a tie implies a distinction that is not there.
            const best = metric.higherIsBetter
              ? Math.max(...values)
              : Math.min(...values);
            const allSame = values.every((v) => v === values[0]);

            return (
              <tr key={metric.label} className="border-b last:border-0">
                <td className="text-muted-foreground p-3">{metric.label}</td>
                {columns.map((c, i) => {
                  const value = values[i] ?? 0;
                  const isBest = !allSame && value === best;
                  return (
                    <td
                      key={c.teamNumber}
                      className={[
                        "p-3 text-right tabular-nums",
                        isBest ? "font-semibold" : "",
                      ].join(" ")}
                    >
                      {value.toFixed(metric.decimals ?? 1)}
                      {metric.suffix ?? ""}
                    </td>
                  );
                })}
              </tr>
            );
          })}
          <tr className="border-t">
            <td className="text-muted-foreground p-3">Range (total fuel)</td>
            {columns.map((c) => (
              <td key={c.teamNumber} className="text-muted-foreground p-3 text-right text-xs tabular-nums">
                {c.stats.reportCount === 0
                  ? "—"
                  : `${c.stats.minTotalFuel}–${c.stats.maxTotalFuel}`}
              </td>
            ))}
          </tr>
        </tbody>
      </table>
    </div>
  );
}
