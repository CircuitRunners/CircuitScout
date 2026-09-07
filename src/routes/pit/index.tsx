import { useQuery } from "convex/react";
import { useMemo, useState } from "react";
import { useNavigate } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";

type Filter = "all" | "todo" | "done";

const FILTERS: ReadonlyArray<{ value: Filter; label: string }> = [
  { value: "todo", label: "Not scouted" },
  { value: "done", label: "Scouted" },
  { value: "all", label: "All" },
];

export default function PitLandingPage() {
  const teams = useQuery(api.teams.listWithStatus);
  const navigate = useNavigate();
  const [filter, setFilter] = useState<Filter>("todo");
  const [search, setSearch] = useState("");

  const shown = useMemo(() => {
    if (!teams) return [];
    const needle = search.trim().toLowerCase();
    return teams.filter((team) => {
      if (filter === "todo" && team.pitScouted) return false;
      if (filter === "done" && !team.pitScouted) return false;
      if (needle === "") return true;
      return (
        String(team.number).includes(needle) ||
        team.nickname.toLowerCase().includes(needle)
      );
    });
  }, [teams, filter, search]);

  const done = teams?.filter((t) => t.pitScouted).length ?? 0;
  const total = teams?.length ?? 0;

  return (
    <PageShell
      title="Pit Scouting"
      description={
        total === 0
          ? "No teams yet. An admin needs to import an event."
          : `${done} of ${total} teams scouted. Tap a team to scout it.`
      }
    >
      <div className="flex flex-wrap items-center gap-2">
        {FILTERS.map((f) => (
          <Button
            key={f.value}
            size="sm"
            variant={filter === f.value ? "default" : "outline"}
            onClick={() => setFilter(f.value)}
          >
            {f.label}
          </Button>
        ))}
        <Input
          className="ml-auto max-w-48"
          placeholder="Find a team"
          inputMode="numeric"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
      </div>

      {teams === undefined ? (
        <p className="text-muted-foreground text-sm">Loading…</p>
      ) : shown.length === 0 ? (
        <p className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
          {filter === "todo" && total > 0
            ? "Every team has been scouted."
            : "Nothing matches."}
        </p>
      ) : (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
          {shown.map((team) => (
            <button
              key={team._id}
              onClick={() => void navigate(`/pit/${team.number}`)}
              className={[
                "flex min-h-24 flex-col justify-between rounded-lg border p-3 text-left transition-colors",
                team.pitScouted
                  ? "bg-primary/5 border-primary/40"
                  : "hover:bg-accent/50",
              ].join(" ")}
            >
              <span className="text-2xl font-semibold tabular-nums">
                {team.number}
              </span>
              <span className="text-muted-foreground truncate text-xs">
                {team.nickname}
              </span>
              <Badge
                variant={team.pitScouted ? "default" : "outline"}
                className="mt-1 w-fit"
              >
                {team.pitScouted ? "Scouted" : "Not scouted"}
              </Badge>
            </button>
          ))}
        </div>
      )}
    </PageShell>
  );
}
