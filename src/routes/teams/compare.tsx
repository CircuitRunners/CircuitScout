import { useQuery } from "convex/react";
import { X } from "lucide-react";
import { useSearchParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { CompareTable } from "@/components/compare-table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useState } from "react";

const MAX = 4;

export default function ComparePage() {
  const [searchParams, setSearchParams] = useSearchParams();
  const [search, setSearch] = useState("");

  const selected = (searchParams.get("teams") ?? "")
    .split(",")
    .map((n) => Number.parseInt(n, 10))
    .filter((n) => !Number.isNaN(n));

  const teams = useQuery(api.teams.listWithStatus);
  const rows = useQuery(
    api.stats.compare,
    selected.length > 0 ? { teamNumbers: selected } : "skip",
  );

  const setSelected = (next: number[]) => {
    const params = new URLSearchParams(searchParams);
    if (next.length === 0) params.delete("teams");
    else params.set("teams", next.join(","));
    setSearchParams(params, { replace: true });
  };

  const add = (n: number) => {
    if (selected.includes(n) || selected.length >= MAX) return;
    setSelected([...selected, n]);
    setSearch("");
  };

  const candidates = (teams ?? [])
    .filter((t) => !selected.includes(t.number))
    .filter((t) => {
      const needle = search.trim().toLowerCase();
      if (needle === "") return false;
      return (
        String(t.number).includes(needle) ||
        t.nickname.toLowerCase().includes(needle)
      );
    })
    .slice(0, 8);

  return (
    <PageShell
      title="Compare teams"
      description="Up to four teams on the same metric rows. The URL holds the selection, so this page is shareable."
    >
      <div className="flex flex-wrap items-center gap-2">
        {selected.map((n) => (
          <Badge key={n} variant="secondary" className="h-9 px-3 text-sm">
            {n}
            <button
              className="ml-1"
              aria-label={`Remove team ${n}`}
              onClick={() => setSelected(selected.filter((x) => x !== n))}
            >
              <X className="size-3" />
            </button>
          </Badge>
        ))}
        {selected.length < MAX ? (
          <Input
            className="max-w-56"
            placeholder="Add a team"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        ) : (
          <span className="text-muted-foreground text-xs">
            Four is the maximum — beyond that the rows stop being readable.
          </span>
        )}
      </div>

      {candidates.length > 0 ? (
        <div className="flex flex-wrap gap-2">
          {candidates.map((t) => (
            <Button key={t._id} size="sm" variant="outline" onClick={() => add(t.number)}>
              {t.number} · {t.nickname}
            </Button>
          ))}
        </div>
      ) : null}

      {selected.length === 0 ? (
        <p className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
          Add two or more teams to compare them.
        </p>
      ) : rows === undefined ? (
        <p className="text-muted-foreground text-sm">Loading…</p>
      ) : (
        <>
          <CompareTable columns={rows} />
          <p className="text-muted-foreground text-xs">
            Bold marks the best value in each row. Compare report counts before
            trusting a gap — an average over two matches and one over eleven are
            not the same claim.
          </p>
        </>
      )}
    </PageShell>
  );
}
