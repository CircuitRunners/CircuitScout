import { useQuery } from "convex/react";
import { useMemo, useState } from "react";
import { useSearchParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { NotesTeamDetail } from "./team-detail";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";

export default function NotesTeamsPage() {
  const teams = useQuery(api.notes.teams);
  const [search, setSearch] = useState("");
  // ?team=1002 opens that team, the same link the 2026 page answers to.
  const [params, setParams] = useSearchParams();
  const openTeam = Number.parseInt(params.get("team") ?? "", 10);

  const shown = useMemo(() => {
    const needle = search.trim().toLowerCase();
    return (teams ?? []).filter((t) =>
      needle === "" || String(t.number).includes(needle) || t.nickname.toLowerCase().includes(needle));
  }, [teams, search]);

  return (
    <PageShell title="Teams" description="Tap a team for its pit notes and every match note written about it.">
      <Input className="max-w-56" placeholder="Team number or name"
        value={search} onChange={(e) => setSearch(e.target.value)} />

      {teams === undefined ? (
        <p className="text-muted-foreground text-sm">Loading…</p>
      ) : shown.length === 0 ? (
        <p className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
          {(teams ?? []).length === 0 ? "No teams yet. An admin needs to import an event." : "Nothing matches."}
        </p>
      ) : (
        <div className="space-y-2">
          {shown.map((team) => (
            <button key={team.teamId}
              onClick={() => setParams({ team: String(team.number) })}
              className="hover:bg-accent/50 flex min-h-16 w-full items-center gap-3 rounded-lg border p-3 text-left transition-colors">
              <span className="w-14 shrink-0 text-lg font-semibold tabular-nums">{team.number}</span>
              <span className="min-w-0 flex-1 truncate text-sm">{team.nickname}</span>
              <Badge variant={team.pitNoted ? "default" : "outline"}>
                {team.pitNoted ? "Pit notes" : "No pit notes"}
              </Badge>
            </button>
          ))}
        </div>
      )}

      <NotesTeamDetail
        teamNumber={Number.isNaN(openTeam) ? null : openTeam}
        onClose={() => setParams({})}
      />
    </PageShell>
  );
}
