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
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Checkbox } from "@/components/ui/checkbox";
import { SPARE_PARTS, type Spare, type SparePart } from "@/lib/spares";

const DRIVETRAINS = ["Swerve", "Tank / WCD", "Mecanum", "Other"] as const;

type HopperRoof = "solid" | "expanding" | "net" | "none";

const HOPPER_ROOFS: ReadonlyArray<{ value: HopperRoof; label: string }> = [
  { value: "solid", label: "Solid" },
  { value: "expanding", label: "Expanding solid" },
  { value: "net", label: "Net" },
  { value: "none", label: "No roof" },
];

const roofExpands = (roof: HopperRoof | "") => roof === "expanding" || roof === "net";
/** Digits only, three at most: a phone keyboard can still slip in a "." or "-". */
const digitsOnly = (text: string) => text.replace(/\D/g, "").slice(0, 3);
const toCount = (text: string) => (text === "" ? null : Number.parseInt(text, 10));

type FormState = {
  turret: boolean;
  drumNonFullWidth: boolean;
  drumFullWidth: boolean;
  fixed: boolean;
  kitbot: boolean;
  other: boolean;
  otherText: string;
  hopperRoof: HopperRoof | "";
  hopperCapacity: string;
  hopperExpanded: string;
  low: boolean;
  mid: boolean;
  high: boolean;
  duringAuto: boolean;
  drivetrainBase: string;
  drivetrainDetail: string;
  underTrench: boolean;
  overBump: boolean;
  robotNotes: string;
  otherNotes: string;
  spares: Record<SparePart, SpareRow>;
};

type SpareRow = { on: boolean; quantity: string; specify: string };

const BLANK_SPARES = Object.fromEntries(
  SPARE_PARTS.map(({ part }) => [part, { on: false, quantity: "", specify: "" }]),
) as Record<SparePart, SpareRow>;

/** Digits only, no leading zeros: the box can only ever hold a positive whole number. */
const positiveDigits = (text: string) => text.replace(/\D/g, "").replace(/^0+/, "").slice(0, 3);

/** What a ticked spare is missing, or null when it is complete or unticked. */
function spareProblem(row: SpareRow): string | null {
  if (!row.on) return null;
  const missing: string[] = [];
  if (row.quantity === "") missing.push("how many");
  if (row.specify.trim() === "") missing.push("what exactly");
  return missing.length > 0 ? `Say ${missing.join(" and ")}.` : null;
}

function sparesFromReport(spares: Spare[] | undefined): Record<SparePart, SpareRow> {
  const rows = { ...BLANK_SPARES };
  for (const s of spares ?? []) {
    rows[s.part] = { on: true, quantity: String(s.quantity), specify: s.specify };
  }
  return rows;
}

