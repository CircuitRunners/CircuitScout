#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-generic-match.sh
#   Match scouting for seasons without their own forms becomes a form with
#   Auto / Teleop / Conclusion tabs instead of one notes box:
#   1-2. No Match Start and no timing of any kind
#   3-4. Auto: auto path and auto scoring as text boxes, then Switch to Teleop
#   6.   Teleop: teleop scoring as a text box, then Switch to Conclusion
#   7.   Conclusion: endgame as a text box
#   8.   Ratings: driver and defense (required), robot broke down, robot was
#        inconsistent. No accuracy, BPS or shoots on the move.
#   9.   Final notes (required)
#   No auto winner. Missing required fields are outlined in red on submit.
#
# Stored on the existing matchNotes rows (new optional fields), so match
# notes already written are kept and show up as the form's Final notes. The
# match view, team view, notes export and practice list show the new fields.
# Practice mode applies. 2026 is untouched.
#
# Needs patch-generic-pit.sh and patch-match-form-nav.sh applied first.
#
# Every edit is checked before any file is written, so a mismatch stops the
# patch with nothing half-applied. CRLF checkouts are handled.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/pit.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

if grep -qF 'teleopScoring' convex/schema.ts; then
  echo "patch-generic-match already applied."
  exit 0
fi
if ! grep -qF 'scoringText' convex/schema.ts; then
  echo "ERROR: run patch-generic-pit.sh first." >&2
  exit 1
fi
if ! grep -qF 'invalid' src/components/scouting/rating-scale.tsx; then
  echo "ERROR: run patch-match-form-nav.sh first." >&2
  exit 1
fi

# Working files live in the repo root, not /tmp: on Windows, Git Bash's /tmp
# is not where bun looks for a "/tmp/..." path written inside a script.
JSON_FILE=".patch-generic-match.json"
MJS_FILE=".patch-generic-match.mjs"
trap 'rm -f "$JSON_FILE" "$MJS_FILE"' EXIT

