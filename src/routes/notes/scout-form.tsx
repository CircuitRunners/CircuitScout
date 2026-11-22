import { useMutation, useQuery } from "convex/react";
import type { FunctionReturnType } from "convex/server";
import { ArrowLeft, ArrowRight } from "lucide-react";
import { useState, type ReactNode } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import { CapabilityCheck } from "@/components/scouting/capability-check";
import { RatingScale } from "@/components/scouting/rating-scale";
import { LoadingWheel } from "@/components/loading-wheel";

/**
 * Match scouting for a season without its own forms: the 2026 form's shape
 * (Auto, Teleop, Conclusion) with the game-specific parts as text boxes. No
 * clock, no auto winner, nothing timed.
 */

type MatchData = NonNullable<FunctionReturnType<typeof api.notes.matchNote>>;
type Period = "auto" | "teleop" | "conclusion";

export default function NotesScoutFormPage() {
  const params = useParams();
  const matchNumber = Number.parseInt(params.matchNumber ?? "", 10);
  const teamNumber = Number.parseInt(params.teamNumber ?? "", 10);
  const bad = Number.isNaN(matchNumber) || Number.isNaN(teamNumber);
  const data = useQuery(api.notes.matchNote, bad ? "skip" : { matchNumber, teamNumber });

  const back = (
    <Button variant="outline" render={<Link to="/scout" />}>
      <ArrowLeft className="size-4" /> Back
    </Button>
  );
  if (bad) return <PageShell title="Match Scouting" description="Bad URL." actions={back} />;
  if (data === undefined) return <PageShell title="Match Scouting" description="Loading…" actions={back} />;
  if (data === null) {
    return (
      <PageShell title="Match Scouting" actions={back}
        description={`Team ${teamNumber} is not in Qual ${matchNumber} at the active event.`} />
    );
  }
  // Keyed, so a saved report seeds the form exactly once per robot and match.
  return <MatchReportForm key={`${data.matchNumber}:${data.teamNumber}`} data={data} back={back} />;
}

