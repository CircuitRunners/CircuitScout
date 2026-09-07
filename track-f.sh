#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# track-f.sh — Track F: pick lists (landing, Kanban board, drag and drop).
# Run ONCE from the REPO ROOT. Owns convex/pickLists.ts, convex/entries.ts,
# src/routes/picklists/*. No schema change.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f package.json ]] || { echo "ERROR: run from the folder with package.json" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
mkdir -p convex src/routes/picklists

say "Dependencies"
bun add @dnd-kit/core @dnd-kit/sortable @dnd-kit/utilities

say "Convex: pick lists"
cat > convex/pickLists.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import type { MutationCtx } from "./_generated/server";
import { activeEvent, currentProfile, requireAdmin, requireUser } from "./lib/guards";
import type { Doc, Id } from "./_generated/dataModel";

export const listMine = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    const userId = await requireUser(ctx);

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", userId))
      .collect();

    return await Promise.all(
      lists.map(async (list) => {
        const entries = await ctx.db
          .query("pickListEntries")
          .withIndex("by_list", (q) => q.eq("pickListId", list._id))
          .collect();
        return {
          ...list,
          ranked: entries.filter((e) => e.tier !== "uncategorized").length,
          total: entries.length,
        };
      }),
    );
  },
});

export const primary = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    const list = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", null))
      .first();
    if (!list) return null;

    const entries = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", list._id))
      .collect();
    return {
      ...list,
      ranked: entries.filter((e) => e.tier !== "uncategorized").length,
      total: entries.length,
    };
  },
});

/** Everyone's submitted lists, for the merge and for seeing who has finished. */
export const submitted = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    await requireAdmin(ctx);

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event_submitted", (q) =>
        q.eq("eventId", event._id).eq("isSubmitted", true))
      .collect();

    const profiles = await ctx.db.query("profiles").collect();
    const byUser = new Map(profiles.map((p) => [p.userId, p]));

    return lists.flatMap((list) => {
      if (list.ownerId === null) return [];
      const profile = byUser.get(list.ownerId);
      return [{
        ...list,
        ownerName: profile?.displayName ?? "Unknown scout",
        weightTier: profile?.weightTier ?? "normal",
      }];
    });
  },
});

async function assertCanEdit(
  ctx: MutationCtx,
  listId: Id<"pickLists">,
  userId: Id<"users">,
  isAdmin: boolean,
): Promise<Doc<"pickLists">> {
  const list = await ctx.db.get(listId);
  if (!list) throw new Error("That list no longer exists.");
  // The primary list is the team's, so only an admin edits it. Personal lists
  // are the scout's own working notes and nobody else touches them.
  if (list.ownerId === null) {
    if (!isAdmin) throw new Error("Only an admin can edit the primary list.");
  } else if (list.ownerId !== userId) {
    throw new Error("That is someone else's list.");
  }
  return list;
}

export const get = query({
  args: { listId: v.id("pickLists") },
  handler: async (ctx, args) => {
    const list = await ctx.db.get(args.listId);
    if (!list) return null;
    const profile = await currentProfile(ctx);
    const userId = profile?.userId ?? null;

    const canEdit =
      list.ownerId === null
        ? profile?.role === "admin"
        : list.ownerId === userId;

    return { ...list, canEdit };
  },
});

export const create = mutation({
  args: { name: v.string() },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");
    const name = args.name.trim();
    if (name === "") throw new Error("Give the list a name.");

    const listId = await ctx.db.insert("pickLists", {
      eventId: event._id,
      ownerId: userId,
      name,
      isPrimary: false,
      isSubmitted: false,
      createdAt: Date.now(),
    });

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    teams.sort((a, b) => a.number - b.number);

    // Float order, so a later drag inserts between neighbours by halving the
    // gap instead of renumbering the column.
    for (let i = 0; i < teams.length; i++) {
      const team = teams[i];
      if (!team) continue;
      await ctx.db.insert("pickListEntries", {
        pickListId: listId,
        teamId: team._id,
        tier: "uncategorized",
        order: (i + 1) * 1000,
      });
    }

    return listId;
  },
});

