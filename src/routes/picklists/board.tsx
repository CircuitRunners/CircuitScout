import {
  DndContext, DragOverlay, PointerSensor, TouchSensor, closestCorners,
  pointerWithin, useDroppable, useSensor, useSensors,
  type CollisionDetection, type DragEndEvent, type DragOverEvent,
  type DragStartEvent,
} from "@dnd-kit/core";
import { SortableContext, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { useMutation, useQuery } from "convex/react";
import { ArrowDownWideNarrow, ArrowLeft, ArrowUpNarrowWide } from "lucide-react";
import { useMemo, useState } from "react";
import { Link, useParams } from "react-router";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { PageShell } from "@/routes/page-shell";
import { TeamChip, type ChipStats } from "./team-chip";
import { TeamDetail } from "@/routes/teams/team-detail";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
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
  note: string;
};

function PickNote({ row, canEdit }: { row: Row; canEdit: boolean }) {
  const setNote = useMutation(api.entries.setNote);
  const [text, setText] = useState(row.note);
  const [saving, setSaving] = useState(false);
  const required = row.tier === "t1" || row.tier === "dnp";
  const dirty = text !== row.note;

  return (
    <div className="space-y-2 border-t pt-4">
      <div className="flex items-baseline justify-between">
        <h3 className="font-medium">Pick notes</h3>
        {required ? (
          <span className="text-destructive text-xs">
            Required for first picks and dnps
          </span>
        ) : null}
      </div>
      <p className="text-muted-foreground text-xs">
        Why this team sits where it does. Whoever reads the list during alliance
        selection was not in your head when you ranked it.
      </p>
      <Textarea rows={3} value={text} disabled={!canEdit}
        placeholder="Pick notes"
        onChange={(e) => setText(e.target.value)} />
      {canEdit ? (
        <Button size="sm" disabled={!dirty || saving}
          onClick={() => {
            setSaving(true);
            void setNote({ entryId: row.entryId as Id<"pickListEntries">, note: text })
              .then(() => toast.success("Note saved"))
              .catch((error: unknown) =>
                toast.error("Could not save", {
                  description: error instanceof Error ? error.message : String(error),
                }))
              .finally(() => setSaving(false));
          }}>
          {dirty ? "Save note" : "Saved"}
        </Button>
      ) : null}
    </div>
  );
}

function Column({
  tier, rows, children,
}: { tier: Tier; rows: Row[]; children: React.ReactNode }) {
  const { setNodeRef, isOver } = useDroppable({ id: `col:${tier}` });
  return (
    <div ref={setNodeRef}
      className={[
        "flex max-h-[70vh] min-h-32 min-w-64 flex-1 flex-col gap-2 rounded-lg border p-2 transition-colors",
        isOver ? "bg-accent border-secondary" : "",
      ].join(" ")}>
      <div className="flex shrink-0 items-center justify-between px-1">
        <span className="text-sm font-medium">{TIER_LABELS[tier]}</span>
        <span className="text-muted-foreground text-xs tabular-nums">{rows.length}</span>
      </div>
      {/* The cards scroll, the heading stays put — a column you cannot see the
          name of is hard to drop into with any confidence. */}
      <div className="min-h-0 flex-1 space-y-2 overflow-y-auto overscroll-contain">
        {children}
      </div>
    </div>
  );
}

