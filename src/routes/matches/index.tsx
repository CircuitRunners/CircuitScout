import { useQuery } from "convex/react";
import { ChevronRight } from "lucide-react";
import { useMemo, useState } from "react";
import { Link } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export default function MatchesPage() {
  const matches = useQuery(api.matches.listForEvent);
  const [search, setSearch] = useState("");

  const shown = useMemo(() => {
    if (!matches) return [];
    const needle = search.trim();
    if (needle === "") return matches;
    const n = Number.parseInt(needle, 10);
    return matches.filter(
      (m) =>
        String(m.matchNumber) === needle ||
        (!Number.isNaN(n) &&
          (m.redTeamNumbers.includes(n) || m.blueTeamNumbers.includes(n))),
    );
  }, [matches, search]);

  return (
    <PageShell
      title="Matches"
      description="Open a match to see all six robots side by side before you play it."
    >
      <Input
        className="max-w-72"
        placeholder="Match number or team number"
        inputMode="numeric"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
      />

      {matches === undefined ? (
        <p className="text-muted-foreground text-sm">Loading…</p>
      ) : shown.length === 0 ? (
        <p className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
          {matches.length === 0 ? "No schedule imported yet." : "Nothing matches."}
        </p>
      ) : (
        <div className="space-y-1">
          {shown.map((match) => (
            <Button
              key={match._id}
              variant="outline"
              className="h-auto w-full justify-start py-3"
              render={<Link to={`/matches/${match.matchNumber}`} />}
            >
              <span className="font-medium">Qual {match.matchNumber}</span>
              <span className="text-muted-foreground ml-2 min-w-0 flex-1 truncate text-left text-xs">
                <span className="text-red-600 dark:text-red-400">
                  {match.redTeamNumbers.join(", ")}
                </span>
                {" vs "}
                <span className="text-blue-600 dark:text-blue-400">
                  {match.blueTeamNumbers.join(", ")}
                </span>
              </span>
              <ChevronRight className="size-4 shrink-0" />
            </Button>
          ))}
        </div>
      )}
    </PageShell>
  );
}