/** The primary list starts blank — the merge fills it. */
export const ensurePrimary = mutation({
  args: {},
  handler: async (ctx) => {
    await requireAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const existing = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", null))
      .first();
    if (existing) return existing._id;

    return await ctx.db.insert("pickLists", {
      eventId: event._id,
      ownerId: null,
      name: "Team primary list",
      isPrimary: true,
      isSubmitted: false,
      createdAt: Date.now(),
    });
  },
});

export const rename = mutation({
  args: { listId: v.id("pickLists"), name: v.string() },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);
    await assertCanEdit(ctx, args.listId, userId, profile?.role === "admin");
    const name = args.name.trim();
    if (name === "") throw new Error("Give the list a name.");
    await ctx.db.patch(args.listId, { name });
  },
});

export const remove = mutation({
  args: { listId: v.id("pickLists") },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);
    const list = await assertCanEdit(ctx, args.listId, userId, profile?.role === "admin");
    if (list.isPrimary) throw new Error("The primary list cannot be deleted.");

    const entries = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", args.listId))
      .collect();
    for (const entry of entries) await ctx.db.delete(entry._id);
    await ctx.db.delete(args.listId);
  },
});

/**
 * At most one submitted list per scout per event. The others are cleared in
 * this same mutation, so the rule is transactional rather than a convention
 * the UI is trusted to keep.
 */
export const setSubmitted = mutation({
  args: { listId: v.id("pickLists") },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const list = await ctx.db.get(args.listId);
    if (!list || list.ownerId !== userId) throw new Error("That is not your list.");

    const mine = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", userId))
      .collect();

    for (const other of mine) {
      const shouldBe = other._id === args.listId;
      if (other.isSubmitted !== shouldBe) {
        await ctx.db.patch(other._id, { isSubmitted: shouldBe });
      }
    }
  },
});

export const unsubmit = mutation({
  args: { listId: v.id("pickLists") },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const list = await ctx.db.get(args.listId);
    if (!list || list.ownerId !== userId) throw new Error("That is not your list.");
    await ctx.db.patch(args.listId, { isSubmitted: false });
  },
});
EOF

say "Convex: entries"
cat > convex/entries.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { currentProfile, requireUser } from "./lib/guards";

const tier = v.union(
  v.literal("t1"), v.literal("t2"), v.literal("t3"),
  v.literal("dnp"), v.literal("uncategorized"),
);

export const forList = query({
  args: { listId: v.id("pickLists") },
  handler: async (ctx, args) => {
    const entries = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", args.listId))
      .collect();

    const rows = [];
    for (const entry of entries) {
      const team = await ctx.db.get(entry.teamId);
      if (!team) continue;
      rows.push({
        entryId: entry._id,
        teamId: entry.teamId,
        teamNumber: team.number,
        nickname: team.nickname,
        tier: entry.tier,
        order: entry.order,
      });
    }
    return rows.sort((a, b) => a.order - b.order);
  },
});

/**
 * Moves one entry. `order` is a float chosen by the client as the midpoint
 * between its new neighbours, so a drop is a single write and no other row
 * has to be renumbered.
 */
export const move = mutation({
  args: { entryId: v.id("pickListEntries"), tier, order: v.number() },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);

    const entry = await ctx.db.get(args.entryId);
    if (!entry) throw new Error("That card no longer exists.");
    const list = await ctx.db.get(entry.pickListId);
    if (!list) throw new Error("That list no longer exists.");

    if (list.ownerId === null) {
      if (profile?.role !== "admin") {
        throw new Error("Only an admin can edit the primary list.");
      }
    } else if (list.ownerId !== userId) {
      throw new Error("That is someone else's list.");
    }

    await ctx.db.patch(args.entryId, { tier: args.tier, order: args.order });
  },
});

/**
 * Rewrites a column's order to even spacing. Only needed when repeated
 * midpoint inserts have squeezed the gaps too small to represent.
 */
export const renormalise = mutation({
  args: { listId: v.id("pickLists"), tier },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const profile = await currentProfile(ctx);
    const list = await ctx.db.get(args.listId);
    if (!list) throw new Error("That list no longer exists.");
    if (list.ownerId === null ? profile?.role !== "admin" : list.ownerId !== userId) {
      throw new Error("You cannot edit that list.");
    }

    const entries = (
      await ctx.db
        .query("pickListEntries")
        .withIndex("by_list_tier", (q) =>
          q.eq("pickListId", args.listId).eq("tier", args.tier))
        .collect()
    ).sort((a, b) => a.order - b.order);

    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      if (entry) await ctx.db.patch(entry._id, { order: (i + 1) * 1000 });
    }
  },
});
EOF

