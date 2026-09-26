import {
  DndContext, DragOverlay, PointerSensor, TouchSensor, closestCorners,
  pointerWithin, useDroppable, useSensor, useSensors,
  type CollisionDetection, type DragEndEvent, type DragOverEvent,
  type DragStartEvent,
} from "@dnd-kit/core";
import { SortableContext, useSortable, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { useMutation, useQuery } from "convex/react";
import { ArrowLeft, Check, GripVertical, MessageSquare, MessageSquareWarning } from "lucide-react";
import { useMemo, useState } from "react";
import { Link, useParams } from "react-router";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { NotesTeamDetail } from "./team-detail";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { TIERS, TIER_LABELS, type Tier } from "@/lib/types";

/**
 * The pick list board for a notes-only season. The same lists, tiers, drag
 * and picked ticks as the 2026 board, which is where this was copied from;
 * what is gone is everything counted: no stat sorts, no stat line on the
 * cards, and the notes team modal in place of the 2026 one.
 */

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
          <span className="text-destructive text-xs">Required for first picks and dnps</span>
        ) : null}
      </div>
      <Textarea rows={3} value={text} disabled={!canEdit} placeholder="Pick notes"
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

function Column({ tier, rows, children }: { tier: Tier; rows: Row[]; children: React.ReactNode }) {
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
      <div className="min-h-0 flex-1 space-y-2 overflow-y-auto overscroll-contain">{children}</div>
    </div>
  );
}

function Chip({
  row, pitNoted, draggable, picked, onTogglePicked, onOpen,
}: {
  row: Row;
  pitNoted: boolean;
  draggable: boolean;
  picked: boolean;
  onTogglePicked?: () => void;
  onOpen: () => void;
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } =
    useSortable({ id: row.entryId, disabled: !draggable });
  const needsNote = (row.tier === "t1" || row.tier === "dnp") && row.note.trim() === "";

  return (
    <div ref={setNodeRef}
      style={{ transform: CSS.Translate.toString(transform), transition }}
      className={["bg-background rounded-lg border p-2", isDragging ? "opacity-40" : ""].join(" ")}>
      <div className="flex items-center gap-1.5">
        {draggable ? (
          <button {...attributes} {...listeners} aria-label={`Reorder team ${row.teamNumber}`}
            className="text-muted-foreground touch-none p-1">
            <GripVertical className="size-4" />
          </button>
        ) : null}
        <button onClick={onOpen} className="min-w-0 flex-1 text-left">
          <span className="font-semibold tabular-nums">{row.teamNumber}</span>
          <span className="text-muted-foreground ml-1.5 text-xs">{row.nickname}</span>
        </button>
        {needsNote ? (
          <MessageSquareWarning className="text-destructive size-4 shrink-0" />
        ) : row.note ? (
          <MessageSquare className="text-muted-foreground size-4 shrink-0" />
        ) : null}
        {onTogglePicked ? (
          <Button size="icon" variant={picked ? "secondary" : "ghost"} className="size-6 shrink-0"
            aria-label={picked ? `Unmark ${row.teamNumber} as picked` : `Mark ${row.teamNumber} as picked`}
            onClick={(e) => { e.stopPropagation(); onTogglePicked(); }}>
            <Check className="size-3.5" />
          </Button>
        ) : null}
        <Badge variant={pitNoted ? "secondary" : "outline"} className="shrink-0 text-[10px]">
          {pitNoted ? "Pit notes" : "No pit"}
        </Badge>
      </div>
      {row.note ? <p className="mt-1 line-clamp-2 pl-1 text-[11px] italic">{row.note}</p> : null}
    </div>
  );
}

