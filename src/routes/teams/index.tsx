import { useQuery } from "convex/react";
import { ChevronDown } from "lucide-react";
import { useMemo, useState } from "react";
import { Link, useSearchParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { TeamDetail } from "./team-detail";
import { TeamCard } from "@/components/scouting/team-card";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuRadioGroup,
  DropdownMenuRadioItem, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import type { Tier } from "@/lib/types";

type Filter = "all" | "needs-help" | "no-pit" | "no-matches";

const FILTERS: ReadonlyArray<{ value: Filter; label: string }> = [
  { value: "all", label: "All" },
  { value: "needs-help", label: "Needing assistance" },
  { value: "no-pit", label: "Missing pit" },
  { value: "no-matches", label: "No match data" },
];

type TeamSort = "number" | "totalFuel" | "climbPoints" | "passing" | "defense" | "driver";

/** Team number ascending; every stat highest first. */
const TEAM_SORTS: ReadonlyArray<{ value: TeamSort; label: string }> = [
  { value: "number", label: "Team number" },
  { value: "totalFuel", label: "Fuel" },
  { value: "climbPoints", label: "Climb" },
  { value: "passing", label: "Passing" },
  { value: "defense", label: "Defense" },
  { value: "driver", label: "Driver" },
];

export default function TeamsPage() {
  const teams = useQuery(api.teams.listWithStatus);
  const attention = useQuery(api.attention.forEvent);
  // The open team lives in the URL, not in a store: it makes a team shareable
  // and the back button correct.
  const [searchParams, setSearchParams] = useSearchParams();
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const [sort, setSort] = useState<TeamSort>("number");
  // Only subscribed while a stat sort is chosen; team-number order needs none.
  const stats = useQuery(api.stats.forEvent, sort === "number" ? "skip" : {});

  const openParam = searchParams.get("team");
  const openTeam = openParam === null ? null : Number.parseInt(openParam, 10);

  // Count per team so a row can be marked without re-scanning the list.
  const attentionByTeam = useMemo(() => {
    const counts = new Map<number, number>();
    for (const row of attention ?? []) {
      counts.set(row.teamNumber, (counts.get(row.teamNumber) ?? 0) + 1);
    }
    return counts;
  }, [attention]);

  // Teams, not reports: three warnings on one robot is one team to look at.
  const attentionTeamCount = attentionByTeam.size;

  const shown = useMemo(() => {
    if (!teams) return [];
    const needle = search.trim().toLowerCase();
    return teams.filter((team) => {
      if (filter === "needs-help" && (attentionByTeam.get(team.number) ?? 0) === 0) {
        return false;
      }
      if (filter === "no-pit" && team.pitScouted) return false;
      if (filter === "no-matches" && team.reportCount > 0) return false;
      if (needle === "") return true;
      return (
        String(team.number).includes(needle) ||
        team.nickname.toLowerCase().includes(needle)
      );
    });
  }, [teams, search, filter, attentionByTeam]);

  // Until stats arrive the list stays in team-number order rather than
  // flashing an empty page.
  const sorted = useMemo(() => {
    if (sort === "number" || !stats) return shown;
    const value = (teamId: string): number => {
      const s = stats[teamId];
      if (!s) return -1;
      switch (sort) {
        case "totalFuel": return s.avgTotalFuel;
        case "climbPoints": return s.avgClimbPoints;
        case "passing": return s.avgPassing;
        case "defense": return s.avgDefense;
        case "driver": return s.avgDriver;
      }
    };
    return [...shown].sort((a, b) => value(b._id) - value(a._id) || a.number - b.number);
  }, [shown, sort, stats]);

  const sortLabel = TEAM_SORTS.find((s) => s.value === sort)?.label ?? "";

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
        {FILTERS.map((f) => {
          const urgent = f.value === "needs-help" && attentionTeamCount > 0;
          return (
            <Button
              key={f.value}
              size="sm"
              variant={filter === f.value ? "default" : "outline"}
              className={
                urgent
                  ? "border-destructive text-destructive shadow-[0_0_10px_-1px_var(--destructive)] hover:text-destructive"
                  : ""
              }
              onClick={() => setFilter(f.value)}
            >
              {f.label}
              {urgent ? (
                <span className="bg-destructive ml-1 rounded-full px-1.5 text-[10px] font-semibold text-white tabular-nums">
                  {attentionTeamCount}
                </span>
              ) : null}
            </Button>
          );
        })}
        <DropdownMenu>
          <DropdownMenuTrigger
            render={<Button size="sm" variant={sort === "number" ? "outline" : "default"} />}
          >
            {sort === "number" ? "Sort" : `Sort: ${sortLabel}`}
            <ChevronDown className="size-3" />
          </DropdownMenuTrigger>
          <DropdownMenuContent className="min-w-40">
            <DropdownMenuRadioGroup
              value={sort}
              onValueChange={(value) => setSort(value as TeamSort)}
            >
              {TEAM_SORTS.map((s) => (
                <DropdownMenuRadioItem key={s.value} value={s.value} className="py-2.5">
                  {s.label}
                </DropdownMenuRadioItem>
              ))}
            </DropdownMenuRadioGroup>
          </DropdownMenuContent>
        </DropdownMenu>
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
          {sorted.map((team) => (
            <div key={team._id}
              className={
                (attentionByTeam.get(team.number) ?? 0) > 0
                  ? "border-destructive rounded-lg border-2"
                  : ""
              }>
              <TeamCard
                number={team.number}
                nickname={team.nickname}
                pitScouted={team.pitScouted}
                reportCount={team.reportCount}
                tier={team.tier as Tier}
                attention={attentionByTeam.get(team.number) ?? 0}
                onClick={() => open(team.number)}
              />
            </div>
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
