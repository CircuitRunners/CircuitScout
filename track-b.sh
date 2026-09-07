#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# track-b.sh — Track B: pit scouting (grid landing, form, photo upload).
# Run from the REPO ROOT in Git Bash. Run ONCE; after that edit files directly.
# Owns: convex/pit.ts, src/routes/pit/*, src/lib/compress-image.ts
# Does NOT touch convex/schema.ts (frozen) or any other track's files.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f package.json ]] || { echo "ERROR: run from the folder with package.json" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Convex: pit scouting"
cat > convex/pit.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent, requireUser } from "./lib/guards";

const scoringInput = v.object({
  turret: v.boolean(),
  drumNonFullWidth: v.boolean(),
  drumFullWidth: v.boolean(),
  fixed: v.boolean(),
  kitbot: v.boolean(),
  other: v.boolean(),
  otherText: v.string(),
});

const climbInput = v.object({
  low: v.boolean(),
  mid: v.boolean(),
  high: v.boolean(),
  duringAuto: v.boolean(),
});

export const get = query({
  args: { teamId: v.id("teams") },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;
    return await ctx.db
      .query("pitReports")
      .withIndex("by_event_team", (q) =>
        q.eq("eventId", event._id).eq("teamId", args.teamId))
      .unique();
  },
});

/**
 * Resolves a team by its number for the /pit/:teamNumber route, and returns
 * any existing report alongside it. Kept here rather than in teams.ts so this
 * track owns every file it writes.
 */
export const forTeamNumber = query({
  args: { teamNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;

    const team = await ctx.db
      .query("teams")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("number", args.teamNumber))
      .unique();
    if (!team) return null;

    const report = await ctx.db
      .query("pitReports")
      .withIndex("by_event_team", (q) =>
        q.eq("eventId", event._id).eq("teamId", team._id))
      .unique();

    const photoUrl = report?.photoId
      ? await ctx.storage.getUrl(report.photoId)
      : null;

    return { team, report, photoUrl };
  },
});

export const generateUploadUrl = mutation({
  args: {},
  handler: async (ctx) => {
    await requireUser(ctx);
    return await ctx.storage.generateUploadUrl();
  },
});

/**
 * One report per team per event. A second scout visiting the same pit updates
 * the existing report rather than creating a duplicate — pits get revisited,
 * and two conflicting reports for one robot is worse than one that changed.
 */
export const upsert = mutation({
  args: {
    teamId: v.id("teams"),
    scoring: scoringInput,
    climb: climbInput,
    drivetrain: v.string(),
    underTrench: v.boolean(),
    overBump: v.boolean(),
    robotNotes: v.string(),
    otherNotes: v.string(),
    photoId: v.union(v.id("_storage"), v.null()),
  },
  handler: async (ctx, args) => {
    const scoutId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const team = await ctx.db.get(args.teamId);
    if (!team || team.eventId !== event._id) {
      throw new Error("That team is not part of the active event.");
    }

    const existing = await ctx.db
      .query("pitReports")
      .withIndex("by_event_team", (q) =>
        q.eq("eventId", event._id).eq("teamId", args.teamId))
      .unique();

    const fields = {
      scoring: args.scoring,
      climb: args.climb,
      drivetrain: args.drivetrain,
      underTrench: args.underTrench,
      overBump: args.overBump,
      robotNotes: args.robotNotes,
      otherNotes: args.otherNotes,
      // Keep the old photo when this save did not include a new one.
      photoId: args.photoId ?? existing?.photoId ?? null,
      scoutId,
      updatedAt: Date.now(),
    };

    if (existing) {
      await ctx.db.patch(existing._id, fields);
      return existing._id;
    }
    return await ctx.db.insert("pitReports", {
      eventId: event._id,
      teamId: args.teamId,
      ...fields,
    });
  },
});
EOF

say "Client: image compression"
cat > src/lib/compress-image.ts <<'EOF'
/**
 * Downscale and re-encode before upload.
 *
 * A modern phone camera produces 4-8MB per shot. Fifty pits on venue wifi is
 * hundreds of megabytes, and the bandwidth is shared with everyone else in the
 * building. 1280px at 75% quality is plenty for identifying a robot.
 */
