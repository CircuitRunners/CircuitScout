import { useMutation, useQuery } from "convex/react";
import { ArrowLeft, Camera, Plus, X } from "lucide-react";
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
import { MenuSelect } from "@/components/menu-select";
import {
  BATTERY_TYPES, SPARE_PARTS,
  type Battery, type BatteryType, type Spare, type SparePart,
} from "@/lib/spares";
import { LoadingWheel } from "@/components/loading-wheel";

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
  batteries: BatteryRow[];
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
  return row.specify.trim() === "" ? "Say what exactly." : null;
}

type BatteryRow = {
  /** Stable React key; never saved. */
  key: number;
  type: BatteryType | "";
  otherType: string;
  quantity: string;
  condition: string;
};

let nextBatteryKey = 1;
const blankBattery = (): BatteryRow =>
  ({ key: nextBatteryKey++, type: "", otherType: "", quantity: "", condition: "" });

/** A row added by mistake and never touched is dropped on save, not an error. */
const batteryEmpty = (row: BatteryRow) =>
  row.type === "" && row.quantity === "" && row.condition.trim() === "";

/** What a battery row is missing, or null when it is complete or empty. */
function batteryProblem(row: BatteryRow): string | null {
  if (batteryEmpty(row)) return null;
  const missing: string[] = [];
  if (row.type === "") missing.push("pick a type");
  if (row.type === "other" && row.otherType.trim() === "") missing.push("say which brand");
  if (row.quantity === "") missing.push("say how many");
  if (missing.length === 0) return null;
  const text = missing.join(" and ");
  return `${text[0]!.toUpperCase()}${text.slice(1)}.`;
}

function batteriesFromReport(batteries: Battery[] | undefined): BatteryRow[] {
  return (batteries ?? []).map((b) => ({
    key: nextBatteryKey++,
    type: b.type,
    otherType: b.otherType ?? "",
    quantity: b.quantity === undefined ? "" : String(b.quantity),
    condition: b.condition,
  }));
}

