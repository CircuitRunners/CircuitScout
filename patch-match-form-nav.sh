#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-match-form-nav.sh
#   1. "Switch to Conclusion" button at the bottom of Teleop, like the
#      "Switch to Teleop" button at the bottom of Auto
#   2. Submitting with required fields empty outlines them in red, the way
#      pit scouting does: start position, auto winner, the three ratings,
#      final notes, and the edit reason. The form jumps to the first tab with
#      something missing, and those tabs get a red dot.
#
# Submit is no longer greyed out for missing fields, so pressing it can show
# what is missing. The mid-match and dead-hub warnings still block it as
# before. No schema change; independent of the other patches.
#
# Every edit is checked before any file is written, so a mismatch stops the
# patch with nothing half-applied. CRLF checkouts are handled.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/pit.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

if grep -qF 'goToConclusion' src/routes/scout/form.tsx; then
  echo "patch-match-form-nav already applied."
  exit 0
fi
if ! grep -qF 'defineSchema' convex/schema.ts; then
  echo "ERROR: unexpected repo layout." >&2
  exit 1
fi

# Working files live in the repo root, not /tmp: on Windows, Git Bash's /tmp
# is not where bun looks for a "/tmp/..." path written inside a script.
JSON_FILE=".patch-match-form-nav.json"
MJS_FILE=".patch-match-form-nav.mjs"
trap 'rm -f "$JSON_FILE" "$MJS_FILE"' EXIT

