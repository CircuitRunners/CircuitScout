import { useMutation, useQuery } from "convex/react";
import { AlertTriangle, ArrowLeft, ArrowRight, Play } from "lucide-react";
import { useEffect, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { PageShell } from "@/routes/page-shell";
import { AutoPathEditor } from "@/components/field-map/auto-path-editor";
import { PHASE_LABELS, estimatedStart, useMatchClock } from "./use-match-clock";
import { RatingScale } from "@/components/scouting/rating-scale";
import { SegmentedChoice } from "@/components/scouting/segmented-choice";
import { Stepper } from "@/components/scouting/stepper";
import { CapabilityCheck } from "@/components/scouting/capability-check";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import {
  EMPTY_BY_SHIFT, countedTeleopFuel, uncountedTeleopFuel, type ByShift,
} from "@/lib/scoring";
import type { AutoStep, ClimbLevel, StartPosition } from "@/lib/types";
import { readSteps } from "@/lib/types";
import { LoadingWheel } from "@/components/loading-wheel";
import { HeldNotice } from "@/components/held-notice";
import { NeedsConnection } from "@/components/needs-connection";
import { useMatchFormData } from "@/lib/offline/forms";
import { HeldSummary } from "@/components/held";
import { holdSubmission, useHeld } from "@/lib/offline/held";
import { summarizeMatchReport } from "@/lib/offline/held-match-summary";
import { useOnline } from "@/lib/offline/status";

const CLIMB_OPTIONS: ReadonlyArray<{ value: ClimbLevel; label: string }> = [
  { value: "none", label: "No climb" },
  { value: "low", label: "Low (L1)" },
  { value: "mid", label: "Middle (L2)" },
  { value: "high", label: "High (L3)" },
];

/**
 * Even numbers at the extremes, every integer through the middle — resolution
 * where the readings actually cluster, coarser where they rarely land.
 */
const BPS_VALUES = [
  0, 2, 4, 6, 8, 10,
  11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
  24, 26, 28, 30, 32, 34,
] as const;

export default function MatchFormPage() {
  const params = useParams();
  const navigate = useNavigate();
  const matchNumber = Number.parseInt(params.matchNumber ?? "", 10);
  const teamNumber = Number.parseInt(params.teamNumber ?? "", 10);
  const valid = !Number.isNaN(matchNumber) && !Number.isNaN(teamNumber);

  // Online this is matchReports.forMatchAndTeam, unchanged. Offline it is the
  // saved copy, or the same shape rebuilt from the saved schedule and team list.
  const { data, unavailable } = useMatchFormData(matchNumber, teamNumber, valid);
  const online = useOnline();
  const heldKey = `match:${matchNumber}:${teamNumber}`;
  const held = useHeld(heldKey);
  const submit = useMutation(api.matchReports.submit);
  const update = useMutation(api.matchReports.update);

  const [searchParams] = useSearchParams();
  const editId = searchParams.get("report");
  const editing = useQuery(
    api.admin.reportForEdit,
    editId ? { reportId: editId as Id<"matchReports"> } : "skip",
  );
  const [editReason, setEditReason] = useState("");
  const [hydrated, setHydrated] = useState(false);

  // Local state, not the UI store: every match opens on Auto rather than on
  // whichever tab the previous one was left on.
  const [period, setPeriod] = useState<"auto" | "teleop" | "conclusion">("auto");

  const [startedAt, setStartedAt] = useState<number | null>(null);
  const [estimated, setEstimated] = useState(false);
  const { phase, bucket } = useMatchClock(startedAt);

  const [start, setStart] = useState<StartPosition | null>(null);
  const [steps, setSteps] = useState<AutoStep[]>([]);
  const [autoFuel, setAutoFuel] = useState(0);
  const [autoFouls, setAutoFouls] = useState(0);
  const [autoNotes, setAutoNotes] = useState("");

  const [byShift, setByShift] = useState<ByShift>({ ...EMPTY_BY_SHIFT });
  const [tPassedNeutral, setTPassedNeutral] = useState(0);
  const [tPassedFull, setTPassedFull] = useState(0);
  const [stoleFuel, setStoleFuel] = useState(0);
  const [defended, setDefended] = useState(false);
  const [teleopNotes, setTeleopNotes] = useState("");

  const [climb, setClimb] = useState<ClimbLevel>("none");
  const [endFuel, setEndFuel] = useState(0);
  const [ePassedNeutral, setEPassedNeutral] = useState(0);
  const [ePassedFull, setEPassedFull] = useState(0);
  const [endStole, setEndStole] = useState(0);
  const [endNotes, setEndNotes] = useState("");
  const [finalNotes, setFinalNotes] = useState("");

  const [driver, setDriver] = useState<number | null>(null);
  const [defense, setDefense] = useState<number | null>(null);
  const [accuracy, setAccuracy] = useState<number | null>(null);
  const [avgBps, setAvgBps] = useState<number | null>(null);
  const [shootsOnMove, setShootsOnMove] = useState(false);
  const [broke, setBroke] = useState(false);
  const [brokeNotes, setBrokeNotes] = useState("");
  const [inconsistent, setInconsistent] = useState(false);
  const [inconsistentNotes, setInconsistentNotes] = useState("");

  const [autoWinner, setAutoWinner] = useState<"red" | "blue" | null>(null);
  const [saving, setSaving] = useState(false);
  const [override, setOverride] = useState(false);
  const [earlyAck, setEarlyAck] = useState(false);
  // Missing fields are outlined once someone tries to submit, not while they
  // are still working through the match.
  const [showErrors, setShowErrors] = useState(false);
  // Editing hydrates once. Convex queries are live, so re-hydrating would
  // stamp on the correction in progress every time anything else changed.
  useEffect(() => {
    if (!editing || hydrated) return;
    setStart(editing.auto.path.start);
    {
      // Reports written before the climb was a step carry it as a boolean.
      const loaded = readSteps(editing.auto.path);
      if (editing.auto.climbL1 && !loaded.some((step) => step.kind === "climb")) {
        loaded.push({ kind: "climb" });
      }
      setSteps(loaded);
    }
    setAutoFuel(editing.auto.fuel);
    setAutoFouls(editing.auto.fouls);
    setAutoNotes(editing.auto.notes);
    setByShift(editing.teleop.byShift);
    setTPassedNeutral(editing.teleop.passedNeutral);
    setTPassedFull(editing.teleop.passedFullField);
    setStoleFuel(editing.teleop.stoleFuel);
    setDefended(editing.teleop.defended);
    setTeleopNotes(editing.teleop.notes);
    setClimb(editing.endgame.climb);
    setEndFuel(editing.endgame.fuel);
    setEPassedNeutral(editing.endgame.passedNeutral);
    setEPassedFull(editing.endgame.passedFullField);
    setEndStole(editing.endgame.stoleFuel ?? 0);
    setEndNotes(editing.endgame.notes);
    setFinalNotes(editing.finalNotes ?? "");
    setDriver(editing.ratings.driver);
    setDefense(editing.ratings.defense);
    setAccuracy(editing.ratings.accuracy);
    setAvgBps(editing.avgBps ?? null);
    setShootsOnMove(editing.ratings.shootsOnMove);
    setBroke(editing.ratings.broke);
    setBrokeNotes(editing.ratings.brokeNotes);
    setInconsistent(editing.ratings.inconsistent);
    setInconsistentNotes(editing.ratings.inconsistentNotes);
    setAutoWinner(editing.autoWinner);
    setStartedAt(editing.matchStartedAt);
    setEstimated(editing.hubStateSource === "estimated");
    setHydrated(true);
  }, [editing, hydrated]);

  // No Match Start tap: anchor on the first look at teleop. Shifts are 25s, so
  // a few seconds of drift only misclassifies fuel near a boundary.
  useEffect(() => {
    if (editId) return;
    if (period === "teleop" && startedAt === null) {
      setStartedAt(estimatedStart());
      setEstimated(true);
    }
  }, [period, startedAt, editId]);

  const teleopTotal =
    byShift.transition + byShift.s1 + byShift.s2 + byShift.s3 + byShift.s4;

  const bankTeleop = (next: number) => {
    const delta = next - teleopTotal;
    setByShift((prev) => ({
      ...prev,
      [bucket]: Math.max(0, prev[bucket] + delta),
    }));
  };

  const isWinner = autoWinner !== null && data ? autoWinner === data.alliance : null;
  const counted = isWinner === null ? teleopTotal : countedTeleopFuel(byShift, isWinner);
  const dead = isWinner === null ? 0 : uncountedTeleopFuel(byShift, isWinner);
  const suspicious = dead > counted && dead > 0;

  // From this scouting team's own pit report. No line at all when the robot
  // was never pit scouted or its hopper capacity was left blank.
  const hopper = data?.hopper ?? null;
  const hopperLine =
    hopper && hopper.capacity !== null
      ? `Hopper Capacity: ${hopper.capacity}`
        + (hopper.expandedCapacity !== null
          ? `, Expanded Hopper Capacity: ${hopper.expandedCapacity}`
          : "")
      : null;

  const goTo = (next: typeof period) => {
    setPeriod(next);
    // The switch buttons sit at the bottom of a tab; land at the top of the next.
    document.getElementById("match-form-tabs")
      ?.scrollIntoView({ block: "start", behavior: "smooth" });
  };
  const goToTeleop = () => goTo("teleop");
  const goToConclusion = () => goTo("conclusion");

  const missing: string[] = [];
  if (start === null) missing.push("start position");
  if (driver === null) missing.push("driver rating");
  if (defense === null) missing.push("defense rating");
  if (accuracy === null) missing.push("shooting accuracy");
  if (autoWinner === null) missing.push("auto winner");
  if (finalNotes.trim() === "") missing.push("final notes");
  if (editId && editReason.trim() === "") missing.push("a reason for this edit");

  // Which fields to outline, and which tabs hold them.
  const bad = {
    start: showErrors && start === null,
    autoWinner: showErrors && autoWinner === null,
    driver: showErrors && driver === null,
    defense: showErrors && defense === null,
    accuracy: showErrors && accuracy === null,
    finalNotes: showErrors && finalNotes.trim() === "",
    editReason: showErrors && Boolean(editId) && editReason.trim() === "",
  };
  const autoMissing = bad.start || bad.autoWinner;
  const conclusionMissing = bad.driver || bad.defense || bad.accuracy || bad.finalNotes;

  // A report finished before the buzzer cannot have seen the endgame.
  const beforeMatchEnd = !editId && startedAt !== null && phase !== "over";

  // Values only an old report can have: the endgame tab that wrote them is
  // gone, but editing must not silently zero them.
  const legacyEndgame =
    editId !== null
    && (endFuel > 0 || ePassedNeutral > 0 || ePassedFull > 0
      || endStole > 0 || endNotes.trim() !== "");

  const hubStateSource: "timed" | "estimated" | "none" =
    startedAt === null ? "none" : estimated ? "estimated" : "timed";

  const save = async () => {
    if (!data?.match || !data.team) return;
    if (missing.length > 0) {
      setShowErrors(true);
      // Open the first tab with a gap; the edit reason sits below the tabs.
      if (start === null || autoWinner === null) goTo("auto");
      else if (driver === null || defense === null || accuracy === null || finalNotes.trim() === "") {
        goTo("conclusion");
      }
      toast.error("Some required fields are empty", {
        description: "What needs filling in is outlined in red.",
      });
      return;
    }
    setSaving(true);
    try {
      const payload = {
        auto: {
          path: { start, steps },
          // Derived from the path so the tower toggle is the only source.
          climbL1: steps.some((step) => step.kind === "climb"), fuel: autoFuel, fouls: autoFouls, notes: autoNotes,
        },
        teleop: {
          byShift,
          passedNeutral: tPassedNeutral,
          passedFullField: tPassedFull,
          stoleFuel, defended, notes: teleopNotes,
        },
        endgame: {
          climb, fuel: endFuel,
          passedNeutral: ePassedNeutral,
          passedFullField: ePassedFull,
          stoleFuel: endStole,
          notes: endNotes,
        },
        ratings: {
          driver: driver ?? 0, defense: defense ?? 0, accuracy: accuracy ?? 0,
          shootsOnMove,
          broke, brokeNotes: broke ? brokeNotes : "",
          inconsistent, inconsistentNotes: inconsistent ? inconsistentNotes : "",
        },
        avgBps: avgBps ?? 0,
        finalNotes,
        matchStartedAt: startedAt,
        autoWinner,
        hubStateSource,
      };

      if (editId) {
        await update({
          reportId: editId as Id<"matchReports">,
          reason: editReason.trim(),
          ...payload,
        });
        toast.success("Report updated");
        void navigate(-1);
      } else {
        const args = { matchId: data.match._id, teamId: data.team._id, ...payload };
        if (!online) {
          // No connection: hand the report to the outbox rather than
          // waiting here. It is kept on this device and sent when the
          // connection returns.
          const heldNow = holdSubmission({
            key: heldKey,
            label: `Qual ${matchNumber} · team ${teamNumber}`,
            to: `/scout/${matchNumber}/${teamNumber}`,
            values: payload,
            report: { kind: "match", args },
          });
          if (heldNow) void navigate("/scout");
          return;
        }
        await submit(args);
        toast.success(`Qual ${matchNumber} · team ${teamNumber} submitted`);
        void navigate("/scout");
      }
    } catch (error) {
      toast.error("Could not submit", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setSaving(false);
    }
  };

  if (!valid) return <PageShell title="Match Scouting" description="Bad URL." />;
  if (editId && !online && editing === undefined) {
    return (
      <PageShell title="Match Scouting">
        <NeedsConnection title="Needs a connection" description="Editing a submitted report needs a connection." />
      </PageShell>
    );
  }
  if (data === undefined && unavailable) {
    return (
      <PageShell title="Match Scouting">
        <NeedsConnection title="Not saved on this device" description="Open the Dashboard once while online, and this form will open offline." />
      </PageShell>
    );
  }
  if (data === undefined) return <PageShell title="Match Scouting" description="Loading…" />;
  if (data === null) {
    return (
      <PageShell title="Match Scouting" description="That match or team is not at the active event.">
        <Button variant="outline" onClick={() => void navigate("/scout")}>
          <ArrowLeft className="size-4" /> Back
        </Button>
      </PageShell>
    );
  }
  if (held && !editId) {
    // A submitted match report can only be changed with a reason on record,
    // so a held one is shown, not reopened as a form.
    return (
      <PageShell
        title={`Qual ${matchNumber} · ${data.team.number}`}
        description={
          held.status === "waiting"
            ? "This report is waiting to send. It cannot be changed until it has."
            : "This report could not be sent."
        }
      >
        <HeldSummary item={held} rows={summarizeMatchReport(held.values)} />
        <Button variant="outline" onClick={() => void navigate("/scout")}>
          <ArrowLeft className="size-4" /> Back
        </Button>
      </PageShell>
    );
  }
  if (data.myReport && !editId) {
    return (
      <PageShell
        title={`Qual ${matchNumber} · ${data.team.number}`}
        description="You have already reported this robot in this match."
      >
        <Button variant="outline" onClick={() => void navigate("/scout")}>
          <ArrowLeft className="size-4" /> Back
        </Button>
      </PageShell>
    );
  }

  return (
    <PageShell
      title={`Qual ${matchNumber} · ${data.team.number}`}
      description={
        data.othersCount > 0
          ? `${data.team.nickname} · ${data.alliance} alliance · ${data.othersCount} other report${data.othersCount === 1 ? "" : "s"} already submitted`
          : `${data.team.nickname} · ${data.alliance} alliance`
      }
      actions={
        <Button variant="outline" onClick={() => void navigate("/scout")}>
          <ArrowLeft className="size-4" /> Back
        </Button>
      }
    >
      <Card>
        <CardContent className="flex flex-wrap items-center gap-3 pt-6">
          {startedAt === null ? (
            <Button
              className="h-14 flex-1 text-base"
              onClick={() => { setStartedAt(Date.now()); setEstimated(false); }}
            >
              <Play className="size-4" /> Match Start
            </Button>
          ) : (
            <>
              <Badge variant={estimated ? "outline" : "default"} className="text-sm">
                {PHASE_LABELS[phase]}
              </Badge>
              <span className="text-muted-foreground text-xs">
                {estimated
                  ? "Estimated timing — Match Start was not tapped."
                  : "Fuel is banked per shift automatically."}
              </span>
            </>
          )}
        </CardContent>
      </Card>

      <Tabs value={period} onValueChange={(v) => setPeriod(v as typeof period)}>
        <TabsList id="match-form-tabs" className="w-full scroll-mt-4">
          <TabsTrigger value="auto" className="flex-1">
            Auto
            {autoMissing ? <span aria-hidden className="bg-destructive ml-1.5 size-1.5 rounded-full" /> : null}
          </TabsTrigger>
          <TabsTrigger value="teleop" className="flex-1">Teleop</TabsTrigger>
          <TabsTrigger value="conclusion" className="flex-1">
            Conclusion
            {conclusionMissing ? <span aria-hidden className="bg-destructive ml-1.5 size-1.5 rounded-full" /> : null}
          </TabsTrigger>
        </TabsList>

        <TabsContent value="auto" className="space-y-4 pt-4">
          <div className={bad.start ? "ring-destructive space-y-2 rounded-xl ring-2" : ""}>
            <AutoPathEditor
              alliance={data.alliance === "red" ? "red" : "blue"}
              start={start}
              onStartChange={setStart}
              steps={steps}
              onStepsChange={setSteps}
            />
            {bad.start ? (
              <p className="text-destructive px-4 pb-3 text-xs">Pick where the robot started.</p>
            ) : null}
          </div>

          <Card>
            <CardHeader>
              <CardTitle>Auto scoring</CardTitle>
              {hopperLine ? <CardDescription>{hopperLine}</CardDescription> : null}
            </CardHeader>
            <CardContent className="space-y-6">
              <Stepper label="Fuel scored" value={autoFuel} onChange={setAutoFuel} />
              <Stepper label="Fouls" value={autoFouls} onChange={setAutoFouls}
                downSteps={[-15, -5]} upSteps={[5, 15]} />
              <Textarea placeholder="Auto notes" rows={2}
                value={autoNotes} onChange={(e) => setAutoNotes(e.target.value)} />
            </CardContent>
          </Card>

          <Card className={bad.autoWinner ? "ring-destructive ring-2" : ""}>
            <CardHeader><CardTitle>Which alliance won auto?</CardTitle></CardHeader>
            <CardContent className="space-y-4">
              <p className="text-muted-foreground text-sm">
                The alliance scoring more auto fuel has its hub inactive first,
                which decides how much of the teleop fuel actually scored.
              </p>
              <SegmentedChoice
                label="More auto fuel"
                options={[
                  { value: "red", label: "Red" },
                  { value: "blue", label: "Blue" },
                ]}
                value={autoWinner}
                onChange={setAutoWinner}
              />
              {bad.autoWinner ? (
                <p className="text-destructive text-xs">Pick the alliance that scored more auto fuel.</p>
              ) : null}
              {autoWinner !== null ? (
                <div className="flex gap-4 text-sm">
                  <span>Counted: <strong className="tabular-nums">{counted}</strong></span>
                  <span className="text-muted-foreground">
                    Dead hub: <strong className="tabular-nums">{dead}</strong>
                  </span>
                </div>
              ) : null}
              <Button variant="outline" className="h-12 w-full" onClick={goToTeleop}>
                Switch to Teleop
                <ArrowRight className="size-4" />
              </Button>
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="teleop" className="space-y-4 pt-4">
          <Card>
            <CardHeader>
              <CardTitle>Teleop</CardTitle>
              {hopperLine ? <CardDescription>{hopperLine}</CardDescription> : null}
            </CardHeader>
            <CardContent className="space-y-6">
              <Stepper label="Fuel scored" value={teleopTotal} onChange={bankTeleop} />
              <Stepper label="Passed from neutral zone"
                value={tPassedNeutral} onChange={setTPassedNeutral} />
              <Stepper label="Passed full field"
                value={tPassedFull} onChange={setTPassedFull} />
              <Stepper label="Stole fuel" value={stoleFuel} onChange={setStoleFuel} />
              <CapabilityCheck id="defended" label="Defended an opposing robot"
                checked={defended} onChange={setDefended} />
              <Textarea placeholder="Teleop notes" rows={2}
                value={teleopNotes} onChange={(e) => setTeleopNotes(e.target.value)} />
              <Button variant="outline" className="h-12 w-full" onClick={goToConclusion}>
                Switch to Conclusion
                <ArrowRight className="size-4" />
              </Button>
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="conclusion" className="space-y-4 pt-4">
          <Card>
            <CardHeader><CardTitle>Endgame</CardTitle></CardHeader>
            <CardContent className="space-y-3">
              <SegmentedChoice label="Climb" options={CLIMB_OPTIONS}
                value={climb} onChange={setClimb} />
              <p className="text-muted-foreground text-xs">
                Fuel scored in the last 30 seconds goes on the Teleop stepper —
                the shift timer banks it for you.
              </p>
              {legacyEndgame ? (
                <p className="text-muted-foreground border-t pt-3 text-xs">
                  This report was written with the old endgame tab: {endFuel} fuel,{" "}
                  {ePassedNeutral + ePassedFull} passed, {endStole} stolen. Those
                  stay as they were — editing here does not clear them.
                </p>
              ) : null}
            </CardContent>
          </Card>

      <Card>
        <CardHeader><CardTitle>Ratings</CardTitle></CardHeader>
        <CardContent className="space-y-6">
          <RatingScale label="Driver" value={driver} onChange={setDriver}
            invalid={bad.driver} />
          <RatingScale label="Defense" value={defense} onChange={setDefense}
            invalid={bad.defense} />
          <RatingScale
            label="Shooting accuracy"
            value={accuracy}
            onChange={setAccuracy}
            invalid={bad.accuracy}
            min={0}
            max={100}
            step={5}
            unit="%"
          />
          <RatingScale
            label="Average BPS (observed)"
            value={avgBps}
            onChange={setAvgBps}
            values={BPS_VALUES}
            unit=" bps"
          />
          <CapabilityCheck id="on-move" label="Shoots on the move"
            checked={shootsOnMove} onChange={setShootsOnMove} />
          <CapabilityCheck id="broke" label="Robot broke down"
            checked={broke} onChange={setBroke} />
          {broke ? (
            <Input placeholder="What happened?" value={brokeNotes}
              onChange={(e) => setBrokeNotes(e.target.value)} />
          ) : null}
          <CapabilityCheck id="inconsistent" label="Robot was inconsistent"
            checked={inconsistent} onChange={setInconsistent} />
          {inconsistent ? (
            <Input placeholder="In what way?" value={inconsistentNotes}
              onChange={(e) => setInconsistentNotes(e.target.value)} />
          ) : null}
        </CardContent>
      </Card>

          <Card className={bad.finalNotes ? "ring-destructive ring-2" : ""}>
            <CardHeader><CardTitle>Final notes</CardTitle></CardHeader>
            <CardContent className="space-y-2">
              <p className="text-muted-foreground text-sm">
                Anything a strategy lead should know when they read this report
                during alliance selection.
              </p>
              <Textarea
                placeholder="Overall impression of this robot"
                rows={4}
                value={finalNotes}
                aria-invalid={bad.finalNotes || undefined}
                onChange={(e) => setFinalNotes(e.target.value)}
              />
              {bad.finalNotes ? (
                <p className="text-destructive text-xs">Final notes are required.</p>
              ) : null}
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>

      {suspicious && !override ? (
        <Card className="border-destructive">
          <CardContent className="space-y-3 pt-6">
            <div className="flex items-start gap-2">
              <AlertTriangle className="mt-0.5 size-4 shrink-0" />
              <p className="text-sm">
                You have logged more dead-hub fuel ({dead}) than live-hub fuel
                ({counted}). That usually means the auto winner is inverted — but
                a robot really can dump into a dead hub all match.
              </p>
            </div>
            <Button variant="outline" className="w-full"
              onClick={() => setOverride(true)}>
              That is correct, let me submit
            </Button>
          </CardContent>
        </Card>
      ) : null}

      {beforeMatchEnd && !earlyAck ? (
        <Card className="border-destructive">
          <CardContent className="space-y-3 pt-6">
            <div className="flex items-start gap-2">
              <AlertTriangle className="mt-0.5 size-4 shrink-0" />
              <p className="text-sm">
                The match is not over yet. A report submitted now cannot have
                seen the endgame — the climb, the last shift's fuel, or a robot
                that died in the final seconds. It will be flagged as early.
              </p>
            </div>
            <Button variant="outline" className="w-full"
              onClick={() => setEarlyAck(true)}>
              Submit early anyway
            </Button>
          </CardContent>
        </Card>
      ) : null}

      {editId ? (
        <Card>
          <CardHeader><CardTitle>Why are you changing this?</CardTitle></CardHeader>
          <CardContent className="space-y-2">
            <p className="text-muted-foreground text-sm">
              Appended to this report's history and never overwritten. Whoever
              reads the number later needs to know it moved, and why.
            </p>
            <Input
              placeholder="Reason (required)"
              value={editReason}
              aria-invalid={bad.editReason || undefined}
              onChange={(e) => setEditReason(e.target.value)}
            />
          </CardContent>
        </Card>
      ) : null}

      {missing.length > 0 ? (
        <p className="text-muted-foreground rounded-lg border border-dashed p-3 text-sm">
          Still needed: {missing.join(", ")}.
        </p>
      ) : null}

      <HeldNotice saving={saving} />
      <Button
        className="h-14 w-full text-base"
        disabled={
          saving ||
          (suspicious && !override) ||
          (beforeMatchEnd && !earlyAck)
        }
        onClick={() => void save()}
      >
        {saving ? <LoadingWheel className="size-4" /> : null}
        {editId ? "Save changes" : online ? "Submit report" : "Submit when back online"}
      </Button>
    </PageShell>
  );
}
