import { useMutation } from "convex/react";
import { ArrowLeft, Camera, Plus, X } from "lucide-react";
import type { ReactNode } from "react";
import { useRef, useState } from "react";
import type { FunctionReturnType } from "convex/server";
import { Link, useNavigate, useParams } from "react-router";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { genericPitIsBlank, genericPitMissing } from "../../../convex/lib/genericPit";
import { compressImage } from "@/lib/compress-image";
import { BATTERY_TYPES, MAX_OTHER_SPARES, type BatteryType } from "@/lib/spares";
import { PageShell } from "@/routes/page-shell";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { MenuSelect } from "@/components/menu-select";
import { LoadingWheel } from "@/components/loading-wheel";
import { HeldNotice } from "@/components/held-notice";
import { NeedsConnection } from "@/components/needs-connection";
import { useNotePitFormData } from "@/lib/offline/forms";
import { HeldFormNotice } from "@/components/held";
import { forgetHeld, heldValues, holdSubmission } from "@/lib/offline/held";
import { useOnline } from "@/lib/offline/status";

/**
 * Pit scouting for a season without its own forms: the parts of the 2026
 * form that do not depend on the game. Scoring is described in words.
 */

const DRIVETRAINS = ["Swerve", "Tank / WCD", "Mecanum", "Other"] as const;

/** Digits only, no leading zeros. */
const positiveDigits = (t: string) => t.replace(/\D/g, "").replace(/^0+/, "").slice(0, 3);

/** Pounds: three digits and one decimal place at most. */
function weightDigits(t: string): string {
  const match = /^(\d{0,3})(\.\d?)?/.exec(t.replace(/[^\d.]/g, ""));
  return match ? `${match[1] ?? ""}${match[2] ?? ""}` : "";
}
function weightProblem(t: string): string | null {
  if (t === "") return null;
  const pounds = Number.parseFloat(t);
  return pounds >= 10 && pounds <= 200 ? null : "Enter a weight between 10 and 200 lbs.";
}

type SpareRow = { on: boolean; quantity: string; specify: string };
type OtherRow = { key: number; quantity: string; specify: string };
type BatteryRow = { key: number; type: BatteryType | ""; otherType: string; quantity: string };

let nextKey = 1;
const blankOther = (): OtherRow => ({ key: nextKey++, quantity: "", specify: "" });
const blankBattery = (): BatteryRow => ({ key: nextKey++, type: "", otherType: "", quantity: "" });
const otherEmpty = (r: OtherRow) => r.quantity === "" && r.specify.trim() === "";
const batteryEmpty = (r: BatteryRow) => r.type === "" && r.quantity === "";

function batteryProblem(r: BatteryRow): string | null {
  if (batteryEmpty(r)) return null;
  const missing: string[] = [];
  if (r.type === "") missing.push("pick a type");
  if (r.type === "other" && r.otherType.trim() === "") missing.push("say which brand");
  if (r.quantity === "") missing.push("say how many are in good condition");
  if (missing.length === 0) return null;
  const t = missing.join(" and ");
  return `${t[0]!.toUpperCase()}${t.slice(1)}.`;
}

type FormState = {
  scoringText: string;
  drivetrainBase: string;
  drivetrainDetail: string;
  drivetrainGearing: string;
  robotWeight: string;
  swerve: SpareRow;
  others: OtherRow[];
  batteries: BatteryRow[];
  notes: string;
  otherNotes: string;
};

const BLANK: FormState = {
  scoringText: "", drivetrainBase: "", drivetrainDetail: "", drivetrainGearing: "", robotWeight: "",
  swerve: { on: false, quantity: "", specify: "" }, others: [], batteries: [],
  notes: "", otherNotes: "",
};