say "Applying patch-generic-match"
cat > "$JSON_FILE" <<'PATCH_EDITS_JSON'
[
 {
  "file": "convex/schema.ts",
  "old": "    scoutingTeamNumber: v.number(),\n    notes: v.string(),\n    submittedAt: v.number(),\n    updatedAt: v.number(),\n  })",
  "new": "    scoutingTeamNumber: v.number(),\n    /** Final notes. On rows from before the match form, the whole note. */\n    notes: v.string(),\n    submittedAt: v.number(),\n    updatedAt: v.number(),\n    // The match form for seasons without their own forms. All optional: rows\n    // written as plain notes have none of them.\n    autoPath: v.optional(v.string()),\n    autoScoring: v.optional(v.string()),\n    teleopScoring: v.optional(v.string()),\n    endgame: v.optional(v.string()),\n    /** 1 to 10. */\n    driver: v.optional(v.number()),\n    defense: v.optional(v.number()),\n    broke: v.optional(v.boolean()),\n    brokeNotes: v.optional(v.string()),\n    inconsistent: v.optional(v.boolean()),\n    inconsistentNotes: v.optional(v.string()),\n  })"
 },
 {
  "file": "convex/lib/genericMatch.ts",
  "old": null,
  "new": "/**\n * How a match report from the form for seasons without their own forms\n * reads, as label/text pairs for the match and team views. Final notes are\n * shown on their own, so they are not in here. Plain notes from before the\n * form have no sections at all.\n */\nexport type GenericMatchFields = {\n  autoPath?: string;\n  autoScoring?: string;\n  teleopScoring?: string;\n  endgame?: string;\n  driver?: number;\n  defense?: number;\n  broke?: boolean;\n  brokeNotes?: string;\n  inconsistent?: boolean;\n  inconsistentNotes?: string;\n};\n\nexport function matchSections(n: GenericMatchFields): Array<[string, string]> {\n  const out: Array<[string, string]> = [];\n  const add = (label: string, value: string | undefined) => {\n    if (value !== undefined && value.trim() !== \"\") out.push([label, value.trim()]);\n  };\n  add(\"Auto path\", n.autoPath);\n  add(\"Auto scoring\", n.autoScoring);\n  add(\"Teleop scoring\", n.teleopScoring);\n  add(\"Endgame\", n.endgame);\n  if (n.driver !== undefined) add(\"Driver\", `${n.driver}/10`);\n  if (n.defense !== undefined) add(\"Defense\", `${n.defense}/10`);\n  if (n.broke) add(\"Broke down\", n.brokeNotes?.trim() || \"Yes\");\n  if (n.inconsistent) add(\"Inconsistent\", n.inconsistentNotes?.trim() || \"Yes\");\n  return out;\n}\n"
 },
 {
  "file": "convex/notes.ts",
  "old": "import { MAX_OTHER_SPARES, batteryText, spareText } from \"./lib/spares\";",
  "new": "import { MAX_OTHER_SPARES, batteryText, spareText } from \"./lib/spares\";\nimport { matchSections } from \"./lib/genericMatch\";"
 },
 {
  "file": "convex/notes.ts",
  "old": "    const mine = (\n      await ctx.db\n        .query(\"matchNotes\")\n        .withIndex(\"by_match\", (q) => q.eq(\"matchId\", match._id))\n        .collect()\n    ).find((n) => n.teamId === team._id && n.scoutId === userId) ?? null;\n    return {\n      matchNumber: match.matchNumber,\n      teamNumber: team.number,\n      nickname: team.nickname,\n      alliance,\n      notes: mine?.notes ?? null,\n    };",
  "new": "    // Practice starts from a blank form, not the scout's real report.\n    const mine = (await isPracticing(ctx)) ? null : ((\n      await ctx.db\n        .query(\"matchNotes\")\n        .withIndex(\"by_match\", (q) => q.eq(\"matchId\", match._id))\n        .collect()\n    ).find((n) => n.teamId === team._id && n.scoutId === userId) ?? null);\n    return {\n      matchNumber: match.matchNumber,\n      teamNumber: team.number,\n      nickname: team.nickname,\n      alliance,\n      notes: mine?.notes ?? null,\n      report: mine\n        ? {\n            autoPath: mine.autoPath ?? \"\",\n            autoScoring: mine.autoScoring ?? \"\",\n            teleopScoring: mine.teleopScoring ?? \"\",\n            endgame: mine.endgame ?? \"\",\n            driver: mine.driver ?? null,\n            defense: mine.defense ?? null,\n            broke: mine.broke ?? false,\n            brokeNotes: mine.brokeNotes ?? \"\",\n            inconsistent: mine.inconsistent ?? false,\n            inconsistentNotes: mine.inconsistentNotes ?? \"\",\n            notes: mine.notes,\n          }\n        : null,\n    };"
 },
 {
  "file": "convex/notes.ts",
  "old": "/** Your match notes at this event, newest first, for \"My notes\". */",
  "new": "/**\n * The match form for seasons without their own forms. One report per scout\n * per robot per match; saving again replaces it.\n */\nexport const saveMatchReport = mutation({\n  args: {\n    matchNumber: v.number(),\n    teamNumber: v.number(),\n    autoPath: v.string(),\n    autoScoring: v.string(),\n    teleopScoring: v.string(),\n    endgame: v.string(),\n    driver: v.number(),\n    defense: v.number(),\n    broke: v.boolean(),\n    brokeNotes: v.string(),\n    inconsistent: v.boolean(),\n    inconsistentNotes: v.string(),\n    notes: v.string(),\n  },\n  handler: async (ctx, args) => {\n    const scoutId = await requireUser(ctx);\n    const event = await activeEvent(ctx);\n    if (!event) throw new Error(\"No active event.\");\n    const scoutingTeamNumber = await currentTeamNumber(ctx);\n    if (scoutingTeamNumber === undefined) {\n      throw new Error(\"Set your team number on your profile first.\");\n    }\n    const match = await matchByNumber(ctx, event._id, args.matchNumber);\n    if (!match) throw new Error(\"That match is not in the schedule.\");\n    if (allianceOf(match, args.teamNumber) === null) {\n      throw new Error(`Team ${args.teamNumber} is not in Qual ${args.matchNumber}.`);\n    }\n    const team = await teamByNumber(ctx, event._id, args.teamNumber);\n    if (!team) throw new Error(\"That team is not part of the active event.\");\n\n    const rating = (n: number, what: string) => {\n      if (!Number.isInteger(n) || n < 1 || n > 10) throw new Error(`${what} rating must be from 1 to 10.`);\n      return n;\n    };\n    const notes = args.notes.trim();\n    if (notes === \"\") throw new Error(\"Final notes are required.\");\n    const fields = {\n      autoPath: text(args.autoPath, 2000, \"Auto path\"),\n      autoScoring: text(args.autoScoring, 2000, \"Auto scoring\"),\n      teleopScoring: text(args.teleopScoring, 2000, \"Teleop scoring\"),\n      endgame: text(args.endgame, 2000, \"Endgame\"),\n      driver: rating(args.driver, \"Driver\"),\n      defense: rating(args.defense, \"Defense\"),\n      broke: args.broke,\n      brokeNotes: args.broke ? text(args.brokeNotes, 500, \"What happened\") : \"\",\n      inconsistent: args.inconsistent,\n      inconsistentNotes: args.inconsistent ? text(args.inconsistentNotes, 500, \"In what way\") : \"\",\n      notes: text(notes, MAX_NOTE, \"Final notes\"),\n    };\n\n    if (await isPracticing(ctx)) {\n      return await savePractice(ctx, {\n        kind: \"matchNote\", teamNumber: team.number, matchNumber: match.matchNumber, payload: fields,\n      });\n    }\n\n    const existing = (\n      await ctx.db\n        .query(\"matchNotes\")\n        .withIndex(\"by_match\", (q) => q.eq(\"matchId\", match._id))\n        .collect()\n    ).find((n) => n.teamId === team._id && n.scoutId === scoutId);\n\n    const now = Date.now();\n    if (existing) {\n      await ctx.db.patch(existing._id, { ...fields, scoutingTeamNumber, updatedAt: now });\n      return existing._id;\n    }\n    return await ctx.db.insert(\"matchNotes\", {\n      eventId: event._id,\n      matchId: match._id,\n      teamId: team._id,\n      scoutId,\n      scoutingTeamNumber,\n      ...fields,\n      submittedAt: now,\n      updatedAt: now,\n    });\n  },\n});\n\n/** Your match notes at this event, newest first, for \"My notes\". */"
 },
 {
  "file": "convex/notes.ts",
  "old": "                .map((n) => ({\n                  id: n._id,\n                  scoutName: names.get(n.scoutId) ?? \"Unknown scout\",\n                  notes: n.notes,\n                }))",
  "new": "                .map((n) => ({\n                  id: n._id,\n                  scoutName: names.get(n.scoutId) ?? \"Unknown scout\",\n                  notes: n.notes,\n                  sections: matchSections(n),\n                }))"
 },
 {
  "file": "convex/notes.ts",
  "old": "          matchNumber: matchNumberById.get(n.matchId) ?? null,\n          scoutName: names.get(n.scoutId) ?? \"Unknown scout\",\n          notes: n.notes,\n          updatedAt: n.updatedAt,",
  "new": "          matchNumber: matchNumberById.get(n.matchId) ?? null,\n          scoutName: names.get(n.scoutId) ?? \"Unknown scout\",\n          notes: n.notes,\n          sections: matchSections(n),\n          updatedAt: n.updatedAt,"
 },
 {
  "file": "convex/notes.ts",
  "old": "            scout: names.get(n.scoutId) ?? \"\",\n            updatedAt: stamp(n.updatedAt),\n            notes: n.notes,\n          };",
  "new": "            scout: names.get(n.scoutId) ?? \"\",\n            updatedAt: stamp(n.updatedAt),\n            autoPath: n.autoPath ?? \"\",\n            autoScoring: n.autoScoring ?? \"\",\n            teleopScoring: n.teleopScoring ?? \"\",\n            endgame: n.endgame ?? \"\",\n            driver: n.driver ?? \"\",\n            defense: n.defense ?? \"\",\n            broke: n.broke ? (n.brokeNotes || \"yes\") : \"\",\n            inconsistent: n.inconsistent ? (n.inconsistentNotes || \"yes\") : \"\",\n            finalNotes: n.notes,\n          };"
 },
 {
  "file": "src/routes/notes/scout-form.tsx",
  "old": "import { useMutation, useQuery } from \"convex/react\";\nimport { ArrowLeft } from \"lucide-react\";\nimport { Link, useNavigate, useParams } from \"react-router\";\n\nimport { api } from \"../../../convex/_generated/api\";\nimport { NoteEditor } from \"./note-editor\";\nimport { PageShell } from \"@/routes/page-shell\";\nimport { Badge } from \"@/components/ui/badge\";\nimport { Button } from \"@/components/ui/button\";\n\nexport default function NotesScoutFormPage() {\n  const params = useParams();\n  const navigate = useNavigate();\n  const matchNumber = Number.parseInt(params.matchNumber ?? \"\", 10);\n  const teamNumber = Number.parseInt(params.teamNumber ?? \"\", 10);\n  const bad = Number.isNaN(matchNumber) || Number.isNaN(teamNumber);\n  const data = useQuery(api.notes.matchNote, bad ? \"skip\" : { matchNumber, teamNumber });\n  const save = useMutation(api.notes.saveMatch);\n\n  const back = (\n    <Button variant=\"outline\" render={<Link to=\"/scout\" />}>\n      <ArrowLeft className=\"size-4\" /> All matches\n    </Button>\n  );\n\n  if (bad) return <PageShell title=\"Match notes\" description=\"Bad URL.\" actions={back} />;\n  if (data === undefined) return <PageShell title=\"Match notes\" description=\"Loading…\" actions={back} />;\n  if (data === null) {\n    return (\n      <PageShell title=\"Match notes\" actions={back}\n        description={`Team ${teamNumber} is not in Qual ${matchNumber} at the active event.`} />\n    );\n  }\n\n  return (\n    <PageShell\n      title={\n        <>\n          Qual {data.matchNumber} · {data.teamNumber}\n          <Badge className={data.alliance === \"red\" ? \"bg-red-600 text-white\" : \"bg-blue-600 text-white\"}>\n            {data.alliance === \"red\" ? \"Red\" : \"Blue\"}\n          </Badge>\n        </>\n      }\n      description={\n        data.notes === null\n          ? `${data.nickname}. Your notes on this robot in this match.`\n          : `${data.nickname}. You have notes on this robot already; saving replaces them.`\n      }\n      actions={back}\n    >\n      <NoteEditor key={`${data.matchNumber}:${data.teamNumber}`} id=\"match-notes\"\n        initial={data.notes ?? \"\"}\n        onSave={(notes) => save({ matchNumber, teamNumber, notes })}\n        onSaved={() => void navigate(\"/scout\")} />\n    </PageShell>\n  );\n}\n",
  "new": "import { useMutation, useQuery } from \"convex/react\";\nimport type { FunctionReturnType } from \"convex/server\";\nimport { ArrowLeft, ArrowRight } from \"lucide-react\";\nimport { useState, type ReactNode } from \"react\";\nimport { Link, useNavigate, useParams } from \"react-router\";\nimport { toast } from \"sonner\";\n\nimport { api } from \"../../../convex/_generated/api\";\nimport { PageShell } from \"@/routes/page-shell\";\nimport { Badge } from \"@/components/ui/badge\";\nimport { Button } from \"@/components/ui/button\";\nimport { Card, CardContent, CardDescription, CardHeader, CardTitle } from \"@/components/ui/card\";\nimport { Input } from \"@/components/ui/input\";\nimport { Tabs, TabsContent, TabsList, TabsTrigger } from \"@/components/ui/tabs\";\nimport { Textarea } from \"@/components/ui/textarea\";\nimport { CapabilityCheck } from \"@/components/scouting/capability-check\";\nimport { RatingScale } from \"@/components/scouting/rating-scale\";\nimport { LoadingWheel } from \"@/components/loading-wheel\";\n\n/**\n * Match scouting for a season without its own forms: the 2026 form's shape\n * (Auto, Teleop, Conclusion) with the game-specific parts as text boxes. No\n * clock, no auto winner, nothing timed.\n */\n\ntype MatchData = NonNullable<FunctionReturnType<typeof api.notes.matchNote>>;\ntype Period = \"auto\" | \"teleop\" | \"conclusion\";\n\nexport default function NotesScoutFormPage() {\n  const params = useParams();\n  const matchNumber = Number.parseInt(params.matchNumber ?? \"\", 10);\n  const teamNumber = Number.parseInt(params.teamNumber ?? \"\", 10);\n  const bad = Number.isNaN(matchNumber) || Number.isNaN(teamNumber);\n  const data = useQuery(api.notes.matchNote, bad ? \"skip\" : { matchNumber, teamNumber });\n\n  const back = (\n    <Button variant=\"outline\" render={<Link to=\"/scout\" />}>\n      <ArrowLeft className=\"size-4\" /> Back\n    </Button>\n  );\n  if (bad) return <PageShell title=\"Match Scouting\" description=\"Bad URL.\" actions={back} />;\n  if (data === undefined) return <PageShell title=\"Match Scouting\" description=\"Loading…\" actions={back} />;\n  if (data === null) {\n    return (\n      <PageShell title=\"Match Scouting\" actions={back}\n        description={`Team ${teamNumber} is not in Qual ${matchNumber} at the active event.`} />\n    );\n  }\n  // Keyed, so a saved report seeds the form exactly once per robot and match.\n  return <MatchReportForm key={`${data.matchNumber}:${data.teamNumber}`} data={data} back={back} />;\n}\n\nfunction MatchReportForm({ data, back }: { data: MatchData; back: ReactNode }) {\n  const navigate = useNavigate();\n  const save = useMutation(api.notes.saveMatchReport);\n  const saved = data.report;\n\n  // Every match opens on Auto.\n  const [period, setPeriod] = useState<Period>(\"auto\");\n  const [autoPath, setAutoPath] = useState(saved?.autoPath ?? \"\");\n  const [autoScoring, setAutoScoring] = useState(saved?.autoScoring ?? \"\");\n  const [teleopScoring, setTeleopScoring] = useState(saved?.teleopScoring ?? \"\");\n  const [endgame, setEndgame] = useState(saved?.endgame ?? \"\");\n  const [driver, setDriver] = useState<number | null>(saved?.driver ?? null);\n  const [defense, setDefense] = useState<number | null>(saved?.defense ?? null);\n  const [broke, setBroke] = useState(saved?.broke ?? false);\n  const [brokeNotes, setBrokeNotes] = useState(saved?.brokeNotes ?? \"\");\n  const [inconsistent, setInconsistent] = useState(saved?.inconsistent ?? false);\n  const [inconsistentNotes, setInconsistentNotes] = useState(saved?.inconsistentNotes ?? \"\");\n  // A plain note from before the form becomes the final notes.\n  const [finalNotes, setFinalNotes] = useState(saved?.notes ?? data.notes ?? \"\");\n  const [saving, setSaving] = useState(false);\n  // Missing fields are outlined once someone tries to submit.\n  const [showErrors, setShowErrors] = useState(false);\n\n  const goTo = (next: Period) => {\n    setPeriod(next);\n    // The switch buttons sit at the bottom of a tab; land at the top of the next.\n    document.getElementById(\"match-form-tabs\")?.scrollIntoView({ block: \"start\", behavior: \"smooth\" });\n  };\n\n  const missing: string[] = [];\n  if (driver === null) missing.push(\"driver rating\");\n  if (defense === null) missing.push(\"defense rating\");\n  if (finalNotes.trim() === \"\") missing.push(\"final notes\");\n  const bad = {\n    driver: showErrors && driver === null,\n    defense: showErrors && defense === null,\n    finalNotes: showErrors && finalNotes.trim() === \"\",\n  };\n  const conclusionMissing = bad.driver || bad.defense || bad.finalNotes;\n\n  const submit = async () => {\n    if (driver === null || defense === null || finalNotes.trim() === \"\") {\n      setShowErrors(true);\n      goTo(\"conclusion\");\n      toast.error(\"Some required fields are empty\", { description: \"What needs filling in is outlined in red.\" });\n      return;\n    }\n    setSaving(true);\n    try {\n      await save({\n        matchNumber: data.matchNumber,\n        teamNumber: data.teamNumber,\n        autoPath, autoScoring, teleopScoring, endgame,\n        driver, defense,\n        broke, brokeNotes: broke ? brokeNotes : \"\",\n        inconsistent, inconsistentNotes: inconsistent ? inconsistentNotes : \"\",\n        notes: finalNotes,\n      });\n      toast.success(`Qual ${data.matchNumber} · team ${data.teamNumber} ${saved || data.notes !== null ? \"updated\" : \"submitted\"}`);\n      void navigate(\"/scout\");\n    } catch (error) {\n      toast.error(\"Could not submit\", { description: error instanceof Error ? error.message : String(error) });\n    } finally {\n      setSaving(false);\n    }\n  };\n\n  const box = (id: string, label: string, value: string, set: (v: string) => void, placeholder: string) => (\n    <Textarea id={id} aria-label={label} rows={4} maxLength={2000} placeholder={placeholder}\n      value={value} onChange={(e) => set(e.target.value)} />\n  );\n\n  return (\n    <PageShell\n      title={\n        <>\n          Qual {data.matchNumber} · {data.teamNumber}\n          <Badge className={data.alliance === \"red\" ? \"bg-red-600 text-white\" : \"bg-blue-600 text-white\"}>\n            {data.alliance === \"red\" ? \"Red\" : \"Blue\"}\n          </Badge>\n        </>\n      }\n      description={\n        saved || data.notes !== null\n          ? `${data.nickname}. You have scouted this robot in this match already; saving replaces it.`\n          : data.nickname\n      }\n      actions={back}\n    >\n      <Tabs value={period} onValueChange={(v) => setPeriod(v as Period)}>\n        <TabsList id=\"match-form-tabs\" className=\"w-full scroll-mt-4\">\n          <TabsTrigger value=\"auto\" className=\"flex-1\">Auto</TabsTrigger>\n          <TabsTrigger value=\"teleop\" className=\"flex-1\">Teleop</TabsTrigger>\n          <TabsTrigger value=\"conclusion\" className=\"flex-1\">\n            Conclusion\n            {conclusionMissing ? <span aria-hidden className=\"bg-destructive ml-1.5 size-1.5 rounded-full\" /> : null}\n          </TabsTrigger>\n        </TabsList>\n\n        <TabsContent value=\"auto\" className=\"space-y-4 pt-4\">\n          <Card>\n            <CardHeader>\n              <CardTitle>Auto path</CardTitle>\n              <CardDescription>Where the robot started and where it went.</CardDescription>\n            </CardHeader>\n            <CardContent>\n              {box(\"auto-path\", \"Auto path\", autoPath, setAutoPath, \"e.g. Started left, drove to the centre line, came back to score\")}\n            </CardContent>\n          </Card>\n          <Card>\n            <CardHeader><CardTitle>Auto scoring</CardTitle></CardHeader>\n            <CardContent className=\"space-y-4\">\n              {box(\"auto-scoring\", \"Auto scoring\", autoScoring, setAutoScoring, \"What it scored in auto, and how much\")}\n              <Button variant=\"outline\" className=\"h-12 w-full\" onClick={() => goTo(\"teleop\")}>\n                Switch to Teleop\n                <ArrowRight className=\"size-4\" />\n              </Button>\n            </CardContent>\n          </Card>\n        </TabsContent>\n\n        <TabsContent value=\"teleop\" className=\"space-y-4 pt-4\">\n          <Card>\n            <CardHeader><CardTitle>Teleop scoring</CardTitle></CardHeader>\n            <CardContent className=\"space-y-4\">\n              {box(\"teleop-scoring\", \"Teleop scoring\", teleopScoring, setTeleopScoring, \"What it scored in teleop, how often, from where\")}\n              <Button variant=\"outline\" className=\"h-12 w-full\" onClick={() => goTo(\"conclusion\")}>\n                Switch to Conclusion\n                <ArrowRight className=\"size-4\" />\n              </Button>\n            </CardContent>\n          </Card>\n        </TabsContent>\n\n        <TabsContent value=\"conclusion\" className=\"space-y-4 pt-4\">\n          <Card>\n            <CardHeader><CardTitle>Endgame</CardTitle></CardHeader>\n            <CardContent>\n              {box(\"endgame\", \"Endgame\", endgame, setEndgame, \"What it did at the end of the match\")}\n            </CardContent>\n          </Card>\n\n          <Card>\n            <CardHeader><CardTitle>Ratings</CardTitle></CardHeader>\n            <CardContent className=\"space-y-6\">\n              <RatingScale label=\"Driver\" value={driver} onChange={setDriver} invalid={bad.driver} />\n              <RatingScale label=\"Defense\" value={defense} onChange={setDefense} invalid={bad.defense} />\n              <CapabilityCheck id=\"broke\" label=\"Robot broke down\" checked={broke} onChange={setBroke} />\n              {broke ? (\n                <Input placeholder=\"What happened?\" value={brokeNotes} maxLength={500}\n                  onChange={(e) => setBrokeNotes(e.target.value)} />\n              ) : null}\n              <CapabilityCheck id=\"inconsistent\" label=\"Robot was inconsistent\"\n                checked={inconsistent} onChange={setInconsistent} />\n              {inconsistent ? (\n                <Input placeholder=\"In what way?\" value={inconsistentNotes} maxLength={500}\n                  onChange={(e) => setInconsistentNotes(e.target.value)} />\n              ) : null}\n            </CardContent>\n          </Card>\n\n          <Card className={bad.finalNotes ? \"ring-destructive ring-2\" : \"\"}>\n            <CardHeader><CardTitle>Final notes</CardTitle></CardHeader>\n            <CardContent className=\"space-y-2\">\n              <p className=\"text-muted-foreground text-sm\">\n                Anything a strategy lead should know when they read this report\n                during alliance selection.\n              </p>\n              <Textarea placeholder=\"Overall impression of this robot\" rows={4} value={finalNotes}\n                aria-invalid={bad.finalNotes || undefined}\n                onChange={(e) => setFinalNotes(e.target.value)} />\n              {bad.finalNotes ? <p className=\"text-destructive text-xs\">Final notes are required.</p> : null}\n            </CardContent>\n          </Card>\n        </TabsContent>\n      </Tabs>\n\n      {missing.length > 0 ? (\n        <p className=\"text-muted-foreground rounded-lg border border-dashed p-3 text-sm\">\n          Still needed: {missing.join(\", \")}.\n        </p>\n      ) : null}\n      <Button className=\"h-14 w-full text-base\" disabled={saving} onClick={() => void submit()}>\n        {saving ? <LoadingWheel className=\"size-4\" /> : null}\n        {saved || data.notes !== null ? \"Save changes\" : \"Submit report\"}\n      </Button>\n    </PageShell>\n  );\n}\n"
 },
 {
  "file": "src/routes/notes/match.tsx",
  "old": "  notes: { id: string; scoutName: string; notes: string }[];",
  "new": "  notes: { id: string; scoutName: string; notes: string; sections: [string, string][] }[];"
 },
 {
  "file": "src/routes/notes/match.tsx",
  "old": "                <div key={n.id} className=\"space-y-0.5\">\n                  <p className=\"text-sm whitespace-pre-wrap\">{n.notes}</p>",
  "new": "                <div key={n.id} className=\"space-y-1\">\n                  {n.sections.length > 0 ? (\n                    <dl className=\"grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-0.5 text-sm\">\n                      {n.sections.map(([label, value]) => (\n                        <div key={label} className=\"contents\">\n                          <dt className=\"text-muted-foreground\">{label}</dt>\n                          <dd className=\"break-words whitespace-pre-wrap\">{value}</dd>\n                        </div>\n                      ))}\n                    </dl>\n                  ) : null}\n                  <p className=\"text-sm whitespace-pre-wrap\">{n.notes}</p>"
 },
 {
  "file": "src/routes/notes/team-detail.tsx",
  "old": "                      <p className=\"text-sm whitespace-pre-wrap\">{n.notes}</p>",
  "new": "                      {n.sections.length > 0 ? (\n                        <dl className=\"grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-0.5 text-sm\">\n                          {n.sections.map(([label, value]) => (\n                            <div key={label} className=\"contents\">\n                              <dt className=\"text-muted-foreground\">{label}</dt>\n                              <dd className=\"break-words whitespace-pre-wrap\">{value}</dd>\n                            </div>\n                          ))}\n                        </dl>\n                      ) : null}\n                      <p className=\"text-sm whitespace-pre-wrap\">{n.notes}</p>"
 },
 {
  "file": "src/components/practice-card.tsx",
  "old": "  if (row.kind === \"matchNote\") {\n    add(\"Notes\", strAt(p.notes) || \"(empty)\");\n    return out;\n  }",
  "new": "  if (row.kind === \"matchNote\") {\n    // The match form for seasons without their own forms (or an older plain note).\n    add(\"Auto path\", strAt(p.autoPath));\n    add(\"Auto scoring\", strAt(p.autoScoring));\n    add(\"Teleop scoring\", strAt(p.teleopScoring));\n    add(\"Endgame\", strAt(p.endgame));\n    add(\"Driver\", numAt(p.driver));\n    add(\"Defense\", numAt(p.defense));\n    if (yes(p.broke)) add(\"Broke down\", strAt(p.brokeNotes) || \"Yes\");\n    if (yes(p.inconsistent)) add(\"Inconsistent\", strAt(p.inconsistentNotes) || \"Yes\");\n    add(\"Final notes\", strAt(p.notes) || \"(empty)\");\n    return out;\n  }"
 },
 {
  "file": "src/components/practice-card.tsx",
  "old": "    case \"matchNote\": return `Match note · Qual ${row.matchNumber ?? \"?\"} · ${row.teamNumber}`;",
  "new": "    case \"matchNote\": return `Qual ${row.matchNumber ?? \"?\"} · ${row.teamNumber}`;"
 }
]
PATCH_EDITS_JSON

