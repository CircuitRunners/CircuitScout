import { useConvex, useQuery } from "convex/react";
import { Download } from "lucide-react";
import { useState } from "react";
import { Link } from "react-router";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

const KINDS = [
  { kind: "teams" as const, label: "Teams" },
  { kind: "matchReports" as const, label: "Match reports" },
  { kind: "pitReports" as const, label: "Pit reports" },
];

export default function AdminDataPage() {
  const data = useQuery(api.stats.coverage);
  const convex = useConvex();
  const [busy, setBusy] = useState<string | null>(null);

  const download = async (kind: (typeof KINDS)[number]["kind"], label: string) => {
    setBusy(kind);
    try {
      const csv = await convex.query(api.exports.csv, { kind });
      const url = URL.createObjectURL(new Blob([csv], { type: "text/csv" }));
      const link = document.createElement("a");
      link.href = url;
      link.download = `circuitscout-${kind}.csv`;
      link.click();
      URL.revokeObjectURL(url);
      toast.success(`${label} exported`);
    } catch (error) {
      toast.error("Export failed", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(null);
    }
  };

  const totals = data?.totals ?? null;

  return (
    <PageShell
      title="Coverage and quality"
      description="Whether the numbers everywhere else are worth trusting."
    >
      {totals ? (
        <div className="grid gap-4 sm:grid-cols-3">
          <Card>
            <CardHeader>
              <CardDescription>Reports</CardDescription>
              <CardTitle className="text-3xl tabular-nums">
                {totals.reports}
                <span className="text-muted-foreground text-lg">
                  /{totals.possible}
                </span>
              </CardTitle>
            </CardHeader>
          </Card>
          <Card>
            <CardHeader>
              <CardDescription>Teams never pit scouted</CardDescription>
              <CardTitle className="text-3xl tabular-nums">
                {data?.teamsNoPit.length ?? 0}
              </CardTitle>
            </CardHeader>
          </Card>
          <Card>
            <CardHeader>
              <CardDescription>Teams with no match data</CardDescription>
              <CardTitle className="text-3xl tabular-nums">
                {data?.teamsNoMatch.length ?? 0}
              </CardTitle>
            </CardHeader>
          </Card>
        </div>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>Matches with gaps</CardTitle>
          <CardDescription>
            Robots nobody covered. Six per match is full coverage.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {data === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : data.matches.length === 0 ? (
            <p className="text-muted-foreground text-sm">
              Every scheduled robot has at least one report.
            </p>
          ) : (
            data.matches.map((m) => (
              <div key={m.matchNumber} className="flex flex-wrap items-center gap-2 rounded-lg border p-3 text-sm">
                <Button size="sm" variant="ghost"
                  render={<Link to={`/matches/${m.matchNumber}`} />}>
                  Qual {m.matchNumber}
                </Button>
                <span className="text-muted-foreground text-xs">
                  {m.reportCount} report{m.reportCount === 1 ? "" : "s"} · missing
                </span>
                {m.missing.map((n) => (
                  <Badge key={n} variant="outline" className="tabular-nums">{n}</Badge>
                ))}
              </div>
            ))
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Teams with no data</CardTitle>
          <CardDescription>
            These cannot be ranked on anything. Unscouted is not the same as bad,
            and a pick list that treats them alike will quietly bury a good robot.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <div>
            <p className="text-muted-foreground mb-1 text-xs">No pit report</p>
            <div className="flex flex-wrap gap-1">
              {(data?.teamsNoPit ?? []).length === 0 ? (
                <span className="text-muted-foreground text-sm">None.</span>
              ) : (
                data?.teamsNoPit.map((n) => (
                  <Button key={n} size="sm" variant="outline" render={<Link to={`/pit/${n}`} />}>
                    {n}
                  </Button>
                ))
              )}
            </div>
          </div>
          <div>
            <p className="text-muted-foreground mb-1 text-xs">No match reports</p>
            <div className="flex flex-wrap gap-1">
              {(data?.teamsNoMatch ?? []).length === 0 ? (
                <span className="text-muted-foreground text-sm">None.</span>
              ) : (
                data?.teamsNoMatch.map((n) => (
                  <Button key={n} size="sm" variant="outline"
                    render={<Link to={`/teams?team=${n}`} />}>
                    {n}
                  </Button>
                ))
              )}
            </div>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>By scout</CardTitle>
          <CardDescription>
            Volume, plus how many of each scout's reports lack a shift split or
            were finished before the buzzer. High counts usually mean the Match
            Start button is being missed, not that someone is careless.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {(data?.byScout ?? []).map((s) => (
            <div key={s.name} className="flex flex-wrap items-center gap-2 rounded-lg border p-3 text-sm">
              <span className="min-w-0 flex-1 truncate font-medium">{s.name}</span>
              <span className="text-muted-foreground text-xs tabular-nums">
                {s.count} report{s.count === 1 ? "" : "s"}
              </span>
              {s.noSplit > 0 ? (
                <Badge variant="outline">{s.noSplit} no split</Badge>
              ) : null}
              {s.early > 0 ? (
                <Badge variant="destructive">{s.early} early</Badge>
              ) : null}
            </div>
          ))}
          {(data?.byScout ?? []).length === 0 ? (
            <p className="text-muted-foreground text-sm">No reports yet.</p>
          ) : null}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Export</CardTitle>
          <CardDescription>
            CSV of the active event. Also your fallback when the app is
            unreachable — which is exactly when venue wifi fails.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap gap-2">
          {KINDS.map((k) => (
            <Button key={k.kind} variant="outline" disabled={busy !== null}
              onClick={() => void download(k.kind, k.label)}>
              <Download className="size-4" />
              {k.label}
            </Button>
          ))}
        </CardContent>
      </Card>
    </PageShell>
  );
}