/** The report as the server takes it, minus the team and photo. */
function reportFromForm(f: FormState) {
  return {
    scoringText: f.scoringText.trim(),
    drivetrain: f.drivetrainDetail.trim() ? `${f.drivetrainBase} — ${f.drivetrainDetail.trim()}` : f.drivetrainBase,
    drivetrainGearing: f.drivetrainGearing.trim(),
    robotWeight: f.robotWeight === "" ? null : Math.round(Number.parseFloat(f.robotWeight) * 10) / 10,
    spares: [
      ...(f.swerve.on
        ? [{
            part: "swerve" as const,
            ...(f.swerve.quantity === "" ? {} : { quantity: Number.parseInt(f.swerve.quantity, 10) }),
            specify: f.swerve.specify.trim(),
          }]
        : []),
      ...f.others.filter((o) => !otherEmpty(o)).map((o) => ({
        part: "other" as const,
        ...(o.quantity === "" ? {} : { quantity: Number.parseInt(o.quantity, 10) }),
        specify: o.specify.trim(),
      })),
    ],
    batteries: f.batteries.filter((b) => !batteryEmpty(b)).map((b) => ({
      type: b.type as BatteryType,
      ...(b.type === "other" ? { otherType: b.otherType.trim() } : {}),
      ...(b.quantity === "" ? {} : { quantity: Number.parseInt(b.quantity, 10) }),
    })),
    notes: f.notes,
    otherNotes: f.otherNotes,
  };
}

type PitData = NonNullable<FunctionReturnType<typeof api.notes.pitNote>>;

/** The saved report as form state, read once when the form mounts. */
function formFromSaved(data: PitData): FormState {
  const n = data.note;
  if (!n) return BLANK;
  const swerve = n.spares.find((s) => s.part === "swerve");
  return {
    scoringText: n.scoringText,
    drivetrainBase: n.drivetrain.split(" — ")[0] ?? "",
    drivetrainDetail: n.drivetrain.split(" — ").slice(1).join(" — "),
    drivetrainGearing: n.drivetrainGearing,
    robotWeight: n.robotWeight === null ? "" : String(n.robotWeight),
    swerve: swerve
      ? { on: true, quantity: swerve.quantity === undefined ? "" : String(swerve.quantity), specify: swerve.specify }
      : BLANK.swerve,
    others: n.spares.filter((s) => s.part === "other").map((s) => ({
      key: nextKey++, quantity: s.quantity === undefined ? "" : String(s.quantity), specify: s.specify,
    })),
    batteries: n.batteries.map((b) => ({
      key: nextKey++, type: b.type, otherType: b.otherType ?? "",
      quantity: b.quantity === undefined ? "" : String(b.quantity),
    })),
    notes: n.notes,
    otherNotes: n.otherNotes,
  };
}

export default function NotesPitFormPage() {
  const params = useParams();
  const teamNumber = Number.parseInt(params.teamNumber ?? "", 10);
  // Online this is notes.pitNote, unchanged. Offline: the saved copy, or a
  // blank form for a team the saved list says nobody has scouted.
  const { data, unavailable, blocked } = useNotePitFormData(teamNumber);

  const back = (
    <Button variant="outline" render={<Link to="/pit" />}>
      <ArrowLeft className="size-4" /> Back
    </Button>
  );
  if (Number.isNaN(teamNumber)) return <PageShell title="Pit Scouting" description="Bad URL." actions={back} />;
  if (blocked) {
    // notes.savePitReport patches the existing report: a blank form saved
    // from here would overwrite answers this device does not have.
    return (
      <PageShell title="Pit Scouting" actions={back}>
        <NeedsConnection title="Already scouted" description="This team has a pit report that is not saved on this device. Connect to edit it." />
      </PageShell>
    );
  }
  if (data === undefined && unavailable) {
    return (
      <PageShell title="Pit Scouting" actions={back}>
        <NeedsConnection title="Not saved on this device" description="Open Pit Scouting once while online, and this form will open offline." />
      </PageShell>
    );
  }
  if (data === undefined) return <PageShell title="Pit Scouting" description="Loading…" actions={back} />;
  if (data === null) {
    return <PageShell title="Pit Scouting" description="That team is not at the active event." actions={back} />;
  }
  // Keyed, so the saved report seeds the form exactly once per team. The
  // query is live: re-seeding on every update would stamp on edits.
  return <PitReportForm key={data.teamNumber} data={data} back={back} />;
}

