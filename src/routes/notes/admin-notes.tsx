import { useMutation, useQuery } from "convex/react";
import { Trash2 } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

/** The notes season's report tools: read and remove notes. */
export default function NotesAdminReports() {
  const data = useQuery(api.notes.adminList);
  const removePit = useMutation(api.notes.removePit);
  const removeMatch = useMutation(api.notes.removeMatch);
  const [confirm, setConfirm] = useState<string | null>(null);

  const run = (id: string, fn: () => Promise<unknown>) => {
    if (confirm !== id) { setConfirm(id); return; }
    setConfirm(null);
    void fn()
      .then(() => toast.success("Note removed"))
      .catch((error: unknown) =>
        toast.error("Could not remove", {
          description: error instanceof Error ? error.message : String(error),
        }));
  };

  const del = (id: string, fn: () => Promise<unknown>) => (
    <Button size="sm" variant={confirm === id ? "destructive" : "ghost"}
      aria-label="Remove note" onClick={() => run(id, fn)}>
      <Trash2 className="size-3.5" />
      {confirm === id ? "Tap again to remove" : null}
    </Button>
  );

  return (
    <Card>
      <CardHeader>
        <CardTitle>Notes</CardTitle>
        <CardDescription>
          This event is scouted with notes. Remove a note that is wrong or on the
          wrong robot; the scout can write it again.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-6">
        {data === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) : data === null ? (
          <p className="text-muted-foreground text-sm">No active event.</p>
        ) : (
          <>
            <div className="space-y-2">
              <h3 className="text-sm font-medium">Pit notes ({data.pit.length})</h3>
              {data.pit.length === 0 ? (
                <p className="text-muted-foreground text-sm">None yet.</p>
              ) : data.pit.map((n) => (
                <div key={n.id} className="flex items-start gap-3 rounded-lg border p-3">
                  <div className="min-w-0 flex-1 space-y-1">
                    <p className="text-xs font-medium">
                      Team {n.teamNumber ?? "?"}
                      <span className="text-muted-foreground font-normal">
                        {" "}· {n.scoutName} · for {n.scoutingTeam}
                      </span>
                    </p>
                    <p className="line-clamp-3 text-sm whitespace-pre-wrap">{n.notes}</p>
                  </div>
                  {del(n.id, () => removePit({ id: n.id as Id<"pitNotes"> }))}
                </div>
              ))}
            </div>
            <div className="space-y-2">
              <h3 className="text-sm font-medium">Match notes ({data.matches.length})</h3>
              {data.matches.length === 0 ? (
                <p className="text-muted-foreground text-sm">None yet.</p>
              ) : data.matches.map((n) => (
                <div key={n.id} className="flex items-start gap-3 rounded-lg border p-3">
                  <div className="min-w-0 flex-1 space-y-1">
                    <p className="text-xs font-medium">
                      Qual {n.matchNumber ?? "?"} · {n.teamNumber ?? "?"}
                      <span className="text-muted-foreground font-normal">
                        {" "}· {n.scoutName} · for {n.scoutingTeam}
                      </span>
                    </p>
                    <p className="line-clamp-3 text-sm whitespace-pre-wrap">{n.notes}</p>
                  </div>
                  {del(n.id, () => removeMatch({ id: n.id as Id<"matchNotes"> }))}
                </div>
              ))}
            </div>
          </>
        )}
      </CardContent>
    </Card>
  );
}