cat > "$MJS_FILE" <<'MJS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const edits = JSON.parse(readFileSync(process.argv[2], "utf8"));
const files = new Map(); // path -> { text, crlf }
const fail = (msg) => { console.error(`ERROR: ${msg}\nNothing was changed.`); process.exit(1); };

for (const { file, old, new: next } of edits) {
  if (old === null) {
    if (existsSync(file)) fail(`${file} already exists.`);
    files.set(file, { text: next, crlf: false });
    continue;
  }
  if (!files.has(file)) {
    if (!existsSync(file)) fail(`${file} is missing.`);
    const raw = readFileSync(file, "utf8");
    files.set(file, { text: raw.replace(/\r\n/g, "\n"), crlf: raw.includes("\r\n") });
  }
  const entry = files.get(file);
  const first = entry.text.indexOf(old);
  if (first === -1 || entry.text.indexOf(old, first + 1) !== -1) {
    fail(`${file} does not look like the expected version. Could not place this edit ` +
      `(${first === -1 ? "not found" : "found twice"}):\n` + old.split("\n").slice(0, 4).join("\n"));
  }
  entry.text = entry.text.slice(0, first) + next + entry.text.slice(first + old.length);
}

for (const [file, { text, crlf }] of files) {
  writeFileSync(file, crlf ? text.replace(/\n/g, "\r\n") : text);
  console.log(`${file} written`);
}
MJS
bun "$MJS_FILE" "$JSON_FILE"

say "Done"
cat <<'TXT'
Next:
  1. bun run go        (adds the new matchNotes fields)
  2. bun run typecheck
  3. With an event from a season without forms active, open Match Scouting.
TXT