function PitReportForm({ data, back }: { data: PitData; back: ReactNode }) {
  const navigate = useNavigate();
  const online = useOnline();
  const teamNumber = data.teamNumber;
  const save = useMutation(api.notes.savePitReport);
  const generateUploadUrl = useMutation(api.pit.generateUploadUrl);

  // Answers saved offline and not sent yet come first: they are newer than
  // anything the server or the cache has.
  const [form, setForm] = useState<FormState>(
    () => heldValues<FormState>(`note-pit:${data.teamNumber}`) ?? formFromSaved(data),
  );
  const [photoFile, setPhotoFile] = useState<File | null>(null);
  const [photoPreview, setPhotoPreview] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [showErrors, setShowErrors] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);

  const set = <K extends keyof FormState>(key: K, value: FormState[K]) =>
    setForm((f) => ({ ...f, [key]: value }));
  const setOther = (key: number, patch: Partial<OtherRow>) =>
    setForm((f) => ({ ...f, others: f.others.map((o) => (o.key === key ? { ...o, ...patch } : o)) }));
  const setBattery = (key: number, patch: Partial<BatteryRow>) =>
    setForm((f) => ({ ...f, batteries: f.batteries.map((b) => (b.key === key ? { ...b, ...patch } : b)) }));

  const draft = reportFromForm(form);
  const hasPhoto = photoFile !== null || Boolean(data.photoUrl);
  const draftBlank = genericPitIsBlank({ ...draft, photoId: hasPhoto ? "photo" : null });
  const draftMissing = genericPitMissing(draft);

  const swerveProblem = form.swerve.on && form.swerve.specify.trim() === "" ? "Say what exactly." : null;
  const otherProblem = (o: OtherRow) => (!otherEmpty(o) && o.specify.trim() === "" ? "Say what exactly." : null);

  const submit = async () => {
    if (draftBlank) {
      toast.error("Nothing filled in yet", {
        description: "A blank report would not count as scouted, so nothing was saved.",
      });
      return;
    }
    const badSpares = swerveProblem !== null || form.others.some((o) => otherProblem(o) !== null);
    const badBatteries = form.batteries.some((b) => batteryProblem(b) !== null);
    const badWeight = weightProblem(form.robotWeight) !== null;
    if (badSpares || badBatteries || badWeight) {
      setShowErrors(true);
      const sections = [
        badWeight ? "robot weight" : null, badSpares ? "spares" : null, badBatteries ? "batteries" : null,
      ].filter((s): s is string => s !== null);
      const list = sections.length > 1
        ? `${sections.slice(0, -1).join(", ")} and ${sections[sections.length - 1]}`
        : sections[0];
      toast.error(`Check the ${list}`, { description: "What needs fixing is outlined in red." });
      return;
    }
    if (!online && !photoFile) {
      // No connection: hand the report to the outbox rather than waiting
      // here. It is kept on this device and sent when the connection returns.
      const heldNow = holdSubmission({
        key: `note-pit:${teamNumber}`,
        label: `Team ${teamNumber} pit report`,
        to: `/pit/${teamNumber}`,
        values: form,
        report: { kind: "notePit", args: { teamNumber, ...draft, photoId: null } },
      });
      if (heldNow) void navigate("/pit");
      return;
    }
    setSaving(true);
    try {
      let photoId: Id<"_storage"> | null = null;
      if (photoFile) {
        const url = await generateUploadUrl({});
        const response = await fetch(url, {
          method: "POST", headers: { "Content-Type": photoFile.type }, body: photoFile,
        });
        if (!response.ok) throw new Error("Photo upload failed.");
        photoId = ((await response.json()) as { storageId: Id<"_storage"> }).storageId;
      }
      await save({ teamNumber, ...draft, photoId });
      forgetHeld(`note-pit:${teamNumber}`);
      if (draftMissing.length === 0) toast.success(`Saved team ${data.teamNumber}`);
      else toast.success(`Saved team ${data.teamNumber} as partially scouted`, {
        description: `Still needed: ${draftMissing.join(", ")}.`,
      });
      void navigate("/pit");
    } catch (error) {
      toast.error("Could not save", { description: error instanceof Error ? error.message : String(error) });
    } finally {
      setSaving(false);
    }
  };

  // A saved photo lives on the server and cannot be shown offline.
  const photo = photoPreview ?? (online ? data.photoUrl : null);
  const saved = data.note;

  return (
    <PageShell
      title={`${data.teamNumber} · ${data.nickname}`}
      description={
        saved === null || saved.status === "none"
          ? "Not yet scouted."
          : saved.status === "partial"
            ? `Partially scouted. Still needed: ${saved.missing.join(", ")}.`
            : `Already scouted, last saved by ${saved.scoutName}. Saving updates the existing report.`
      }
      actions={back}
    >
      <HeldFormNotice heldKey={`note-pit:${teamNumber}`} />
      <Card>
        <CardHeader>
          <CardTitle>Scoring capability</CardTitle>
          <CardDescription>How the robot scores, in your own words.</CardDescription>
        </CardHeader>
        <CardContent>
          <Textarea id="scoring" rows={3} aria-label="Scoring capability" maxLength={2000}
            placeholder="e.g. Turret shooter, scores from anywhere on its side; ground intake"
            value={form.scoringText} onChange={(e) => set("scoringText", e.target.value)} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle>Mobility</CardTitle></CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label>Drivetrain</Label>
            <div className="grid grid-cols-2 gap-2">
              {DRIVETRAINS.map((option) => (
                <Button key={option} className="h-12"
                  variant={form.drivetrainBase === option ? "default" : "outline"}
                  onClick={() => set("drivetrainBase", option)}>
                  {option}
                </Button>
              ))}
            </div>
            {form.drivetrainBase === "Swerve" ? (
              <Input placeholder="Which swerve? e.g. MK4i, MK4n, SwerveX"
                value={form.drivetrainDetail} onChange={(e) => set("drivetrainDetail", e.target.value)} />
            ) : null}
            {form.drivetrainBase === "Other" ? (
              <Input placeholder="Describe the drivetrain"
                value={form.drivetrainDetail} onChange={(e) => set("drivetrainDetail", e.target.value)} />
            ) : null}
          </div>
          <div className="space-y-2">
            <Label htmlFor="gearing">Drivetrain gearing</Label>
            <Input id="gearing" placeholder="e.g. L2, 6.75:1" maxLength={100}
              value={form.drivetrainGearing} onChange={(e) => set("drivetrainGearing", e.target.value)} />
          </div>
          <div className="space-y-2">
            <Label htmlFor="weight">Robot weight (with bumpers and battery)</Label>
            <div className="relative">
              <Input id="weight" inputMode="decimal" placeholder="e.g. 112.5" className="pr-10"
                value={form.robotWeight}
                aria-invalid={showErrors && weightProblem(form.robotWeight) !== null ? true : undefined}
                onChange={(e) => set("robotWeight", weightDigits(e.target.value))} />
              <span className="text-muted-foreground pointer-events-none absolute inset-y-0 right-3 flex items-center text-sm">
                lbs
              </span>
            </div>
            {showErrors && weightProblem(form.robotWeight) !== null ? (
              <p className="text-destructive text-xs">{weightProblem(form.robotWeight)}</p>
            ) : null}
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Spares</CardTitle>
          <CardDescription>
            Spare parts the team has in the pit. Say what exactly; Est. Qty is a
            rough count and can be left blank. Add an Other row for anything else.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          <div className={[
            "grid grid-cols-[4.5rem_minmax(0,1fr)] gap-2 rounded-lg border p-3",
            "sm:grid-cols-[minmax(0,1.3fr)_4.5rem_minmax(0,2fr)_2rem] sm:items-center",
            showErrors && swerveProblem ? "border-destructive" : "",
          ].join(" ")}>
            <label htmlFor="spare-swerve"
              className="col-span-2 flex min-h-8 cursor-pointer items-center gap-3 sm:col-span-1">
              <Checkbox id="spare-swerve" checked={form.swerve.on}
                onCheckedChange={(next: boolean) =>
                  set("swerve", next ? { ...form.swerve, on: true } : { on: false, quantity: "", specify: "" })} />
              <span className="text-base">Swerve modules</span>
            </label>
            <Input aria-label="Swerve modules estimated quantity" inputMode="numeric" pattern="[0-9]*"
              placeholder="Est. Qty" disabled={!form.swerve.on} value={form.swerve.quantity}
              onChange={(e) => set("swerve", { ...form.swerve, quantity: positiveDigits(e.target.value) })} />
            <Input aria-label="Swerve modules specifics" placeholder="Specify" maxLength={200}
              disabled={!form.swerve.on} value={form.swerve.specify}
              aria-invalid={showErrors && swerveProblem !== null}
              onChange={(e) => set("swerve", { ...form.swerve, specify: e.target.value })} />
            {showErrors && swerveProblem ? (
              <p className="text-destructive col-span-2 text-xs sm:col-span-4">{swerveProblem}</p>
            ) : null}
          </div>
          {form.others.map((row, i) => {
            const problem = showErrors ? otherProblem(row) : null;
            return (
              <div key={row.key} className={[
                "grid grid-cols-[4.5rem_minmax(0,1fr)_2rem] gap-2 rounded-lg border p-3",
                "sm:grid-cols-[minmax(0,1.3fr)_4.5rem_minmax(0,2fr)_2rem] sm:items-center",
                problem ? "border-destructive" : "",
              ].join(" ")}>
                <span className="col-span-3 flex min-h-8 items-center text-base sm:col-span-1">Other</span>
                <Input aria-label={`Other spare ${i + 1} estimated quantity`} inputMode="numeric" pattern="[0-9]*"
                  placeholder="Est. Qty" value={row.quantity}
                  onChange={(e) => setOther(row.key, { quantity: positiveDigits(e.target.value) })} />
                <Input aria-label={`Other spare ${i + 1} specifics`} placeholder="Specify" maxLength={200}
                  value={row.specify} aria-invalid={problem !== null}
                  onChange={(e) => setOther(row.key, { specify: e.target.value })} />
                <Button size="icon" variant="ghost" className="size-8" aria-label={`Remove other spare ${i + 1}`}
                  onClick={() => setForm((f) => ({ ...f, others: f.others.filter((o) => o.key !== row.key) }))}>
                  <X className="size-4" />
                </Button>
                {problem ? <p className="text-destructive col-span-3 text-xs sm:col-span-4">{problem}</p> : null}
              </div>
            );
          })}
          {form.others.length < MAX_OTHER_SPARES ? (
            <button type="button"
              onClick={() => setForm((f) => ({ ...f, others: [...f.others, blankOther()] }))}
              className="text-muted-foreground hover:bg-accent/50 hover:text-foreground flex min-h-12 w-full items-center gap-2 rounded-lg border border-dashed p-3 text-left text-base transition-colors">
              <Plus className="size-4" /> Add other spare
            </button>
          ) : null}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Batteries</CardTitle>
          <CardDescription>
            One row per kind of battery the team brought, with how many of them
            are in good condition. Both are required.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {form.batteries.map((row, i) => {
            const n = i + 1;
            const problem = showErrors ? batteryProblem(row) : null;
            return (
              <div key={row.key} className={[
                "grid grid-cols-[minmax(0,1fr)_2rem] items-start gap-2 rounded-lg border p-3",
                "sm:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)_2rem]",
                problem ? "border-destructive" : "",
              ].join(" ")}>
                <div className="col-span-2 grid gap-2 sm:col-span-1">
                  <MenuSelect label={`Battery ${n} type`} value={row.type} placeholder="Type"
                    options={BATTERY_TYPES.map((b) => ({ value: b.type, label: b.label }))}
                    invalid={problem !== null && row.type === ""} className="h-8 w-full"
                    onChange={(type) => setBattery(row.key, { type, otherType: type === "other" ? row.otherType : "" })} />
                  {row.type === "other" ? (
                    <Input aria-label={`Battery ${n} brand`} placeholder="Which brand?" maxLength={50}
                      value={row.otherType} aria-invalid={problem !== null && row.otherType.trim() === ""}
                      onChange={(e) => setBattery(row.key, { otherType: e.target.value })} />
                  ) : null}
                </div>
                <Input aria-label={`Battery ${n} number in good condition`} inputMode="numeric"
                  pattern="[0-9]*" placeholder="# in good condition" value={row.quantity}
                  aria-invalid={problem !== null && row.quantity === ""}
                  onChange={(e) => setBattery(row.key, { quantity: positiveDigits(e.target.value) })} />
                <Button size="icon" variant="ghost" className="size-8" aria-label={`Remove battery ${n}`}
                  onClick={() => setForm((f) => ({ ...f, batteries: f.batteries.filter((b) => b.key !== row.key) }))}>
                  <X className="size-4" />
                </Button>
                {problem ? <p className="text-destructive col-span-2 text-xs sm:col-span-3">{problem}</p> : null}
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
          {photo ? (
            <img src={photo} alt={`Team ${data.teamNumber} robot`} className="max-h-64 w-full rounded-lg object-contain" />
          ) : null}
          <input ref={fileInput} type="file" accept="image/*" capture="environment" className="hidden"
            onChange={(e) => {
              const file = e.target.files?.[0];
              if (!file) return;
              void compressImage(file).then((compressed) => {
                setPhotoFile(new File([compressed], "robot.jpg", { type: "image/jpeg" }));
                setPhotoPreview(URL.createObjectURL(compressed));
              });
            }} />
          <Button variant="outline" className="h-12 w-full" disabled={!online} onClick={() => fileInput.current?.click()}>
            <Camera className="size-4" /> {photo ? "Replace photo" : "Take photo"}
          </Button>
          {online ? null : (
            <p className="text-muted-foreground text-xs">
              Photos need a connection. Save the rest now and add the photo when you are back online.
              {data.photoUrl ? " The saved photo is not shown offline." : ""}
            </p>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle>Notes</CardTitle></CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="robot-notes">Robot notes</Label>
            <Textarea id="robot-notes" rows={3} value={form.notes} onChange={(e) => set("notes", e.target.value)} />
          </div>
          <div className="space-y-2">
            <Label htmlFor="other-notes">Anything else</Label>
            <Textarea id="other-notes" rows={3} value={form.otherNotes} onChange={(e) => set("otherNotes", e.target.value)} />
          </div>
        </CardContent>
      </Card>

      {!draftBlank && draftMissing.length > 0 ? (
        <p className="text-muted-foreground text-sm">
          Saving now marks this team <span className="text-foreground font-medium">partially scouted</span>.
          Still needed: {draftMissing.join(", ")}.
        </p>
      ) : null}
      <HeldNotice saving={saving} />
      <Button className="h-14 w-full text-base" disabled={saving} onClick={() => void submit()}>
        {saving ? <LoadingWheel className="size-4" /> : null}
        {!online ? "Save when back online" : saved && saved.status !== "none" ? "Update report" : "Submit report"}
      </Button>
    </PageShell>
  );
}