say "Applying patch-match-form-nav"
cat > "$JSON_FILE" <<'PATCH_EDITS_JSON'
[
 {
  "file": "src/components/scouting/rating-scale.tsx",
  "old": "  unit = \"\",\n  values,\n}: {",
  "new": "  unit = \"\",\n  values,\n  invalid = false,\n}: {"
 },
 {
  "file": "src/components/scouting/rating-scale.tsx",
  "old": "  values?: ReadonlyArray<number>;\n}) {",
  "new": "  values?: ReadonlyArray<number>;\n  /** Outlined in red: required and still not set when the scout tried to submit. */\n  invalid?: boolean;\n}) {"
 },
 {
  "file": "src/components/scouting/rating-scale.tsx",
  "old": "    <div className=\"space-y-3\">\n      <div className=\"flex items-baseline justify-between\">\n        <span className=\"text-sm font-medium\">{label}</span>\n        <span className=\"text-2xl font-semibold tabular-nums\">\n          {value === null ? (\n            <span className=\"text-muted-foreground text-base font-normal\">\n              Not set\n            </span>",
  "new": "    <div className={[\n      \"space-y-3\",\n      // An outline with an offset, so the slider does not move when it appears.\n      invalid ? \"outline-destructive rounded-lg outline outline-offset-8\" : \"\",\n    ].join(\" \")}>\n      <div className=\"flex items-baseline justify-between\">\n        <span className={[\"text-sm font-medium\", invalid ? \"text-destructive\" : \"\"].join(\" \")}>\n          {label}\n        </span>\n        <span className=\"text-2xl font-semibold tabular-nums\">\n          {value === null ? (\n            <span className={[\n              \"text-base font-normal\",\n              invalid ? \"text-destructive\" : \"text-muted-foreground\",\n            ].join(\" \")}>\n              Not set\n            </span>"
 },
 {
  "file": "src/routes/scout/form.tsx",
  "old": "  const [earlyAck, setEarlyAck] = useState(false);",
  "new": "  const [earlyAck, setEarlyAck] = useState(false);\n  // Missing fields are outlined once someone tries to submit, not while they\n  // are still working through the match.\n  const [showErrors, setShowErrors] = useState(false);"
 },
 {
  "file": "src/routes/scout/form.tsx",
  "old": "  const goToTeleop = () => {\n    setPeriod(\"teleop\");\n    // The winner card sits at the bottom of Auto; land at the top of Teleop.\n    document.getElementById(\"match-form-tabs\")\n      ?.scrollIntoView({ block: \"start\", behavior: \"smooth\" });\n  };",
  "new": "  const goTo = (next: typeof period) => {\n    setPeriod(next);\n    // The switch buttons sit at the bottom of a tab; land at the top of the next.\n    document.getElementById(\"match-form-tabs\")\n      ?.scrollIntoView({ block: \"start\", behavior: \"smooth\" });\n  };\n  const goToTeleop = () => goTo(\"teleop\");\n  const goToConclusion = () => goTo(\"conclusion\");"
 },
 {
  "file": "src/routes/scout/form.tsx",
  "old": "  if (editId && editReason.trim() === \"\") missing.push(\"a reason for this edit\");\n",
  "new": "  if (editId && editReason.trim() === \"\") missing.push(\"a reason for this edit\");\n\n  // Which fields to outline, and which tabs hold them.\n  const bad = {\n    start: showErrors && start === null,\n    autoWinner: showErrors && autoWinner === null,\n    driver: showErrors && driver === null,\n    defense: showErrors && defense === null,\n    accuracy: showErrors && accuracy === null,\n    finalNotes: showErrors && finalNotes.trim() === \"\",\n    editReason: showErrors && Boolean(editId) && editReason.trim() === \"\",\n  };\n  const autoMissing = bad.start || bad.autoWinner;\n  const conclusionMissing = bad.driver || bad.defense || bad.accuracy || bad.finalNotes;\n"
 },
 {
  "file": "src/routes/scout/form.tsx",
  "old": "  const save = async () => {\n    if (!data?.match || !data.team) return;\n    setSaving(true);",
  "new": "  const save = async () => {\n    if (!data?.match || !data.team) return;\n    if (missing.length > 0) {\n      setShowErrors(true);\n      // Open the first tab with a gap; the edit reason sits below the tabs.\n      if (start === null || autoWinner === null) goTo(\"auto\");\n      else if (driver === null || defense === null || accuracy === null || finalNotes.trim() === \"\") {\n        goTo(\"conclusion\");\n      }\n      toast.error(\"Some required fields are empty\", {\n        description: \"What needs filling in is outlined in red.\",\n      });\n      return;\n    }\n    setSaving(true);"
 },
 {
  "file": "src/routes/scout/form.tsx",
  "old": "          <TabsTrigger value=\"auto\" className=\"flex-1\">Auto</TabsTrigger>\n          <TabsTrigger value=\"teleop\" className=\"flex-1\">Teleop</TabsTrigger>\n          <TabsTrigger value=\"conclusion\" className=\"flex-1\">Conclusion</TabsTrigger>",
  "new": "          <TabsTrigger value=\"auto\" className=\"flex-1\">\n            Auto\n            {autoMissing ? <span aria-hidden className=\"bg-destructive ml-1.5 size-1.5 rounded-full\" /> : null}\n          </TabsTrigger>\n          <TabsTrigger value=\"teleop\" className=\"flex-1\">Teleop</TabsTrigger>\n          <TabsTrigger value=\"conclusion\" className=\"flex-1\">\n            Conclusion\n            {conclusionMissing ? <span aria-hidden className=\"bg-destructive ml-1.5 size-1.5 rounded-full\" /> : null}\n          </TabsTrigger>"
 },
 {
  "file": "src/routes/scout/form.tsx",
  "old": "          <AutoPathEditor\n            alliance={data.alliance === \"red\" ? \"red\" : \"blue\"}\n            start={start}\n            onStartChange={setStart}\n            steps={steps}\n            onStepsChange={setSteps}\n          />",
  "new": "          <div className={bad.start ? \"ring-destructive space-y-2 rounded-xl ring-2\" : \"\"}>\n            <AutoPathEditor\n              alliance={data.alliance === \"red\" ? \"red\" : \"blue\"}\n              start={start}\n              onStartChange={setStart}\n              steps={steps}\n              onStepsChange={setSteps}\n            />\n            {bad.start ? (\n              <p className=\"text-destructive px-4 pb-3 text-xs\">Pick where the robot started.</p>\n            ) : null}\n          </div>"
 },
 {
  "file": "src/routes/scout/form.tsx",
  "old": "          <Card>\n            <CardHeader><CardTitle>Which alliance won auto?</CardTitle></CardHeader>",
  "new": "          <Card className={bad.autoWinner ? \"ring-destructive ring-2\" : \"\"}>\n            <CardHeader><CardTitle>Which alliance won auto?</CardTitle></CardHeader>"
 },
 {
  "file": "src/routes/scout/form.tsx",
  "old": "                value={autoWinner}\n                onChange={setAutoWinner}\n              />",
  "new": "                value={autoWinner}\n                onChange={setAutoWinner}\n              />\n              {bad.autoWinner ? (\n                <p className=\"text-destructive text-xs\">Pick the alliance that scored more auto fuel.</p>\n              ) : null}"
 },
 {
  "file": "src/routes/scout/form.tsx",
  "old": "              <Textarea placeholder=\"Teleop notes\" rows={2}\n                value={teleopNotes} onChange={(e) => setTeleopNotes(e.target.value)} />\n            </CardContent>",
  "new": "              <Textarea placeholder=\"Teleop notes\" rows={2}\n                value={teleopNotes} onChange={(e) => setTeleopNotes(e.target.value)} />\n              <Button variant=\"outline\" className=\"h-12 w-full\" onClick={goToConclusion}>\n                Switch to Conclusion\n                <ArrowRight className=\"size-4\" />\n              </Button>\n            </CardContent>"
 },
 {
  "file": "src/routes/scout/form.tsx",
  "old": "          <RatingScale label=\"Driver\" value={driver} onChange={setDriver} />\n          <RatingScale label=\"Defense\" value={defense} onChange={setDefense} />\n          <RatingScale\n            label=\"Shooting accuracy\"\n            value={accuracy}\n            onChange={setAccuracy}",
  "new": "          <RatingScale label=\"Driver\" value={driver} onChange={setDriver}\n            invalid={bad.driver} />\n          <RatingScale label=\"Defense\" value={defense} onChange={setDefense}\n            invalid={bad.defense} />\n          <RatingScale\n            label=\"Shooting accuracy\"\n            value={accuracy}\n            onChange={setAccuracy}\n            invalid={bad.accuracy}"
 },
 {
  "file": "src/routes/scout/form.tsx",
  "old": "          <Card>\n            <CardHeader><CardTitle>Final notes</CardTitle></CardHeader>",
  "new": "          <Card className={bad.finalNotes ? \"ring-destructive ring-2\" : \"\"}>\n            <CardHeader><CardTitle>Final notes</CardTitle></CardHeader>"
 },
 {
  "file": "src/routes/scout/form.tsx",
  "old": "                value={finalNotes}\n                onChange={(e) => setFinalNotes(e.target.value)}\n              />",
  "new": "                value={finalNotes}\n                aria-invalid={bad.finalNotes || undefined}\n                onChange={(e) => setFinalNotes(e.target.value)}\n              />\n              {bad.finalNotes ? (\n                <p className=\"text-destructive text-xs\">Final notes are required.</p>\n              ) : null}"
 },
 {
  "file": "src/routes/scout/form.tsx",
  "old": "              placeholder=\"Reason (required)\"\n              value={editReason}",
  "new": "              placeholder=\"Reason (required)\"\n              value={editReason}\n              aria-invalid={bad.editReason || undefined}"
 },
 {
  "file": "src/routes/scout/form.tsx",
  "old": "        disabled={\n          saving ||\n          missing.length > 0 ||\n          (suspicious && !override) ||",
  "new": "        disabled={\n          saving ||\n          (suspicious && !override) ||"
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
  1. bun run typecheck
  2. Open a match, press Submit with nothing filled in, and check the
     outlines; then use Switch to Conclusion at the bottom of Teleop.
TXT
