import { useMutation, useQuery } from "convex/react";
import { AlertTriangle, ArrowLeft, Users } from "lucide-react";
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
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { SCOUT_WEIGHTS } from "@/lib/scoring";
import { TIER_LABELS } from "@/lib/types";

export default function AdminMergePage() {
  const data = useQuery(api.merge.preview);
  const apply = useMutation(api.merge.apply);

  const [includeNotes, setIncludeNotes] = useState(true);
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);

  const run = async () => {
    setBusy(true);
    try {
      const result = await apply({ includeNotes });
      toast.success(`Primary list rebuilt`, {
        description: `${result.teams} teams from ${result.from} submitted lists.`,
      });
      setConfirm("");
    } catch (error) {
      toast.error("Merge failed", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  const rows = data?.rows ?? [];
  const disagreements = rows.filter((r) => r.spread > 20).length;

  return (
    <PageShell
      title="Merge pick lists"
      description="Weighted consensus across every submitted list. Nothing is written until you apply it."
      actions={
        <Button variant="outline" render={<Link to="/admin" />}>
          <ArrowLeft className="size-4" /> Admin
        </Button>
      }
    >
      <Card>
        <CardHeader>
          <CardTitle>Who submitted</CardTitle>
          <CardDescription>
            A strategy lead counts {SCOUT_WEIGHTS.lead}×, a trusted scout{" "}
            {SCOUT_WEIGHTS.trusted}×, everyone else {SCOUT_WEIGHTS.normal}×.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          {data === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : (
            <>
              {data.submitters.length === 0 ? (
                <p className="text-sm">
                  Nobody has submitted a list yet. A scout submits from the pick
                  list page by marking one of their lists.
                </p>
              ) : (
                <div className="flex flex-wrap gap-2">
                  {data.submitters.map((sub) => (
                    <Badge key={sub.name} variant="secondary">
                      <Users className="size-3" />
                      {sub.name} · {sub.ranked} ranked ·{" "}
                      {SCOUT_WEIGHTS[sub.weightTier as keyof typeof SCOUT_WEIGHTS]}×
                    </Badge>
                  ))}
                </div>
              )}

              {/* Shown whether or not anyone has submitted — when nobody has,
                  this is the whole answer to "why is there nothing here". */}
              {data.missing.length > 0 ? (
                <div className="space-y-1">
                  <p className="text-muted-foreground text-xs">
                    Not submitted ({data.missing.length}) — a missing strategy
                    lead is worth chasing before you trust this ranking.
                  </p>
                  <div className="flex flex-wrap gap-1">
                    {data.missing.map((name) => (
                      <Badge key={name} variant="outline" className="text-xs">
                        {name}
                      </Badge>
                    ))}
                  </div>
                </div>
              ) : data.submitters.length > 0 ? (
                <p className="text-muted-foreground text-xs">
                  Everyone with an account has submitted.
                </p>
              ) : null}

              {data.targets && data.submitters.length > 0 ? (
                <p className="text-muted-foreground text-xs">
                  Tier sizes come from what the contributing lists averaged:{" "}
                  {data.targets.t1} first, {data.targets.t2} second,{" "}
                  {data.targets.t3} third.
                </p>
              ) : null}
            </>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Proposed ranking</CardTitle>
          <CardDescription>
            Spread is unweighted on purpose — it shows whether the room
            disagreed, which a weighted number would hide. Anything above 20 is
            worth a look before alliance selection.
            {disagreements > 0 ? ` ${disagreements} teams are flagged.` : ""}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-1">
          {rows.length === 0 ? (
            <p className="text-muted-foreground text-sm">
              Nothing to rank yet.
            </p>
          ) : (
            rows.map((row, i) => (
              <div key={row.teamId}
                className="flex flex-wrap items-center gap-2 rounded-lg border p-2 text-sm">
                <span className="text-muted-foreground w-6 text-xs tabular-nums">
                  {i + 1}
                </span>
                <span className="font-semibold tabular-nums">{row.teamNumber}</span>
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {row.nickname}
                </span>
                <Badge variant={row.proposedTier === "uncategorized" ? "outline" : "default"}>
                  {TIER_LABELS[row.proposedTier]}
                </Badge>
                <span className="text-muted-foreground text-xs tabular-nums">
                  {row.score.toFixed(0)}
                </span>
                <span className="text-muted-foreground text-xs tabular-nums">
                  {row.voters} vote{row.voters === 1 ? "" : "s"}
                </span>
                {row.spread > 20 ? (
                  <Badge variant="outline" className="text-xs">
                    <AlertTriangle className="size-3" />
                    spread {row.spread.toFixed(0)}
                  </Badge>
                ) : null}
                {row.dnpCount > 0 ? (
                  <Badge variant="destructive" className="text-xs">
                    {row.dnpCount} do-not-pick
                  </Badge>
                ) : null}
              </div>
            ))
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Apply to the primary list</CardTitle>
          <CardDescription>
            This replaces every tier and order on the primary list. Anything
            ranked there by hand is overwritten.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <Button variant={includeNotes ? "default" : "outline"} size="sm"
            onClick={() => setIncludeNotes(!includeNotes)}>
            {includeNotes ? "Carrying pick notes across" : "Not carrying pick notes"}
          </Button>
          <p className="text-muted-foreground text-xs">
            Notes are attributed to whoever wrote them.
          </p>

          {rows.length === 0 ? (
            <p className="text-muted-foreground rounded-lg border border-dashed p-4 text-sm">
              Nothing to apply yet. At least one scout has to mark a list for
              submission, with teams ranked on it.
            </p>
          ) : (
            <>
              <div className="space-y-2">
                <Label htmlFor="confirm">Type MERGE to confirm</Label>
                <Input id="confirm" className="max-w-40" value={confirm}
                  autoCapitalize="characters"
                  onChange={(e) => setConfirm(e.target.value)} />
              </div>
              <Button variant="destructive"
                disabled={busy || confirm.trim().toUpperCase() !== "MERGE"}
                onClick={() => void run()}>
                Rebuild the primary list
              </Button>
            </>
          )}
        </CardContent>
      </Card>
    </PageShell>
  );
}