export default function PickListBoardPage() {
  const params = useParams();
  const listId = params.listId as Id<"pickLists"> | undefined;

  const list = useQuery(api.pickLists.get, listId ? { listId } : "skip");
  const entries = useQuery(api.entries.forList, listId ? { listId } : "skip");
  const teams = useQuery(api.teams.listWithStatus);
  const stats = useQuery(api.stats.forEvent);
  const move = useMutation(api.entries.move);
  const picked = useQuery(api.picked.forEvent);
  const togglePicked = useMutation(api.picked.toggle);

  const sort = useUIStore((s) => s.uncategorizedSort);
  const setSort = useUIStore((s) => s.setUncategorizedSort);
  const [dragging, setDragging] = useState<Row | null>(null);
  // The last column the pointer was over. dnd-kit reports `over` as null at
  // the moment of release often enough that relying on it alone loses drops.
  const [overTier, setOverTier] = useState<Tier | null>(null);
  const [selectedTeam, setSelectedTeam] = useState<number | null>(null);
  const [search, setSearch] = useState("");
  const [showPicked, setShowPicked] = useState(false);

  // pointerWithin resolves a column the pointer is actually inside, which is
  // what makes a drop onto empty space in a tier work. closestCorners is the
  // fallback for when the pointer is between columns.
  const collision: CollisionDetection = (args) => {
    const within = pointerWithin(args);
    return within.length > 0 ? within : closestCorners(args);
  };

  // A press delay is what keeps a scroll gesture from starting a drag. Without
  // it every attempt to scroll the board picks up a card instead.
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 200, tolerance: 8 } }),
  );

  const pitByTeam = useMemo(
    () => new Map<string, boolean>((teams ?? []).map((t) => [t._id, t.pitScouted])),
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
    const pickedSet = new Set(picked ?? []);
    if (!showPicked) {
      for (const [tier, rows] of map) {
        map.set(tier, rows.filter((r) => !pickedSet.has(r.teamId)));
      }
    }

    const needle = search.trim().toLowerCase();
    if (needle !== "") {
      const hit = (r: Row) =>
        String(r.teamNumber).includes(needle) ||
        r.nickname.toLowerCase().includes(needle);

      for (const [tier, rows] of map) {
        if (tier === "uncategorized") {
          // Float matches to the top rather than hiding the rest: every card
          // stays present, so a drop still lands between real neighbours.
          map.set(tier, [...rows].sort((a, b) => Number(hit(b)) - Number(hit(a))));
        } else {
          map.set(tier, rows.filter(hit));
        }
      }
    }
    return map;
  }, [entries, sort, stats, search, picked, showPicked]);

  const searching = search.trim() !== "";
  const selectedRow = ((entries ?? []) as Row[]).find(
    (r) => r.teamNumber === selectedTeam,
  ) ?? null;

  const resolveTier = (overId: string | null): Tier | null => {
    if (!overId) return null;
    if (overId.startsWith("col:")) return overId.slice(4) as Tier;
    return ((entries ?? []) as Row[]).find((r) => r.entryId === overId)?.tier ?? null;
  };

  const onDragStart = (event: DragStartEvent) => {
    const row = (entries as Row[] | undefined)?.find((r) => r.entryId === event.active.id);
    setDragging(row ?? null);
    setOverTier(row?.tier ?? null);
  };

  const onDragOver = (event: DragOverEvent) => {
    const tier = resolveTier(event.over ? String(event.over.id) : null);
    if (tier) setOverTier(tier);
  };

  const onDragEnd = (event: DragEndEvent) => {
    setDragging(null);
    const { active, over } = event;
    if (!over) {
      setOverTier(null);
      return;
    }

    const rows = (entries ?? []) as Row[];
    const moved = rows.find((r) => r.entryId === active.id);
    if (!moved) return;

    const overId = String(over.id);
    const target = resolveTier(overId) ?? overTier;
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
        <Input className="max-w-56" placeholder="Find a team"
          value={search} onChange={(e) => setSearch(e.target.value)} />
      </div>

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

      {/* Everyone can hide or reveal picked teams on the list they are looking
          at. Only the primary list carries the tick that SETS them, since that
          records what the team actually did in the draft. */}
      <div className="flex flex-wrap items-center gap-2">
        <Button size="sm" variant={showPicked ? "secondary" : "outline"}
          onClick={() => setShowPicked(!showPicked)}>
          Show picked {showPicked ? "✓" : ""}
        </Button>
        <span className="text-muted-foreground text-xs">
          {(picked ?? []).length} taken
          {list.isPrimary && list.canEdit
            ? " · tick a team to mark it picked"
            : " · marked on the team primary list"}
        </span>
      </div>

      <DndContext sensors={sensors} collisionDetection={collision}
        onDragStart={onDragStart} onDragOver={onDragOver} onDragEnd={onDragEnd}>
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
                      draggable={
                        list.canEdit && (!searching || row.tier === "uncategorized")
                      }
                      picked={(picked ?? []).includes(row.teamId)}
                      onTogglePicked={
                        list.isPrimary && list.canEdit
                          ? () => {
                              void togglePicked({ teamId: row.teamId as Id<"teams"> })
                                .catch((error: unknown) =>
                                  toast.error("Could not update", {
                                    description:
                                      error instanceof Error ? error.message : String(error),
                                  }));
                            }
                          : undefined
                      }
                      note={row.note}
                      needsNote={(row.tier === "t1" || row.tier === "dnp") && row.note.trim() === ""}
                      onOpen={() => setSelectedTeam(row.teamNumber)}
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

      <TeamDetail
        teamNumber={selectedTeam}
        onClose={() => setSelectedTeam(null)}
        footer={
          selectedRow ? (
            <PickNote key={selectedRow.entryId} row={selectedRow} canEdit={list.canEdit} />
          ) : null
        }
      />
    </PageShell>
  );
}