export default function NotesPickListBoardPage() {
  const params = useParams();
  const listId = params.listId as Id<"pickLists"> | undefined;

  const list = useQuery(api.pickLists.get, listId ? { listId } : "skip");
  const entries = useQuery(api.entries.forList, listId ? { listId } : "skip");
  const teams = useQuery(api.notes.teams);
  const move = useMutation(api.entries.move);
  const picked = useQuery(api.picked.forEvent);
  const togglePicked = useMutation(api.picked.toggle);

  const [dragging, setDragging] = useState<Row | null>(null);
  const [overTier, setOverTier] = useState<Tier | null>(null);
  const [selectedTeam, setSelectedTeam] = useState<number | null>(null);
  const [search, setSearch] = useState("");
  const [showPicked, setShowPicked] = useState(false);

  const collision: CollisionDetection = (args) => {
    const within = pointerWithin(args);
    return within.length > 0 ? within : closestCorners(args);
  };
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 200, tolerance: 8 } }),
  );

  const pitByTeam = useMemo(
    () => new Map<string, boolean>((teams ?? []).map((t) => [t.teamId, t.pitNoted])),
    [teams],
  );

  const byTier = useMemo(() => {
    const map = new Map<Tier, Row[]>();
    for (const tier of TIERS) map.set(tier, []);
    for (const row of (entries ?? []) as Row[]) map.get(row.tier)?.push(row);
    for (const rows of map.values()) rows.sort((a, b) => a.order - b.order);

    const pickedSet = new Set(picked ?? []);
    if (!showPicked) {
      for (const [tier, rows] of map) map.set(tier, rows.filter((r) => !pickedSet.has(r.teamId)));
    }
    const needle = search.trim().toLowerCase();
    if (needle !== "") {
      const hit = (r: Row) =>
        String(r.teamNumber).includes(needle) || r.nickname.toLowerCase().includes(needle);
      for (const [tier, rows] of map) {
        map.set(tier, tier === "uncategorized"
          ? [...rows].sort((a, b) => Number(hit(b)) - Number(hit(a)))
          : rows.filter(hit));
      }
    }
    return map;
  }, [entries, search, picked, showPicked]);

  const searching = search.trim() !== "";
  const selectedRow = ((entries ?? []) as Row[]).find((r) => r.teamNumber === selectedTeam) ?? null;

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
    if (!over) { setOverTier(null); return; }
    const rows = (entries ?? []) as Row[];
    const moved = rows.find((r) => r.entryId === active.id);
    if (!moved) return;
    const overId = String(over.id);
    const target = resolveTier(overId) ?? overTier;
    if (!target) return;
    const column = (byTier.get(target) ?? []).filter((r) => r.entryId !== moved.entryId);
    const index = overId.startsWith("col:") ? column.length : column.findIndex((r) => r.entryId === overId);
    const at = index < 0 ? column.length : index;
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
      <Input className="max-w-56" placeholder="Find a team"
        value={search} onChange={(e) => setSearch(e.target.value)} />

      <div className="flex flex-wrap items-center gap-2">
        <Button size="sm" variant={showPicked ? "secondary" : "outline"}
          onClick={() => setShowPicked(!showPicked)}>
          Show picked {showPicked ? "✓" : ""}
        </Button>
        <span className="text-muted-foreground text-xs">
          {(picked ?? []).length} taken
          {list.isPrimary && list.canEdit ? " · tick a team to mark it picked" : " · marked on the team primary list"}
        </span>
      </div>

      <DndContext sensors={sensors} collisionDetection={collision}
        onDragStart={onDragStart} onDragOver={onDragOver} onDragEnd={onDragEnd}>
        <div className="flex gap-3 overflow-x-auto pb-2">
          {TIERS.map((tier) => {
            const rows = byTier.get(tier) ?? [];
            return (
              <Column key={tier} tier={tier} rows={rows}>
                <SortableContext items={rows.map((r) => r.entryId)} strategy={verticalListSortingStrategy}>
                  {rows.map((row) => (
                    <Chip key={row.entryId} row={row}
                      pitNoted={pitByTeam.get(row.teamId) ?? false}
                      draggable={list.canEdit && (!searching || row.tier === "uncategorized")}
                      picked={(picked ?? []).includes(row.teamId)}
                      onTogglePicked={
                        list.isPrimary && list.canEdit
                          ? () => {
                              void togglePicked({ teamId: row.teamId as Id<"teams"> })
                                .catch((error: unknown) =>
                                  toast.error("Could not update", {
                                    description: error instanceof Error ? error.message : String(error),
                                  }));
                            }
                          : undefined
                      }
                      onOpen={() => setSelectedTeam(row.teamNumber)} />
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
              <span className="text-muted-foreground ml-1.5 text-xs">{dragging.nickname}</span>
            </div>
          ) : null}
        </DragOverlay>
      </DndContext>

      <NotesTeamDetail
        teamNumber={selectedTeam}
        onClose={() => setSelectedTeam(null)}
        footer={selectedRow ? (
          <PickNote key={selectedRow.entryId} row={selectedRow} canEdit={list.canEdit} />
        ) : null}
      />
    </PageShell>
  );
}