function MatchReportForm({ data, back }: { data: MatchData; back: ReactNode }) {
  const navigate = useNavigate();
  const save = useMutation(api.notes.saveMatchReport);
  const saved = data.report;

  // Every match opens on Auto.
  const [period, setPeriod] = useState<Period>("auto");
  const [autoPath, setAutoPath] = useState(saved?.autoPath ?? "");
  const [autoScoring, setAutoScoring] = useState(saved?.autoScoring ?? "");
  const [teleopScoring, setTeleopScoring] = useState(saved?.teleopScoring ?? "");
  const [endgame, setEndgame] = useState(saved?.endgame ?? "");
  const [driver, setDriver] = useState<number | null>(saved?.driver ?? null);
  const [defense, setDefense] = useState<number | null>(saved?.defense ?? null);
  const [broke, setBroke] = useState(saved?.broke ?? false);
  const [brokeNotes, setBrokeNotes] = useState(saved?.brokeNotes ?? "");
  const [inconsistent, setInconsistent] = useState(saved?.inconsistent ?? false);
  const [inconsistentNotes, setInconsistentNotes] = useState(saved?.inconsistentNotes ?? "");
  // A plain note from before the form becomes the final notes.
  const [finalNotes, setFinalNotes] = useState(saved?.notes ?? data.notes ?? "");
  const [saving, setSaving] = useState(false);
  // Missing fields are outlined once someone tries to submit.
  const [showErrors, setShowErrors] = useState(false);

  const goTo = (next: Period) => {
    setPeriod(next);
    // The switch buttons sit at the bottom of a tab; land at the top of the next.
    document.getElementById("match-form-tabs")?.scrollIntoView({ block: "start", behavior: "smooth" });
  };

  const missing: string[] = [];
  if (driver === null) missing.push("driver rating");
  if (defense === null) missing.push("defense rating");
  if (finalNotes.trim() === "") missing.push("final notes");
  const bad = {
    driver: showErrors && driver === null,
    defense: showErrors && defense === null,
    finalNotes: showErrors && finalNotes.trim() === "",
  };
  const conclusionMissing = bad.driver || bad.defense || bad.finalNotes;

  const submit = async () => {
    if (driver === null || defense === null || finalNotes.trim() === "") {
      setShowErrors(true);
      goTo("conclusion");
      toast.error("Some required fields are empty", { description: "What needs filling in is outlined in red." });
      return;
    }
    setSaving(true);
    try {
      await save({
        matchNumber: data.matchNumber,
        teamNumber: data.teamNumber,
        autoPath, autoScoring, teleopScoring, endgame,
        driver, defense,
        broke, brokeNotes: broke ? brokeNotes : "",
        inconsistent, inconsistentNotes: inconsistent ? inconsistentNotes : "",
        notes: finalNotes,
      });
      toast.success(`Qual ${data.matchNumber} · team ${data.teamNumber} ${saved || data.notes !== null ? "updated" : "submitted"}`);
      void navigate("/scout");
    } catch (error) {
      toast.error("Could not submit", { description: error instanceof Error ? error.message : String(error) });
    } finally {
      setSaving(false);
    }
  };

  const box = (id: string, label: string, value: string, set: (v: string) => void, placeholder: string) => (
    <Textarea id={id} aria-label={label} rows={4} maxLength={2000} placeholder={placeholder}
      value={value} onChange={(e) => set(e.target.value)} />
  );

  return (
    <PageShell
      title={
        <>
          Qual {data.matchNumber} · {data.teamNumber}
          <Badge className={data.alliance === "red" ? "bg-red-600 text-white" : "bg-blue-600 text-white"}>
            {data.alliance === "red" ? "Red" : "Blue"}
          </Badge>
        </>
      }
      description={
        saved || data.notes !== null
          ? `${data.nickname}. You have scouted this robot in this match already; saving replaces it.`
          : data.nickname
      }
      actions={back}
    >
      <Tabs value={period} onValueChange={(v) => setPeriod(v as Period)}>
        <TabsList id="match-form-tabs" className="w-full scroll-mt-4">
          <TabsTrigger value="auto" className="flex-1">Auto</TabsTrigger>
          <TabsTrigger value="teleop" className="flex-1">Teleop</TabsTrigger>
          <TabsTrigger value="conclusion" className="flex-1">
            Conclusion
            {conclusionMissing ? <span aria-hidden className="bg-destructive ml-1.5 size-1.5 rounded-full" /> : null}
          </TabsTrigger>
        </TabsList>

        <TabsContent value="auto" className="space-y-4 pt-4">
          <Card>
            <CardHeader>
              <CardTitle>Auto path</CardTitle>
              <CardDescription>Where the robot started and where it went.</CardDescription>
            </CardHeader>
            <CardContent>
              {box("auto-path", "Auto path", autoPath, setAutoPath, "e.g. Started left, drove to the centre line, came back to score")}
            </CardContent>
          </Card>
          <Card>
            <CardHeader><CardTitle>Auto scoring</CardTitle></CardHeader>
            <CardContent className="space-y-4">
              {box("auto-scoring", "Auto scoring", autoScoring, setAutoScoring, "What it scored in auto, and how much")}
              <Button variant="outline" className="h-12 w-full" onClick={() => goTo("teleop")}>
                Switch to Teleop
                <ArrowRight className="size-4" />
              </Button>
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="teleop" className="space-y-4 pt-4">
          <Card>
            <CardHeader><CardTitle>Teleop scoring</CardTitle></CardHeader>
            <CardContent className="space-y-4">
              {box("teleop-scoring", "Teleop scoring", teleopScoring, setTeleopScoring, "What it scored in teleop, how often, from where")}
              <Button variant="outline" className="h-12 w-full" onClick={() => goTo("conclusion")}>
                Switch to Conclusion
                <ArrowRight className="size-4" />
              </Button>
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="conclusion" className="space-y-4 pt-4">
          <Card>
            <CardHeader><CardTitle>Endgame</CardTitle></CardHeader>
            <CardContent>
              {box("endgame", "Endgame", endgame, setEndgame, "What it did at the end of the match")}
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>Ratings</CardTitle></CardHeader>
            <CardContent className="space-y-6">
              <RatingScale label="Driver" value={driver} onChange={setDriver} invalid={bad.driver} />
              <RatingScale label="Defense" value={defense} onChange={setDefense} invalid={bad.defense} />
              <CapabilityCheck id="broke" label="Robot broke down" checked={broke} onChange={setBroke} />
              {broke ? (
                <Input placeholder="What happened?" value={brokeNotes} maxLength={500}
                  onChange={(e) => setBrokeNotes(e.target.value)} />
              ) : null}
              <CapabilityCheck id="inconsistent" label="Robot was inconsistent"
                checked={inconsistent} onChange={setInconsistent} />
              {inconsistent ? (
                <Input placeholder="In what way?" value={inconsistentNotes} maxLength={500}
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
              <Textarea placeholder="Overall impression of this robot" rows={4} value={finalNotes}
                aria-invalid={bad.finalNotes || undefined}
                onChange={(e) => setFinalNotes(e.target.value)} />
              {bad.finalNotes ? <p className="text-destructive text-xs">Final notes are required.</p> : null}
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>

      {missing.length > 0 ? (
        <p className="text-muted-foreground rounded-lg border border-dashed p-3 text-sm">
          Still needed: {missing.join(", ")}.
        </p>
      ) : null}
      <Button className="h-14 w-full text-base" disabled={saving} onClick={() => void submit()}>
        {saving ? <LoadingWheel className="size-4" /> : null}
        {saved || data.notes !== null ? "Save changes" : "Submit report"}
      </Button>
    </PageShell>
  );
}
