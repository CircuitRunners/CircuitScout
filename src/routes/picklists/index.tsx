import { useMutation, useQuery } from "convex/react";
import { Check, GitMerge, ListPlus, Lock, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";

export default function PickListsPage() {
  const mine = useQuery(api.pickLists.listMine);
  const primary = useQuery(api.pickLists.primary);
  const orphan = useQuery(api.pickLists.orphanPrimary);
  const claimOrphan = useMutation(api.pickLists.claimOrphanPrimary);
  const profile = useQuery(api.profiles.me);
  const create = useMutation(api.pickLists.create);
  const remove = useMutation(api.pickLists.remove);
  const setSubmitted = useMutation(api.pickLists.setSubmitted);
  const unsubmit = useMutation(api.pickLists.unsubmit);
  const ensurePrimary = useMutation(api.pickLists.ensurePrimary);
  const navigate = useNavigate();
  
  const isAnyAdmin =
    profile?.role === "admin" || profile?.role === "teamAdmin";

  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);

  const syncPrimary = useMutation(api.pickLists.syncPrimary);
  useEffect(() => {
    void syncPrimary({});
  }, [syncPrimary]);

  const add = async () => {
    setBusy(true);
    try {
      const listId = await create({ name });
      setName("");
      void navigate(`/picklists/${listId}`);
    } catch (error) {
      toast.error("Could not create the list", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  const submittedId = mine?.find((l) => l.isSubmitted)?._id ?? null;

  return (
    <PageShell
      title="Pick lists"
      description="The team primary list, and your own working lists."
    >
      <Card>
        <CardHeader>
          <CardTitle>Team primary list</CardTitle>
          <CardDescription>
            What the team acts on during alliance selection. Admin only, and it
            starts blank — Merge fills it from everyone's submitted lists.
          </CardDescription>
        </CardHeader>
        <CardContent>
          {primary === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : primary === null ? (            isAnyAdmin ? (
              <div className="space-y-3">
                {orphan ? (
                  <div className="space-y-2 rounded-lg border border-dashed p-3">
                    <p className="text-sm">
                      There is a primary list here — <strong>{orphan.name}</strong>,
                      with {orphan.ranked} of {orphan.total} teams ranked — from
                      before lists belonged to a team.
                    </p>
                    <p className="text-muted-foreground text-xs">
                      Adopting it keeps every card and note exactly where it is.
                    </p>
                    <Button size="sm"
                      onClick={() => {
                        void claimOrphan({ listId: orphan.listId })
                          .then((r) => toast.success(`Adopted for team ${r.teamNumber}`))
                          .catch((error: unknown) =>
                            toast.error("Could not adopt it", {
                              description:
                                error instanceof Error ? error.message : String(error),
                            }));
                      }}>
                      Adopt this list
                    </Button>
                  </div>
                ) : null}
                <Button variant="outline" onClick={() => void ensurePrimary({})}>
                  {orphan ? "Or start a fresh one" : "Create the primary list"}
                </Button>
              </div>
            ) : (
              <p className="text-muted-foreground text-sm">
                No primary list yet. An admin needs to create it.
              </p>
            )
          ) : (
            <div className="flex flex-wrap items-center gap-3 rounded-lg border p-3">
              <span className="min-w-0 flex-1 truncate font-medium">{primary.name}</span>
              <span className="text-muted-foreground text-xs tabular-nums">
                {primary.ranked} ranked
              </span>
              {!isAnyAdmin ? (
                <Badge variant="outline"><Lock className="size-3" /> Read only</Badge>
              ) : null}
              <Button size="sm" variant="outline"
                render={<Link to={`/picklists/${primary._id}`} />}>
                Open
              </Button>
              {isAnyAdmin ? (
                <Button size="sm" variant="secondary"
                  render={<Link to="/admin/merge" />}>
                  <GitMerge className="size-4" />
                  Merge
                </Button>
              ) : null}
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>My lists</CardTitle>
          <CardDescription>
            Keep as many as you like. Exactly one can be marked for submission —
            that is the one the merge reads.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <div className="flex gap-2">
            <Input placeholder="New list name" value={name}
              onChange={(e) => setName(e.target.value)} />
            <Button disabled={busy || name.trim() === ""} onClick={() => void add()}>
              <ListPlus className="size-4" /> Create
            </Button>
          </div>

          {mine === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : mine.length === 0 ? (
            <p className="text-muted-foreground rounded-lg border border-dashed p-6 text-center text-sm">
              No lists yet. A new list starts with every team in Uncategorized.
            </p>
          ) : (
            mine.map((list) => (
              <div key={list._id}
                className="flex flex-wrap items-center gap-3 rounded-lg border p-3">
                <span className="min-w-0 flex-1 truncate font-medium">{list.name}</span>
                <span className="text-muted-foreground text-xs tabular-nums">
                  {list.ranked}/{list.total} ranked
                </span>
                {list.isSubmitted ? (
                  <Badge><Check className="size-3" /> Submitted</Badge>
                ) : null}
                <Button size="sm" variant={list.isSubmitted ? "outline" : "secondary"}
                  onClick={() => {
                    if (list.isSubmitted) void unsubmit({ listId: list._id });
                    else void setSubmitted({ listId: list._id });
                  }}>
                  {list.isSubmitted ? "Withdraw" : "Submit"}
                </Button>
                <Button size="sm" variant="outline"
                  render={<Link to={`/picklists/${list._id}`} />}>
                  Open
                </Button>
                <Button size="sm" variant="ghost" aria-label={`Delete ${list.name}`}
                  onClick={() => {
                    void remove({ listId: list._id as Id<"pickLists"> })
                      .then(() => toast.success(`${list.name} deleted`))
                      .catch((error: unknown) =>
                        toast.error("Could not delete", {
                          description: error instanceof Error ? error.message : String(error),
                        }));
                  }}>
                  <Trash2 className="size-4" />
                </Button>
              </div>
            ))
          )}

          {mine && mine.length > 0 && submittedId === null ? (
            <p className="text-muted-foreground text-xs">
              None of your lists is marked for submission, so none of them will
              reach the merge.
            </p>
          ) : null}
        </CardContent>
      </Card>
    </PageShell>
  );
}
