import { useAction, useMutation, useQuery } from "convex/react";
import { LoaderCircle } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import { STAT_SITE_METRIC, STAT_SITE_NAME, type StatSite } from "@/lib/stat-site";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

const errorText = (error: unknown) =>
  error instanceof Error ? error.message : String(error);

/** A row of joined buttons, one of which is on. */
function Segmented<T extends string>({
  value, options, onChange, disabled, label,
}: {
  value: T;
  options: ReadonlyArray<{ value: T; label: string }>;
  onChange: (next: T) => void;
  disabled: boolean;
  label: string;
}) {
  return (
    <div role="radiogroup" aria-label={label}
      className="inline-flex overflow-hidden rounded-md border">
      {options.map((option, i) => {
        const on = option.value === value;
        return (
          <button key={option.value} type="button" role="radio" aria-checked={on}
            disabled={disabled}
            onClick={() => { if (!on) onChange(option.value); }}
            className={[
              "px-3 py-2 text-sm transition-colors disabled:opacity-60",
              i > 0 ? "border-l" : "",
              on ? "bg-primary text-primary-foreground" : "hover:bg-accent",
            ].join(" ")}>
            {option.label}
          </button>
        );
      })}
    </div>
  );
}

const SITE_OPTIONS = [
  { value: "statbotics", label: "Statbotics" },
  { value: "match13", label: "match13" },
] as const satisfies ReadonlyArray<{ value: StatSite; label: string }>;

const TEAM_OPTIONS = [
  { value: "default", label: "Default" },
  ...SITE_OPTIONS,
] as const;

/**
 * Statbotics, match13 and TBA: the manual refresh, and which rating teams
 * see. A full admin sets the site-wide default; a team admin sets their own
 * team, where Default means "whatever the full admin chose".
 */
export function StatSourcesCard({ isFullAdmin }: { isFullAdmin: boolean }) {
  const refreshAll = useAction(api.refresh.now);
  const epa = useQuery(api.statbotics.forEvent);
  const xp = useQuery(api.match13.forEvent);
  const choice = useQuery(api.statSite.mine);
  const setDefault = useMutation(api.statSite.setDefault);
  const setForTeam = useMutation(api.statSite.setForTeam);
  const [refreshing, setRefreshing] = useState(false);
  const [saving, setSaving] = useState(false);

  const counts = [
    epa?.fetchedAt ? `EPA ${epa.rows.length} teams` : null,
    xp?.fetchedAt ? `xP ${xp.rows.length} teams` : null,
  ].filter((part): part is string => part !== null);
  const pulledAt = Math.max(epa?.fetchedAt ?? 0, xp?.fetchedAt ?? 0);
  const status = counts.length === 0
    ? "Never pulled yet"
    : `${counts.join(" · ")} · pulled ${new Date(pulledAt).toLocaleString()}`;

  const save = (run: () => Promise<unknown>, done: string) => {
    setSaving(true);
    void run()
      .then(() => toast.success(done))
      .catch((error: unknown) =>
        toast.error("Could not save", { description: errorText(error) }))
      .finally(() => setSaving(false));
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>Statbotics, match13 &amp; TBA</CardTitle>
        <CardDescription>
          EPA, xP and match scores refresh together every two hours, and only
          while a team has an event active. Pull them now if you want the
          numbers current before alliance selection.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="flex flex-wrap items-center gap-3">
          <Button variant="outline" disabled={refreshing}
            onClick={() => {
              setRefreshing(true);
              void refreshAll({})
                .then((r) => {
                  const summary =
                    `EPA for ${r.epaTeams} teams · xP for ${r.xpTeams} teams · ` +
                    `${r.matchesUpdated} matches updated.`;
                  if (r.problems.length > 0) {
                    toast.warning("Refreshed, with problems", {
                      description: `${summary} ${r.problems.join(" · ")}`,
                    });
                  } else {
                    toast.success("Refreshed", { description: summary });
                  }
                })
                .catch((error: unknown) =>
                  toast.error("Refresh failed", { description: errorText(error) }))
                .finally(() => setRefreshing(false));
            }}>
            {refreshing ? <LoaderCircle className="size-4 animate-spin" /> : null}
            Refresh Statbotics/match13/TBA
          </Button>
          <span className="text-muted-foreground text-xs">{status}</span>
        </div>

        {choice === undefined ? null : isFullAdmin ? (
          <div className="space-y-2 border-t pt-4">
            <p className="text-sm font-medium">Default stat site</p>
            <Segmented label="Default stat site" value={choice.siteWide}
              options={SITE_OPTIONS} disabled={saving}
              onChange={(next) => save(
                () => setDefault({ site: next }),
                `Default stat site is now ${STAT_SITE_NAME[next]}`,
              )} />
            <p className="text-muted-foreground text-xs">
              Used by every team left on Default. Teams that picked a site keep
              their choice.
            </p>
          </div>
        ) : choice.teamNumber === null ? (
          <p className="text-muted-foreground border-t pt-4 text-xs">
            Add a team number to your profile to choose a stat site for your team.
          </p>
        ) : (
          <div className="space-y-2 border-t pt-4">
            <p className="text-sm font-medium">Stat site for team {choice.teamNumber}</p>
            <Segmented label={`Stat site for team ${choice.teamNumber}`}
              value={choice.team ?? "default"} options={TEAM_OPTIONS} disabled={saving}
              onChange={(next) => save(
                () => setForTeam({ site: next }),
                next === "default"
                  ? "Following the site-wide default"
                  : `Team ${choice.teamNumber} now uses ${STAT_SITE_NAME[next]}`,
              )} />
            <p className="text-muted-foreground text-xs">
              {choice.team === null
                ? `Follows the site-wide default, currently ${STAT_SITE_NAME[choice.siteWide]}. ` +
                  `Your team sees ${STAT_SITE_METRIC[choice.siteWide]}.`
                : `Your team sees ${STAT_SITE_METRIC[choice.team]} from ` +
                  `${STAT_SITE_NAME[choice.team]}, whatever the site-wide default is.`}
            </p>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
