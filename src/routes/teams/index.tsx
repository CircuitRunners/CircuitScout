import { useQuery } from "convex/react";
import { useMemo, useState } from "react";
import { Link, useSearchParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { TeamDetail } from "./team-detail";
import { TeamCard } from "@/components/scouting/team-card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import type { Tier } from "@/lib/types";

type Filter = "all" | "no-pit" | "no-matches";

const FILTERS: ReadonlyArray<{ value: Filter; label: string }> = [
  { value: "all", label: "All" },
  { value: "no-pit", label: "Missing pit" },
  { value: "no-matches", label: "No match data" },
];

export default function TeamsPage() {
  const teams = useQuery(api.teams.listWithStatus);
  // The open team lives in the URL, not in a store: it makes a team shareable
  // and the back button correct.
  const [searchParams, setSearchParams] = useSearchParams();
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<Filter>("all");

  const openParam = searchParams.get("team");
  const openTeam = openParam === null ? null : Number.parseInt(openParam, 10);

  const shown = useMemo(() => {
    if (!teams) return [];
    const needle = search.trim().toLowerCase();
    return teams.filter((team) => {
      if (filter === "no-pit" && team.pitScouted) return false;
      if (filter === "no-matches" && team.reportCount > 0) return false;
      if (needle === "") return true;
      return (
        String(team.number).includes(needle) ||
        team.nickname.toLowerCase().includes(needle)
      );
    });
  }, [teams, search, filter]);

  const open = (teamNumber: number) => {
    const next = new URLSearchParams(searchParams);
    next.set("team", String(teamNumber));
    setSearchParams(next);
  };

  const close = () => {
    const next = new URLSearchParams(searchParams);
    next.delete("team");
    setSearchParams(next, { replace: true });
  };

  return (
    <PageShell
      title="Teams"
      description={
        teams === undefined
          ? "Loading…"
          : `${teams.length} teams at this event. Tap one for its full record.`
      }
      actions={
        <div className="flex flex-col gap-2">
          <Button variant="outline" render={<Link to="/teams/compare" />}>
            Compare teams
          </Button>
          <Button variant="outline" render={<Link to="/teams/plot" />}>
            Data plot
          </Button>
        </div>
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
          className="ml-auto max-w-56"
          placeholder="Team number or name"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
      </div>

      {teams === undefined ? (
        <p className="text-muted-foreground text-sm">Loading…</p>
      ) : shown.length === 0 ? (
        <p className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
          {teams.length === 0
            ? "No teams yet. An admin needs to import an event."
            : "Nothing matches."}
        </p>
      ) : (
        <div className="space-y-2">
          {shown.map((team) => (
            <TeamCard
              key={team._id}
              number={team.number}
              nickname={team.nickname}
              pitScouted={team.pitScouted}
              reportCount={team.reportCount}
              tier={team.tier as Tier}
              onClick={() => open(team.number)}
            />
          ))}
        </div>
      )}

      <TeamDetail
        teamNumber={openTeam !== null && !Number.isNaN(openTeam) ? openTeam : null}
        onClose={close}
      />
    </PageShell>
  );
}