function sparesFromReport(spares: Spare[] | undefined): Record<SparePart, SpareRow> {
  const rows = { ...BLANK_SPARES };
  for (const s of spares ?? []) {
    rows[s.part] = {
      on: true,
      quantity: s.quantity === undefined ? "" : String(s.quantity),
      specify: s.specify,
    };
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
  batteries: [],
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
  const [showErrors, setShowErrors] = useState(false);
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
        batteries: batteriesFromReport(report.batteries),
      });
    }
    setLoaded(true);
  }, [data, loaded]);

  const set = <K extends keyof FormState>(key: K, value: FormState[K]) =>
    setForm((f) => ({ ...f, [key]: value }));

  const setSpare = (part: SparePart, patch: Partial<SpareRow>) =>
    setForm((f) => ({ ...f, spares: { ...f.spares, [part]: { ...f.spares[part], ...patch } } }));

  const setBattery = (key: number, patch: Partial<BatteryRow>) =>
    setForm((f) => ({
      ...f,
      batteries: f.batteries.map((b) => (b.key === key ? { ...b, ...patch } : b)),
    }));

  const pickPhoto = async (file: File | undefined) => {
    if (!file) return;
    const compressed = await compressImage(file);
    setPhotoFile(new File([compressed], "robot.jpg", { type: "image/jpeg" }));
    setPhotoPreview(URL.createObjectURL(compressed));
  };

  const save = async () => {
    if (!data) return;
    const badSpares = SPARE_PARTS.some(({ part }) => spareProblem(form.spares[part]) !== null);
    const badBatteries = form.batteries.some((b) => batteryProblem(b) !== null);
    if (badSpares || badBatteries) {
      setShowErrors(true);
      toast.error(
        badSpares && badBatteries ? "Fill in the spares and batteries"
          : badSpares ? "Fill in the ticked spares" : "Fill in the batteries",
        { description: "The rows that need something are outlined in red." },
      );
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
          .map(({ part }) => {
            const row = form.spares[part];
            return {
              part,
              ...(row.quantity === "" ? {} : { quantity: Number.parseInt(row.quantity, 10) }),
              specify: row.specify.trim(),
            };
          }),
        batteries: form.batteries
          .filter((b) => !batteryEmpty(b))
          .map((b) => ({
            type: b.type as BatteryType,
            ...(b.type === "other" ? { otherType: b.otherType.trim() } : {}),
            ...(b.quantity === "" ? {} : { quantity: Number.parseInt(b.quantity, 10) }),
            condition: b.condition.trim(),
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
            Spare parts the team has in the pit. Tick a part and say what
            exactly; Est. Qty is a rough count and can be left blank.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {SPARE_PARTS.map(({ part, label }) => {
            const row = form.spares[part];
            const problem = showErrors ? spareProblem(row) : null;
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
                <Input aria-label={`${label} estimated quantity`} inputMode="numeric" pattern="[0-9]*"
                  placeholder="Est. Qty" disabled={!row.on} value={row.quantity}
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
        <CardHeader>
          <CardTitle>Batteries</CardTitle>
          <CardDescription>
            One row per kind of battery the team brought. Type and Qty are required.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {form.batteries.map((row, i) => {
            const n = i + 1;
            const problem = showErrors ? batteryProblem(row) : null;
            return (
              <div key={row.key}
                className={[
                  "grid grid-cols-[4.5rem_minmax(0,1fr)_2rem] gap-2 rounded-lg border p-3",
                  "sm:grid-cols-[minmax(0,1.3fr)_4.5rem_minmax(0,2fr)_2rem] sm:items-start",
                  problem ? "border-destructive" : "",
                ].join(" ")}>
                <div className="col-span-3 grid gap-2 sm:col-span-1">
                  {/* A themed menu, not the browser's own select, which ignores the
                      app's theme; [color-scheme:dark] only half fixed it. */}
                  <MenuSelect label={`Battery ${n} type`} value={row.type} placeholder="Type"
                    options={BATTERY_TYPES.map((b) => ({ value: b.type, label: b.label }))}
                    invalid={problem !== null && row.type === ""}
                    className="h-8 w-full"
                    onChange={(type) =>
                      setBattery(row.key, { type, otherType: type === "other" ? row.otherType : "" })} />
                  {row.type === "other" ? (
                    <Input aria-label={`Battery ${n} brand`} placeholder="Which brand?"
                      value={row.otherType} maxLength={50}
                      aria-invalid={problem !== null && row.otherType.trim() === ""}
                      onChange={(e) => setBattery(row.key, { otherType: e.target.value })} />
                  ) : null}
                </div>
                <Input aria-label={`Battery ${n} quantity`} inputMode="numeric" pattern="[0-9]*"
                  placeholder="Qty" value={row.quantity}
                  aria-invalid={problem !== null && row.quantity === ""}
                  onChange={(e) => setBattery(row.key, { quantity: positiveDigits(e.target.value) })} />
                <Input aria-label={`Battery ${n} condition`} placeholder="Condition"
                  value={row.condition} maxLength={200}
                  onChange={(e) => setBattery(row.key, { condition: e.target.value })} />
                <Button size="icon" variant="ghost" className="size-8"
                  aria-label={`Remove battery ${n}`}
                  onClick={() => setForm((f) => ({
                    ...f, batteries: f.batteries.filter((b) => b.key !== row.key),
                  }))}>
                  <X className="size-4" />
                </Button>
                {problem ? (
                  <p className="text-destructive col-span-3 text-xs sm:col-span-4">{problem}</p>
                ) : null}
              </div>
            );
          })}
          <button type="button"
            onClick={() => setForm((f) => ({ ...f, batteries: [...f.batteries, blankBattery()] }))}
            className="text-muted-foreground hover:bg-accent/50 hover:text-foreground flex min-h-12 w-full items-center gap-2 rounded-lg border border-dashed p-3 text-left text-base transition-colors">
            <Plus className="size-4" /> Add battery type
          </button>
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
        {saving ? <LoadingWheel className="size-4" /> : null}
        {data.report ? "Update report" : "Submit report"}
      </Button>
    </PageShell>
  );
}