export async function compressImage(
  file: File,
  maxDimension = 1280,
  quality = 0.75,
): Promise<Blob> {
  if (!file.type.startsWith("image/")) return file;

  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(file);
  } catch {
    return file; // Unsupported format: upload as-is rather than losing the photo.
  }

  const scale = Math.min(1, maxDimension / Math.max(bitmap.width, bitmap.height));
  const width = Math.round(bitmap.width * scale);
  const height = Math.round(bitmap.height * scale);

  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;

  const context = canvas.getContext("2d");
  if (!context) return file;
  context.drawImage(bitmap, 0, 0, width, height);
  bitmap.close();

  const blob = await new Promise<Blob | null>((resolve) =>
    canvas.toBlob(resolve, "image/jpeg", quality),
  );

  return blob ?? file;
}
EOF

say "Client: pit landing grid"
cat > src/routes/pit/index.tsx <<'EOF'
import { useQuery } from "convex/react";
import { useMemo, useState } from "react";
import { useNavigate } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";

type Filter = "all" | "todo" | "done";

const FILTERS: ReadonlyArray<{ value: Filter; label: string }> = [
  { value: "todo", label: "Not scouted" },
  { value: "done", label: "Scouted" },
  { value: "all", label: "All" },
];

export default function PitLandingPage() {
  const teams = useQuery(api.teams.listWithStatus);
  const navigate = useNavigate();
  const [filter, setFilter] = useState<Filter>("todo");
  const [search, setSearch] = useState("");

  const shown = useMemo(() => {
    if (!teams) return [];
    const needle = search.trim().toLowerCase();
    return teams.filter((team) => {
      if (filter === "todo" && team.pitScouted) return false;
      if (filter === "done" && !team.pitScouted) return false;
      if (needle === "") return true;
      return (
        String(team.number).includes(needle) ||
        team.nickname.toLowerCase().includes(needle)
      );
    });
  }, [teams, filter, search]);

  const done = teams?.filter((t) => t.pitScouted).length ?? 0;
  const total = teams?.length ?? 0;

  return (
    <PageShell
      title="Pit Scouting"
      description={
        total === 0
          ? "No teams yet. An admin needs to import an event."
          : `${done} of ${total} teams scouted. Tap a team to scout it.`
      }
    >
      <div className="flex flex-wrap items-center gap-2">
        {FILTERS.map((f) => (
          <Button
            key={f.value}
            size="sm"
            variant={filter === f.value ? "default" : "outline"}
            onClick={() => setFilter(f.value)}
          >
            {f.label}
          </Button>
        ))}
        <Input
          className="ml-auto max-w-48"
          placeholder="Find a team"
          inputMode="numeric"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
      </div>

      {teams === undefined ? (
        <p className="text-muted-foreground text-sm">Loading…</p>
      ) : shown.length === 0 ? (
        <p className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
          {filter === "todo" && total > 0
            ? "Every team has been scouted."
            : "Nothing matches."}
        </p>
      ) : (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
          {shown.map((team) => (
            <button
              key={team._id}
              onClick={() => void navigate(`/pit/${team.number}`)}
              className={[
                "flex min-h-24 flex-col justify-between rounded-lg border p-3 text-left transition-colors",
                team.pitScouted
                  ? "bg-primary/5 border-primary/40"
                  : "hover:bg-accent/50",
              ].join(" ")}
            >
              <span className="text-2xl font-semibold tabular-nums">
                {team.number}
              </span>
              <span className="text-muted-foreground truncate text-xs">
                {team.nickname}
              </span>
              <Badge
                variant={team.pitScouted ? "default" : "outline"}
                className="mt-1 w-fit"
              >
                {team.pitScouted ? "Scouted" : "Not scouted"}
              </Badge>
            </button>
          ))}
        </div>
      )}
    </PageShell>
  );
}
EOF

say "Client: pit form"
cat > src/routes/pit/form.tsx <<'EOF'
import { useMutation, useQuery } from "convex/react";
import { ArrowLeft, Camera, LoaderCircle } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { compressImage } from "@/lib/compress-image";
import { CapabilityCheck } from "@/components/scouting/capability-check";
import { PageShell } from "@/routes/page-shell";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardHeader, CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";

const DRIVETRAINS = ["Swerve", "Tank / WCD", "Mecanum", "Other"] as const;

type FormState = {
  turret: boolean;
  drumNonFullWidth: boolean;
  drumFullWidth: boolean;
  fixed: boolean;
  kitbot: boolean;
  other: boolean;
  otherText: string;
  low: boolean;
  mid: boolean;
  high: boolean;
  duringAuto: boolean;
  drivetrain: string;
  underTrench: boolean;
  overBump: boolean;
  robotNotes: string;
  otherNotes: string;
};