const BLANK: FormState = {
  turret: false, drumNonFullWidth: false, drumFullWidth: false, fixed: false,
  kitbot: false, other: false, otherText: "",
  hopperRoof: "", hopperCapacity: "", hopperExpanded: "",
  low: false, mid: false, high: false, duringAuto: false,
  drivetrainBase: "", drivetrainDetail: "", underTrench: false, overBump: false,
  robotNotes: "", otherNotes: "",
  spares: BLANK_SPARES,
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
  // Problems show once someone tries to save, not while they are still typing.
  const [showSpareErrors, setShowSpareErrors] = useState(false);
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
        drivetrainBase: report.drivetrain.split(" — ")[0] ?? "",
        drivetrainDetail: report.drivetrain.split(" — ").slice(1).join(" — "),
        underTrench: report.underTrench,
        overBump: report.overBump,
        robotNotes: report.robotNotes,
        otherNotes: report.otherNotes,
        hopperRoof: report.hopper?.roof ?? "",
        hopperCapacity: report.hopper?.capacity?.toString() ?? "",
        hopperExpanded: report.hopper?.expandedCapacity?.toString() ?? "",
        spares: sparesFromReport(report.spares),
      });
    }
    setLoaded(true);
  }, [data, loaded]);

  const set = <K extends keyof FormState>(key: K, value: FormState[K]) =>
    setForm((f) => ({ ...f, [key]: value }));

  const setSpare = (part: SparePart, patch: Partial<SpareRow>) =>
    setForm((f) => ({ ...f, spares: { ...f.spares, [part]: { ...f.spares[part], ...patch } } }));

  const pickPhoto = async (file: File | undefined) => {
    if (!file) return;
    const compressed = await compressImage(file);
    setPhotoFile(new File([compressed], "robot.jpg", { type: "image/jpeg" }));
    setPhotoPreview(URL.createObjectURL(compressed));
  };

  const save = async () => {
    if (!data) return;
    if (SPARE_PARTS.some(({ part }) => spareProblem(form.spares[part]) !== null)) {
      setShowSpareErrors(true);
      toast.error("Fill in the ticked spares", {
        description: "Each ticked part needs how many and what exactly.",
      });
      return;
    }
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
        drivetrain: form.drivetrainDetail.trim()
          ? `${form.drivetrainBase} — ${form.drivetrainDetail.trim()}`
          : form.drivetrainBase,
        underTrench: form.underTrench,
        overBump: form.overBump,
        robotNotes: form.robotNotes,
        otherNotes: form.otherNotes,
        spares: SPARE_PARTS
          .filter(({ part }) => form.spares[part].on)
          .map(({ part }) => ({
            part,
            quantity: Number.parseInt(form.spares[part].quantity, 10),
            specify: form.spares[part].specify.trim(),
          })),
        photoId,
        hopper: {
          roof: form.hopperRoof === "" ? null : form.hopperRoof,
          capacity: toCount(form.hopperCapacity),
          expandedCapacity: roofExpands(form.hopperRoof)
            ? toCount(form.hopperExpanded)
            : null,
        },
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

          <div className="space-y-4 border-t pt-4">
            <h3 className="font-medium">Hopper capacity</h3>
            <div className="space-y-2">
              <Label>Roof type</Label>
              <div className="grid grid-cols-2 gap-2">
                {HOPPER_ROOFS.map((option) => (
                  <Button
                    key={option.value}
                    variant={form.hopperRoof === option.value ? "default" : "outline"}
                    className="h-12"
                    onClick={() => set("hopperRoof", option.value)}
                  >
                    {option.label}
                  </Button>
                ))}
              </div>
            </div>
            <div className="space-y-2">
              <Label htmlFor="hopper-capacity">Max capacity (not expanded)</Label>
              <Input
                id="hopper-capacity"
                inputMode="numeric"
                pattern="[0-9]*"
                placeholder="Fuel"
                value={form.hopperCapacity}
                onChange={(e) => set("hopperCapacity", digitsOnly(e.target.value))}
              />
            </div>
            {roofExpands(form.hopperRoof) ? (
              <div className="space-y-2">
                <Label htmlFor="hopper-expanded">Max capacity (expanded)</Label>
                <Input
                  id="hopper-expanded"
                  inputMode="numeric"
                  pattern="[0-9]*"
                  placeholder="Fuel"
                  value={form.hopperExpanded}
                  onChange={(e) => set("hopperExpanded", digitsOnly(e.target.value))}
                />
              </div>
            ) : null}
          </div>
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
                  variant={form.drivetrainBase === option ? "default" : "outline"}
                  className="h-12"
                  onClick={() => set("drivetrainBase", option)}
                >
                  {option}
                </Button>
              ))}
            </div>
            {form.drivetrainBase === "Swerve" ? (
              <Input
                placeholder="Which swerve? e.g. MK4i, MK4n, SwerveX"
                value={form.drivetrainDetail}
                onChange={(e) => set("drivetrainDetail", e.target.value)}
              />
            ) : null}
            {form.drivetrainBase === "Other" ? (
              <Input
                placeholder="Describe the drivetrain"
                value={form.drivetrainDetail}
                onChange={(e) => set("drivetrainDetail", e.target.value)}
              />
            ) : null}
          </div>

            <CapabilityCheck id="trench" label="Fits under the trench"
            description="22in clearance."
            checked={form.underTrench} onChange={(v) => set("underTrench", v)} />
          <CapabilityCheck id="bump" label="Can cross the bump"
            checked={form.overBump} onChange={(v) => set("overBump", v)} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Spares</CardTitle>
          <CardDescription>
            Spare parts the team has in the pit. Tick a part, then say how many
            and what exactly.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {SPARE_PARTS.map(({ part, label }) => {
            const row = form.spares[part];
            const problem = showSpareErrors ? spareProblem(row) : null;
            return (
              <div key={part}
                className={[
                  "grid grid-cols-[4.5rem_minmax(0,1fr)] gap-2 rounded-lg border p-3",
                  "sm:grid-cols-[minmax(0,1.3fr)_4.5rem_minmax(0,2fr)] sm:items-center",
                  problem ? "border-destructive" : "",
                ].join(" ")}>
                <label htmlFor={`spare-${part}`}
                  className="col-span-2 flex min-h-8 cursor-pointer items-center gap-3 sm:col-span-1">
                  <Checkbox id={`spare-${part}`} checked={row.on}
                    onCheckedChange={(next: boolean) =>
                      setSpare(part, next
                        ? { on: true }
                        : { on: false, quantity: "", specify: "" })} />
                  <span className="text-base">{label}</span>
                </label>
                <Input aria-label={`${label} quantity`} inputMode="numeric" pattern="[0-9]*"
                  placeholder="Qty" disabled={!row.on} value={row.quantity}
                  aria-invalid={problem !== null && row.quantity === ""}
                  onChange={(e) => setSpare(part, { quantity: positiveDigits(e.target.value) })} />
                <Input aria-label={`${label} specifics`} placeholder="Specify"
                  disabled={!row.on} value={row.specify}
                  aria-invalid={problem !== null && row.specify.trim() === ""}
                  onChange={(e) => setSpare(part, { specify: e.target.value })} />
                {problem ? (
                  <p className="text-destructive col-span-2 text-xs sm:col-span-3">{problem}</p>
                ) : null}
              </div>
            );
          })}
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
