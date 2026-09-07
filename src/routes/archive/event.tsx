import { useQuery } from "convex/react";
import { ArrowLeft, TriangleAlert } from "lucide-react";
import { useMemo, useState } from "react";
import { Link, useParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

type SortKey = "number" | "totalFuel" | "climbPoints" | "driver" | "defense";

const COLUMNS: ReadonlyArray<{ key: SortKey; label: string }> = [
  { key: "number", label: "Team" },
  { key: "totalFuel", label: "Fuel" },
  { key: "climbPoints", label: "Climb" },
  { key: "driver", label: "Driver" },
  { key: "defense", label: "Defense" },
];

export default function ArchiveEventPage() {
  const params = useParams();
  const eventKey = params.eventKey ?? "";
  const data = useQuery(api.archive.teamTable, eventKey ? { eventKey } : "skip");

  const [search, setSearch] = useState("");
  const [sort, setSort] = useState<SortKey>("number");

  const rows = useMemo(() => {
    const all = data?.rows ?? [];
    const needle = search.trim().toLowerCase();
    const filtered = needle === ""
      ? all
      : all.filter((r) =>
          String(r.teamNumber).includes(needle) ||
          r.nickname.toLowerCase().includes(needle));

    return [...filtered].sort((a, b) => {
      switch (sort) {
        case "number": return a.teamNumber - b.teamNumber;
        case "totalFuel": return b.stats.avgTotalFuel - a.stats.avgTotalFuel;
        case "climbPoints": return b.stats.avgClimbPoints - a.stats.avgClimbPoints;
        case "driver": return b.stats.avgDriver - a.stats.avgDriver;
        case "defense": return b.stats.avgDefense - a.stats.avgDefense;
      }
    });
  }, [data, search, sort]);

  if (data === undefined) {
    return <PageShell title="Past event" description="Loading…" />;
  }
  if (data === null) {
    return (
      <PageShell title="Past event" description="No event with that key.">
        <Button variant="outline" render={<Link to="/archive" />}>
          <ArrowLeft className="size-4" /> All events
        </Button>
      </PageShell>
    );
  }

  return (
    <PageShell
      title={data.name}
      description={`${data.eventKey} · ${data.matchCount} qualification matches`}
      actions={
        <Button variant="outline" render={<Link to="/archive" />}>
          <ArrowLeft className="size-4" /> All events
        </Button>
      }
    >
      <div className="border-destructive text-destructive flex items-center gap-2 rounded-lg border p-3 text-sm">
        <TriangleAlert className="size-4 shrink-0" />
        Archived data. These numbers are not from your current competition.
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <Input className="max-w-56" placeholder="Team number or name"
          value={search} onChange={(e) => setSearch(e.target.value)} />
        {COLUMNS.map((c) => (
          <Button key={c.key} size="sm"
            variant={sort === c.key ? "default" : "outline"}
            onClick={() => setSort(c.key)}>
            {c.label}
          </Button>
        ))}
      </div>

      <div className="overflow-x-auto rounded-lg border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b">
              <th className="p-3 text-left font-medium">Team</th>
              <th className="p-3 text-right font-medium">Reports</th>
              <th className="p-3 text-right font-medium">Fuel</th>
              <th className="p-3 text-right font-medium">Climb</th>
              <th className="p-3 text-right font-medium">Driver</th>
              <th className="p-3 text-right font-medium">Defense</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.teamNumber} className="border-b last:border-0">
                <td className="p-3">
                  <span className="font-semibold tabular-nums">{row.teamNumber}</span>
                  <span className="text-muted-foreground ml-2 text-xs">
                    {row.nickname}
                  </span>
                </td>
                <td className="text-muted-foreground p-3 text-right text-xs tabular-nums">
                  {row.stats.reportCount}
                </td>
                <td className="p-3 text-right tabular-nums">
                  {row.stats.reportCount === 0 ? "—" : row.stats.avgTotalFuel.toFixed(1)}
                </td>
                <td className="p-3 text-right tabular-nums">
                  {row.stats.reportCount === 0 ? "—" : row.stats.avgClimbPoints.toFixed(1)}
                </td>
                <td className="p-3 text-right tabular-nums">
                  {row.stats.reportCount === 0 ? "—" : row.stats.avgDriver.toFixed(1)}
                </td>
                <td className="p-3 text-right tabular-nums">
                  {row.stats.reportCount === 0 ? "—" : row.stats.avgDefense.toFixed(1)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </PageShell>
  );
}
