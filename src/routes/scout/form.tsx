import { useMutation, useQuery } from "convex/react";
import { AlertTriangle, ArrowLeft, LoaderCircle, Play } from "lucide-react";
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
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import {
  EMPTY_BY_SHIFT, countedTeleopFuel, uncountedTeleopFuel, type ByShift,
} from "@/lib/scoring";
import type { AutoStep, ClimbLevel, StartPosition } from "@/lib/types";
import { readSteps } from "@/lib/types";
import { useUIStore } from "@/stores/ui-store";

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

  const data = useQuery(
    api.matchReports.forMatchAndTeam,
    valid ? { matchNumber, teamNumber } : "skip",
  );
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

  const period = useUIStore((s) => s.matchFormPeriod);
  const setPeriod = useUIStore((s) => s.setMatchFormPeriod);

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

  const missing: string[] = [];
  if (start === null) missing.push("start position");
  if (driver === null) missing.push("driver rating");
  if (defense === null) missing.push("defense rating");
  if (accuracy === null) missing.push("shooting accuracy");
  if (autoWinner === null) missing.push("auto winner");
  if (finalNotes.trim() === "") missing.push("final notes");
  if (editId && editReason.trim() === "") missing.push("a reason for this edit");

  // A report finished before the buzzer cannot have seen the endgame.
  const beforeMatchEnd = !editId && startedAt !== null && phase !== "over";

  const hubStateSource: "timed" | "estimated" | "none" =
    startedAt === null ? "none" : estimated ? "estimated" : "timed";

  const save = async () => {
    if (!data?.match || !data.team) return;
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
        await submit({
          matchId: data.match._id,
          teamId: data.team._id,
          ...payload,
        });
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
        <TabsList className="w-full">
          <TabsTrigger value="auto" className="flex-1">Auto</TabsTrigger>
          <TabsTrigger value="teleop" className="flex-1">Teleop</TabsTrigger>
          <TabsTrigger value="endgame" className="flex-1">Endgame</TabsTrigger>
          <TabsTrigger value="conclusion" className="flex-1">Conclusion</TabsTrigger>
        </TabsList>

        <TabsContent value="auto" className="space-y-4 pt-4">
          <AutoPathEditor
            alliance={data.alliance === "red" ? "red" : "blue"}
            start={start}
            onStartChange={setStart}
            steps={steps}
            onStepsChange={setSteps}
          />

          <Card>
            <CardHeader><CardTitle>Auto scoring</CardTitle></CardHeader>
            <CardContent className="space-y-6">
              <Stepper label="Fuel scored" value={autoFuel} onChange={setAutoFuel} />
              <Stepper label="Fouls" value={autoFouls} onChange={setAutoFouls}
                downSteps={[-15, -5]} upSteps={[5, 15]} />
              <Textarea placeholder="Auto notes" rows={2}
                value={autoNotes} onChange={(e) => setAutoNotes(e.target.value)} />
            </CardContent>
          </Card>

          <Card>
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
              {autoWinner !== null ? (
                <div className="flex gap-4 text-sm">
                  <span>Counted: <strong className="tabular-nums">{counted}</strong></span>
                  <span className="text-muted-foreground">
                    Dead hub: <strong className="tabular-nums">{dead}</strong>
                  </span>
                </div>
              ) : null}
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="teleop" className="space-y-4 pt-4">
          <Card>
            <CardHeader><CardTitle>Teleop</CardTitle></CardHeader>
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
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="endgame" className="space-y-4 pt-4">
          <Card>
            <CardHeader><CardTitle>Endgame</CardTitle></CardHeader>
            <CardContent className="space-y-6">
              <SegmentedChoice label="Climb" options={CLIMB_OPTIONS}
                value={climb} onChange={setClimb} />
              <Stepper label="Fuel scored" value={endFuel} onChange={setEndFuel} />
              <Stepper label="Passed from neutral zone"
                value={ePassedNeutral} onChange={setEPassedNeutral} />
              <Stepper label="Passed full field"
                value={ePassedFull} onChange={setEPassedFull} />
              <Stepper label="Stole fuel" value={endStole} onChange={setEndStole} />
              <Textarea placeholder="Endgame notes" rows={2}
                value={endNotes} onChange={(e) => setEndNotes(e.target.value)} />
            </CardContent>
          </Card>

        </TabsContent>
        <TabsContent value="conclusion" className="space-y-4 pt-4">
      <Card>
        <CardHeader><CardTitle>Ratings</CardTitle></CardHeader>
        <CardContent className="space-y-6">
          <RatingScale label="Driver" value={driver} onChange={setDriver} />
          <RatingScale label="Defense" value={defense} onChange={setDefense} />
          <RatingScale
            label="Shooting accuracy"
            value={accuracy}
            onChange={setAccuracy}
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

          <Card>
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
                onChange={(e) => setFinalNotes(e.target.value)}
              />
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

      <Button
        className="h-14 w-full text-base"
        disabled={
          saving ||
          missing.length > 0 ||
          (suspicious && !override) ||
          (beforeMatchEnd && !earlyAck)
        }
        onClick={() => void save()}
      >
        {saving ? <LoaderCircle className="size-4 animate-spin" /> : null}
        {editId ? "Save changes" : "Submit report"}
      </Button>
    </PageShell>
  );
}