say "Client: pick list landing"
cat > src/routes/picklists/index.tsx <<'EOF'
import { useMutation, useQuery } from "convex/react";
import { Check, ListPlus, Lock, Trash2 } from "lucide-react";
import { useState } from "react";
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
  const profile = useQuery(api.profiles.me);
  const create = useMutation(api.pickLists.create);
  const remove = useMutation(api.pickLists.remove);
  const setSubmitted = useMutation(api.pickLists.setSubmitted);
  const unsubmit = useMutation(api.pickLists.unsubmit);
  const ensurePrimary = useMutation(api.pickLists.ensurePrimary);
  const navigate = useNavigate();

  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);

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
            starts blank — the merge fills it from everyone's submitted lists.
          </CardDescription>
        </CardHeader>
        <CardContent>
          {primary === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : primary === null ? (
            profile?.role === "admin" ? (
              <Button variant="outline" onClick={() => void ensurePrimary({})}>
                Create the primary list
              </Button>
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
              {profile?.role !== "admin" ? (
                <Badge variant="outline"><Lock className="size-3" /> Read only</Badge>
              ) : null}
              <Button size="sm" variant="outline"
                render={<Link to={`/picklists/${primary._id}`} />}>
                Open
              </Button>
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
EOF

say "Client: Kanban board"
cat > src/routes/picklists/team-chip.tsx <<'EOF'
import { useSortable } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { GripVertical } from "lucide-react";

import { Badge } from "@/components/ui/badge";

export type ChipStats = {
  reportCount: number;
  avgTotalFuel: number;
  avgDriver: number;
  avgDefense: number;
  avgAccuracy: number;
  avgClimbPoints: number;
};

export function TeamChip({
  entryId,
  teamNumber,
  nickname,
  pitScouted,
  stats,
  draggable,
  onOpen,
}: {
  entryId: string;
  teamNumber: number;
  nickname: string;
  pitScouted: boolean;
  stats: ChipStats | null;
  draggable: boolean;
  onOpen: () => void;
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } =
    useSortable({ id: entryId, disabled: !draggable });

  return (
    <div
      ref={setNodeRef}
      style={{ transform: CSS.Translate.toString(transform), transition }}
      className={[
        "bg-background rounded-lg border p-2",
        isDragging ? "opacity-40" : "",
      ].join(" ")}
    >
      <div className="flex items-center gap-1.5">
        {draggable ? (
          // The grip is the only drag handle, so the rest of the card stays
          // tappable and the column stays scrollable.
          <button
            {...attributes}
            {...listeners}
            aria-label={`Reorder team ${teamNumber}`}
            className="text-muted-foreground touch-none p-1"
          >
            <GripVertical className="size-4" />
          </button>
        ) : null}
        <button onClick={onOpen} className="min-w-0 flex-1 text-left">
          <span className="font-semibold tabular-nums">{teamNumber}</span>
          <span className="text-muted-foreground ml-1.5 text-xs">{nickname}</span>
        </button>
        <Badge variant={pitScouted ? "secondary" : "outline"} className="shrink-0 text-[10px]">
          {pitScouted ? "Pit" : "No pit"}
        </Badge>
      </div>
      {stats && stats.reportCount > 0 ? (
        <div className="text-muted-foreground mt-1 flex flex-wrap gap-x-2.5 gap-y-0.5 pl-1 text-[11px] tabular-nums">
          <span>fuel {stats.avgTotalFuel.toFixed(0)}</span>
          <span>climb {stats.avgClimbPoints.toFixed(0)}</span>
          <span>drv {stats.avgDriver.toFixed(1)}</span>
          <span>def {stats.avgDefense.toFixed(1)}</span>
          <span>acc {stats.avgAccuracy.toFixed(0)}%</span>
          <span className="opacity-70">n={stats.reportCount}</span>
        </div>
      ) : (
        <p className="text-muted-foreground mt-1 pl-1 text-[11px]">
          No match data — unscouted is not the same as bad.
        </p>
      )}
    </div>
  );
}
EOF

cat > src/routes/picklists/board.tsx <<'EOF'
import {
  DndContext, DragOverlay, PointerSensor, TouchSensor, closestCorners,
  useDroppable, useSensor, useSensors,
  type DragEndEvent, type DragStartEvent,
} from "@dnd-kit/core";
import { SortableContext, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { useMutation, useQuery } from "convex/react";
import { ArrowDownWideNarrow, ArrowLeft, ArrowUpNarrowWide } from "lucide-react";
import { useMemo, useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { PageShell } from "@/routes/page-shell";
import { TeamChip, type ChipStats } from "./team-chip";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { TIERS, TIER_LABELS, type Tier } from "@/lib/types";
import { useUIStore, type SortKey } from "@/stores/ui-store";

const SORTS: ReadonlyArray<{ key: SortKey; label: string }> = [
  { key: "totalFuel", label: "Fuel" },
  { key: "climbPoints", label: "Climb" },
  { key: "defense", label: "Defense" },
  { key: "driver", label: "Driver" },
];

type Row = {
  entryId: string;
  teamId: string;
  teamNumber: number;
  nickname: string;
  tier: Tier;
  order: number;
};

function Column({
  tier, rows, children,
}: { tier: Tier; rows: Row[]; children: React.ReactNode }) {
  const { setNodeRef, isOver } = useDroppable({ id: `col:${tier}` });
  return (
    <div ref={setNodeRef}
      className={[
        "min-w-64 flex-1 space-y-2 rounded-lg border p-2 transition-colors",
        isOver ? "bg-accent/50" : "",
      ].join(" ")}>
      <div className="flex items-center justify-between px-1">
        <span className="text-sm font-medium">{TIER_LABELS[tier]}</span>
        <span className="text-muted-foreground text-xs tabular-nums">{rows.length}</span>
      </div>
      {children}
    </div>
  );
}

export default function PickListBoardPage() {
  const params = useParams();
  const navigate = useNavigate();
  const listId = params.listId as Id<"pickLists"> | undefined;

  const list = useQuery(api.pickLists.get, listId ? { listId } : "skip");
  const entries = useQuery(api.entries.forList, listId ? { listId } : "skip");
  const teams = useQuery(api.teams.listWithStatus);
  const stats = useQuery(api.stats.forEvent);
  const move = useMutation(api.entries.move);

  const sort = useUIStore((s) => s.uncategorizedSort);
  const setSort = useUIStore((s) => s.setUncategorizedSort);
  const [dragging, setDragging] = useState<Row | null>(null);

  // A press delay is what keeps a scroll gesture from starting a drag. Without
  // it every attempt to scroll the board picks up a card instead.
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 200, tolerance: 8 } }),
  );

  const pitByTeam = useMemo(
    () => new Map((teams ?? []).map((t) => [t._id, t.pitScouted])),
    [teams],
  );

  const statFor = (teamId: string): ChipStats | null => {
    const s = stats?.[teamId];
    return s ? (s as ChipStats) : null;
  };

  const byTier = useMemo(() => {
    const map = new Map<Tier, Row[]>();
    for (const tier of TIERS) map.set(tier, []);
    for (const row of (entries ?? []) as Row[]) {
      map.get(row.tier)?.push(row);
    }
    for (const [tier, rows] of map) {
      rows.sort((a, b) => a.order - b.order);
      // Sorting Uncategorized is a VIEW. It never rewrites stored order, so one
      // tap cannot discard an afternoon of manual ranking.
      if (tier === "uncategorized" && sort) {
        const value = (r: Row) => {
          const s = statFor(r.teamId);
          if (!s) return -1;
          switch (sort.key) {
            case "totalFuel": return s.avgTotalFuel;
            case "climbPoints": return s.avgClimbPoints;
            case "defense": return s.avgDefense;
            case "driver": return s.avgDriver;
          }
        };
        rows.sort((a, b) =>
          sort.direction === "asc" ? value(a) - value(b) : value(b) - value(a));
      }
    }
    return map;
  }, [entries, sort, stats]);

  const onDragStart = (event: DragStartEvent) => {
    const row = (entries as Row[] | undefined)?.find((r) => r.entryId === event.active.id);
    setDragging(row ?? null);
  };

  const onDragEnd = (event: DragEndEvent) => {
    setDragging(null);
    const { active, over } = event;
    if (!over) return;

    const rows = (entries ?? []) as Row[];
    const moved = rows.find((r) => r.entryId === active.id);
    if (!moved) return;

    const overId = String(over.id);
    const target = overId.startsWith("col:")
      ? (overId.slice(4) as Tier)
      : rows.find((r) => r.entryId === overId)?.tier;
    if (!target) return;

    const column = (byTier.get(target) ?? []).filter((r) => r.entryId !== moved.entryId);
    const index = overId.startsWith("col:")
      ? column.length
      : column.findIndex((r) => r.entryId === overId);
    const at = index < 0 ? column.length : index;

    // Midpoint between neighbours: one write, nothing else renumbered.
    const before = column[at - 1]?.order ?? 0;
    const after = column[at]?.order ?? before + 2000;
    const order = (before + after) / 2;

    if (target === moved.tier && Math.abs(order - moved.order) < 1e-9) return;

    void move({ entryId: moved.entryId as Id<"pickListEntries">, tier: target, order })
      .catch((error: unknown) =>
        toast.error("Could not move that card", {
          description: error instanceof Error ? error.message : String(error),
        }));
  };

  if (!listId) return <PageShell title="Pick list" description="Bad URL." />;
  if (list === undefined || entries === undefined) {
    return <PageShell title="Pick list" description="Loading…" />;
  }
  if (list === null) {
    return (
      <PageShell title="Pick list" description="That list no longer exists.">
        <Button variant="outline" render={<Link to="/picklists" />}>
          <ArrowLeft className="size-4" /> All lists
        </Button>
      </PageShell>
    );
  }

  return (
    <PageShell
      title={list.name}
      description="Tier 1 is highest. Drag by the grip to move a team between tiers."
      actions={
        <div className="flex flex-wrap gap-2">
          {!list.canEdit ? <Badge variant="outline">Read only</Badge> : null}
          <Button variant="outline" render={<Link to="/picklists" />}>
            <ArrowLeft className="size-4" /> All lists
          </Button>
        </div>
      }
    >
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-muted-foreground text-xs">Sort Uncategorized</span>
        {SORTS.map((s) => {
          const active = sort?.key === s.key;
          return (
            <Button key={s.key} size="sm" variant={active ? "default" : "outline"}
              onClick={() =>
                setSort(
                  active && sort?.direction === "desc"
                    ? { key: s.key, direction: "asc" }
                    : { key: s.key, direction: "desc" },
                )
              }>
              {s.label}
              {active
                ? sort?.direction === "desc"
                  ? <ArrowDownWideNarrow className="size-3" />
                  : <ArrowUpNarrowWide className="size-3" />
                : null}
            </Button>
          );
        })}
        {sort ? (
          <Button size="sm" variant="ghost" onClick={() => setSort(null)}>
            Clear
          </Button>
        ) : null}
        {sort ? (
          <span className="text-muted-foreground text-xs">
            View only — stored order is untouched.
          </span>
        ) : null}
      </div>

      <DndContext sensors={sensors} collisionDetection={closestCorners}
        onDragStart={onDragStart} onDragEnd={onDragEnd}>
        <div className="flex gap-3 overflow-x-auto pb-2">
          {TIERS.map((tier) => {
            const rows = byTier.get(tier) ?? [];
            return (
              <Column key={tier} tier={tier} rows={rows}>
                <SortableContext items={rows.map((r) => r.entryId)}
                  strategy={verticalListSortingStrategy}>
                  {rows.map((row) => (
                    <TeamChip
                      key={row.entryId}
                      entryId={row.entryId}
                      teamNumber={row.teamNumber}
                      nickname={row.nickname}
                      pitScouted={pitByTeam.get(row.teamId) ?? false}
                      stats={statFor(row.teamId)}
                      draggable={list.canEdit}
                      onOpen={() => void navigate(`/teams?team=${row.teamNumber}`)}
                    />
                  ))}
                </SortableContext>
              </Column>
            );
          })}
        </div>

        <DragOverlay>
          {dragging ? (
            <div className="bg-background rounded-lg border p-2 shadow-lg">
              <span className="font-semibold tabular-nums">{dragging.teamNumber}</span>
              <span className="text-muted-foreground ml-1.5 text-xs">
                {dragging.nickname}
              </span>
            </div>
          ) : null}
        </DragOverlay>
      </DndContext>
    </PageShell>
  );
}
EOF

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Track F written. Open /picklists, create a list, and drag by the grip handle.

DONE