const BLANK: FormState = {
  turret: false, drumNonFullWidth: false, drumFullWidth: false, fixed: false,
  kitbot: false, other: false, otherText: "",
  low: false, mid: false, high: false, duringAuto: false,
  drivetrain: "", underTrench: false, overBump: false,
  robotNotes: "", otherNotes: "",
};

export default function PitFormPage() {
  const params = useParams();
  const navigate = useNavigate();
  const teamNumber = Number.parseInt(params.teamNumber ?? "", 10);

  const data = useQuery(
    api.pit.forTeamNumber,
    Number.isNaN(teamNumber) ? "skip" : { teamNumber },
  );
  const upsert = useMutation(api.pit.upsert);
  const generateUploadUrl = useMutation(api.pit.generateUploadUrl);

  const [form, setForm] = useState<FormState>(BLANK);
  const [loaded, setLoaded] = useState(false);
  const [photoPreview, setPhotoPreview] = useState<string | null>(null);
  const [photoFile, setPhotoFile] = useState<File | null>(null);
  const [saving, setSaving] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);

  // Hydrate once. Re-hydrating on every query update would stamp on edits in
  // progress each time another scout writes to the same event.
  useEffect(() => {
    if (loaded || data === undefined || data === null) return;
    const report = data.report;
    if (report) {
      setForm({
        ...report.scoring,
        ...report.climb,
        drivetrain: report.drivetrain,
        underTrench: report.underTrench,
        overBump: report.overBump,
        robotNotes: report.robotNotes,
        otherNotes: report.otherNotes,
      });
    }
    setLoaded(true);
  }, [data, loaded]);

  const set = <K extends keyof FormState>(key: K, value: FormState[K]) =>
    setForm((f) => ({ ...f, [key]: value }));

  const pickPhoto = async (file: File | undefined) => {
    if (!file) return;
    const compressed = await compressImage(file);
    setPhotoFile(new File([compressed], "robot.jpg", { type: "image/jpeg" }));
    setPhotoPreview(URL.createObjectURL(compressed));
  };

  const save = async () => {
    if (!data) return;
    setSaving(true);
    try {
      let photoId: Id<"_storage"> | null = null;
      if (photoFile) {
        const url = await generateUploadUrl({});
        const response = await fetch(url, {
          method: "POST",
          headers: { "Content-Type": photoFile.type },
          body: photoFile,
        });
        if (!response.ok) throw new Error("Photo upload failed.");
        const body = (await response.json()) as { storageId: Id<"_storage"> };
        photoId = body.storageId;
      }

      await upsert({
        teamId: data.team._id,
        scoring: {
          turret: form.turret,
          drumNonFullWidth: form.drumNonFullWidth,
          drumFullWidth: form.drumFullWidth,
          fixed: form.fixed,
          kitbot: form.kitbot,
          other: form.other,
          otherText: form.other ? form.otherText : "",
        },
        climb: {
          low: form.low, mid: form.mid, high: form.high,
          duringAuto: form.duringAuto,
        },
        drivetrain: form.drivetrain,
        underTrench: form.underTrench,
        overBump: form.overBump,
        robotNotes: form.robotNotes,
        otherNotes: form.otherNotes,
        photoId,
      });

      toast.success(`Saved team ${data.team.number}`);
      void navigate("/pit");
    } catch (error) {
      toast.error("Could not save", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setSaving(false);
    }
  };

  if (Number.isNaN(teamNumber)) {
    return <PageShell title="Pit Scouting" description="That is not a team number." />;
  }
  if (data === undefined) {
    return <PageShell title="Pit Scouting" description="Loading…" />;
  }
  if (data === null) {
    return (
      <PageShell
        title="Pit Scouting"
        description={`Team ${teamNumber} is not at the active event.`}
      >
        <Button variant="outline" onClick={() => void navigate("/pit")}>
          <ArrowLeft className="size-4" />
          Back to pit list
        </Button>
      </PageShell>
    );
  }

  const existingPhoto = photoPreview ?? data.photoUrl;

  return (
    <PageShell
      title={`${data.team.number} · ${data.team.nickname}`}
      description={
        data.report
          ? "Already scouted. Saving updates the existing report."
          : "Not yet scouted."
      }
      actions={
        <Button variant="outline" onClick={() => void navigate("/pit")}>
          <ArrowLeft className="size-4" />
          Back
        </Button>
      }
    >
      <Card>
        <CardHeader><CardTitle>Scoring capability</CardTitle></CardHeader>
        <CardContent className="space-y-2">
          <CapabilityCheck id="turret" label="Turret"
            checked={form.turret} onChange={(v) => set("turret", v)} />
          <CapabilityCheck id="drum-narrow" label="Drum shooter (not full width)"
            checked={form.drumNonFullWidth} onChange={(v) => set("drumNonFullWidth", v)} />
          <CapabilityCheck id="drum-wide" label="Drum shooter (full width)"
            checked={form.drumFullWidth} onChange={(v) => set("drumFullWidth", v)} />
          <CapabilityCheck id="fixed" label="Fixed shooter"
            checked={form.fixed} onChange={(v) => set("fixed", v)} />
          <CapabilityCheck id="kitbot" label="Kitbot / Everybot"
            checked={form.kitbot} onChange={(v) => set("kitbot", v)} />
          <CapabilityCheck id="other" label="Other"
            checked={form.other} onChange={(v) => set("other", v)} />
          {form.other ? (
            <Input
              placeholder="Describe the scoring mechanism"
              value={form.otherText}
              onChange={(e) => set("otherText", e.target.value)}
            />
          ) : null}
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle>Climb capability</CardTitle></CardHeader>
        <CardContent className="space-y-2">
          <CapabilityCheck id="climb-low" label="Low climb (L1)"
            checked={form.low} onChange={(v) => set("low", v)} />
          <CapabilityCheck id="climb-mid" label="Middle climb (L2)"
            checked={form.mid} onChange={(v) => set("mid", v)} />
          <CapabilityCheck id="climb-high" label="High climb (L3)"
            checked={form.high} onChange={(v) => set("high", v)} />
          <CapabilityCheck id="climb-auto" label="Can climb during auto"
            description="Rules permit L1 only in auto."
            checked={form.duringAuto} onChange={(v) => set("duringAuto", v)} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle>Mobility</CardTitle></CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label>Drivetrain</Label>
            <div className="grid grid-cols-2 gap-2">
              {DRIVETRAINS.map((option) => (
                <Button
                  key={option}
                  variant={form.drivetrain === option ? "default" : "outline"}
                  className="h-12"
                  onClick={() => set("drivetrain", option)}
                >
                  {option}
                </Button>
              ))}
            </div>
            {form.drivetrain === "Other" ? (
              <Input
                placeholder="Drivetrain type"
                onChange={(e) => set("drivetrain", e.target.value)}
              />
            ) : null}
          </div>

          <CapabilityCheck id="trench" label="Fits under the trench"
            description="40.25in clearance."
            checked={form.underTrench} onChange={(v) => set("underTrench", v)} />
          <CapabilityCheck id="bump" label="Can cross the bump"
            description="6.5in tall."
            checked={form.overBump} onChange={(v) => set("overBump", v)} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle>Robot photo</CardTitle></CardHeader>
        <CardContent className="space-y-3">
          {existingPhoto ? (
            <img
              src={existingPhoto}
              alt={`Team ${data.team.number} robot`}
              className="max-h-64 w-full rounded-lg object-contain"
            />
          ) : null}
          <input
            ref={fileInput}
            type="file"
            accept="image/*"
            capture="environment"
            className="hidden"
            onChange={(e) => void pickPhoto(e.target.files?.[0])}
          />
          <Button variant="outline" className="h-12 w-full"
            onClick={() => fileInput.current?.click()}>
            <Camera className="size-4" />
            {existingPhoto ? "Replace photo" : "Take photo"}
          </Button>
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle>Notes</CardTitle></CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="robot-notes">Robot notes</Label>
            <Textarea id="robot-notes" rows={3} value={form.robotNotes}
              onChange={(e) => set("robotNotes", e.target.value)} />
          </div>
          <div className="space-y-2">
            <Label htmlFor="other-notes">Anything else</Label>
            <Textarea id="other-notes" rows={3} value={form.otherNotes}
              onChange={(e) => set("otherNotes", e.target.value)} />
          </div>
        </CardContent>
      </Card>

      <Button className="h-14 w-full text-base" disabled={saving}
        onClick={() => void save()}>
        {saving ? <LoaderCircle className="size-4 animate-spin" /> : null}
        {data.report ? "Update report" : "Submit report"}
      </Button>
    </PageShell>
  );
}
EOF

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Track B written. Open /pit and scout a robot.

DONE
