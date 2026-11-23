#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-offline-forms.sh — offline plan, patch 4 of 5: offline forms
#   1. Any match form and the robots in any match open offline, rebuilt from
#      the saved schedule and team list (src/lib/offline/derive.ts). A form
#      that was opened before uses its own saved copy.
#   2. Pit forms open offline for teams nobody has scouted. A team that
#      already has a pit report opens only if that form was viewed on this
#      device; otherwise it says "Already scouted. Connect to edit it."
#      pit.upsert patches the existing report, so a blank form saved from
#      here would overwrite real answers.
#   3. The same for seasons without their own forms (notes.* queries).
#   4. Submitting is NOT changed: the Convex client holds a report in memory
#      and sends it when the connection returns, but only while the app stays
#      open. This patch says so: the button reads "Submit when back online",
#      a "Held on this device" notice stays up, and the browser warns before
#      the tab is closed. Photos are disabled offline.
#   5. Dashboard: an "Offline ready" line with the time the lists were saved,
#      and a hint to install the app.
#
# Online nothing changes, and no Convex call is added: offline pages read the
# saved lists with useCachedOnly, which never subscribes.
#
# Requires patch-offline-store.sh and patch-offline-login.sh (patches 2, 3).
# No Convex change, no schema change, no new dependency. Safe to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f vite.config.ts && -f convex/auth.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
[[ -f src/lib/offline/store.ts && -f src/components/needs-connection.tsx ]] || {
  echo "ERROR: run patch-offline-store.sh and patch-offline-login.sh (patches 2 and 3) first; nothing was changed" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# ---- 1. Check every anchor before writing anything ------------------------
say "Checking anchors"
trap 'rm -f .patch-offline-forms.mjs' EXIT
cat > .patch-offline-forms.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";

const mode = process.argv[2]; // "check" | "write"
const plan = [];
const read = (path) => readFileSync(path, "utf8").replace(/\r\n/g, "\n");

/**
 * Skip when `marker` is present; otherwise every anchor must appear exactly
 * once. With `dropUseQuery`, useQuery leaves the convex/react import when the
 * edits removed its last use.
 */
function edit(path, marker, pairs, { dropUseQuery = false } = {}) {
  let source = read(path);
  if (source.includes(marker)) return plan.push({ path, skip: true });
  for (const [anchor] of pairs) {
    const count = source.split(anchor).length - 1;
    if (count !== 1) throw new Error(`${path}: expected anchor once, found ${count}:\n  ${anchor}`);
  }
  for (const [anchor, replacement] of pairs) source = source.replace(anchor, replacement);
  if (dropUseQuery && !/\buseQuery\(/.test(source)) {
    const importLine = /^import \{([^}]*)\} from "convex\/react";\n/m;
    const match = source.match(importLine);
    if (!match) throw new Error(`${path}: no convex/react import found`);
    const names = match[1].split(",").map((n) => n.trim()).filter((n) => n && n !== "useQuery");
    source = source.replace(
      importLine,
      names.length ? `import { ${names.join(", ")} } from "convex/react";\n` : "",
    );
  }
  plan.push({ path, skip: false, next: source });
}

const NEEDS = (title, description) =>
  `<NeedsConnection title="${title}" description="${description}" />`;

// ---- store.ts: tell the UI when something was saved -------------------------
edit("src/lib/offline/store.ts", "subscribeSaved", [
  [
    "function scheduleFlush() {\n",
    `// For UI that shows whether data is on the device (the Offline ready line).
// Separate from the epoch on purpose: hooks re-save on an epoch change, so
// bumping the epoch on every save would loop.
let tick = 0;
const savedListeners = new Set<() => void>();
export function subscribeSaved(listener: () => void): () => void {
  savedListeners.add(listener);
  return () => savedListeners.delete(listener);
}
export const savedTick = (): number => tick;

function scheduleFlush() {
`,
  ],
  [
    "  if (rows.length === 0) return;\n  write([QUERIES], (tx) => {\n",
    "  if (rows.length === 0) return;\n  tick += 1;\n  for (const listener of savedListeners) listener();\n  write([QUERIES], (tx) => {\n",
  ],
]);

// ---- Robot picker on the two Match Scouting landings -------------------------
const HOOK_IMPORT = 'import { useCachedQuery } from "@/lib/offline/use-cached-query";\n';
function robotPicker(path) {
  edit(path, "useMatchRobots", [
    [
      HOOK_IMPORT,
      'import { useMatchRobots } from "@/lib/offline/forms";\nimport { useOnline } from "@/lib/offline/status";\n' + HOOK_IMPORT,
    ],
    [
      "  const data = useQuery(api.matches.teamsInMatch, { matchNumber });\n",
      "  // Offline: the saved copy, or rebuilt from the saved schedule and team list.\n  const data = useMatchRobots(matchNumber);\n  const online = useOnline();\n",
    ],
    [
      '    return <p className="text-muted-foreground p-3 text-sm">Loading…</p>;\n',
      `    return (
      <p className="text-muted-foreground p-3 text-sm">
        {data === undefined && !online
          ? "Not saved on this device. Open the Dashboard once while online."
          : "Loading…"}
      </p>
    );
`,
    ],
    [
      '                <Badge\n                  variant={count === 0 ? "outline" : mine ? "secondary" : "default"}\n',
      '                {/* Counts are live only: offline a 0 would be a guess. */}\n                {counts === undefined && !online ? null : (\n                <Badge\n                  variant={count === 0 ? "outline" : mine ? "secondary" : "default"}\n',
    ],
    [
      '                  {mine ? " ✓" : ""}\n                </Badge>\n',
      '                  {mine ? " ✓" : ""}\n                </Badge>\n                )}\n',
    ],
    [
      '      <p className="text-muted-foreground text-xs">\n        The number is how many scouts have ',
      `      {counts === undefined && !online ? (
        <p className="text-muted-foreground text-xs">Report counts are not shown offline.</p>
      ) : null}
      <p className="text-muted-foreground text-xs">
        The number is how many scouts have `,
    ],
  ]);
}
robotPicker("src/routes/scout/index.tsx");
robotPicker("src/routes/notes/scout.tsx");

// ---- 2026 match form ----------------------------------------------------------
edit("src/routes/scout/form.tsx", "useMatchFormData", [
  [
    'import { LoadingWheel } from "@/components/loading-wheel";\n',
    `import { LoadingWheel } from "@/components/loading-wheel";
import { HeldNotice } from "@/components/held-notice";
import { NeedsConnection } from "@/components/needs-connection";
import { useMatchFormData } from "@/lib/offline/forms";
import { useOnline } from "@/lib/offline/status";
`,
  ],
  [
    `  const data = useQuery(
    api.matchReports.forMatchAndTeam,
    valid ? { matchNumber, teamNumber } : "skip",
  );
`,
    `  // Online this is matchReports.forMatchAndTeam, unchanged. Offline it is the
  // saved copy, or the same shape rebuilt from the saved schedule and team list.
  const { data, unavailable } = useMatchFormData(matchNumber, teamNumber, valid);
  const online = useOnline();
`,
  ],
  [
    '  if (data === undefined) return <PageShell title="Match Scouting" description="Loading…" />;\n',
    `  if (editId && !online && editing === undefined) {
    return (
      <PageShell title="Match Scouting">
        ${NEEDS("Needs a connection", "Editing a submitted report needs a connection.")}
      </PageShell>
    );
  }
  if (data === undefined && unavailable) {
    return (
      <PageShell title="Match Scouting">
        ${NEEDS("Not saved on this device", "Open the Dashboard once while online, and this form will open offline.")}
      </PageShell>
    );
  }
  if (data === undefined) return <PageShell title="Match Scouting" description="Loading…" />;
`,
  ],
  [
    '      <Button\n        className="h-14 w-full text-base"\n        disabled={\n          saving ||\n',
    '      <HeldNotice saving={saving} />\n      <Button\n        className="h-14 w-full text-base"\n        disabled={\n          saving ||\n',
  ],
  [
    '        {editId ? "Save changes" : "Submit report"}\n',
    '        {editId ? "Save changes" : online ? "Submit report" : "Submit when back online"}\n',
  ],
]);

// ---- 2026 pit form ------------------------------------------------------------
edit("src/routes/pit/form.tsx", "usePitFormData", [
  [
    'import { compressImage } from "@/lib/compress-image";\n',
    `import { compressImage } from "@/lib/compress-image";
import { HeldNotice } from "@/components/held-notice";
import { NeedsConnection } from "@/components/needs-connection";
import { usePitFormData } from "@/lib/offline/forms";
import { useOnline } from "@/lib/offline/status";
`,
  ],
  [
    `  const data = useQuery(
    api.pit.forTeamNumber,
    Number.isNaN(teamNumber) ? "skip" : { teamNumber },
  );
`,
    `  // Online this is pit.forTeamNumber, unchanged. Offline it is the saved copy,
  // or a blank form for a team the saved list says nobody has scouted.
  const { data, unavailable, blocked } = usePitFormData(teamNumber);
  const online = useOnline();
`,
  ],
  [
    `  if (data === undefined) {
    return <PageShell title="Pit Scouting" description="Loading…" />;
  }
`,
    `  if (blocked || (data === undefined && unavailable)) {
    return (
      <PageShell
        title="Pit Scouting"
        actions={
          <Button variant="outline" onClick={() => void navigate("/pit")}>
            <ArrowLeft className="size-4" />
            Back
          </Button>
        }
      >
        {blocked ? (
          // pit.upsert patches the existing report: a blank form saved from
          // here would overwrite answers this device does not have.
          ${NEEDS("Already scouted", `Team \${teamNumber} has a pit report that is not saved on this device. Connect to edit it.`).replace('description="', "description={`").replace('." />', ".`} />")}
        ) : (
          ${NEEDS("Not saved on this device", "Open the Dashboard once while online, and this form will open offline.")}
        )}
      </PageShell>
    );
  }
  if (data === undefined) {
    return <PageShell title="Pit Scouting" description="Loading…" />;
  }
`,
  ],
  [
    "  const existingPhoto = photoPreview ?? data.photoUrl;\n",
    "  // A saved photo lives on the server and cannot be shown offline.\n  const existingPhoto = photoPreview ?? (online ? data.photoUrl : null);\n",
  ],
  [
    `          <Button variant="outline" className="h-12 w-full"
            onClick={() => fileInput.current?.click()}>
            <Camera className="size-4" />
            {existingPhoto ? "Replace photo" : "Take photo"}
          </Button>
`,
    `          <Button variant="outline" className="h-12 w-full" disabled={!online}
            onClick={() => fileInput.current?.click()}>
            <Camera className="size-4" />
            {existingPhoto ? "Replace photo" : "Take photo"}
          </Button>
          {online ? null : (
            <p className="text-muted-foreground text-xs">
              Photos need a connection. Save the rest now and add the photo when you are back online.
              {data.photoUrl ? " The saved photo is not shown offline." : ""}
            </p>
          )}
`,
  ],
  [
    '      <Button className="h-14 w-full text-base" disabled={saving}\n        onClick={() => void save()}>\n',
    '      <HeldNotice saving={saving} />\n      <Button className="h-14 w-full text-base" disabled={saving}\n        onClick={() => void save()}>\n',
  ],
  [
    '        {data.report ? "Update report" : "Submit report"}\n',
    '        {!online ? "Save when back online" : data.report ? "Update report" : "Submit report"}\n',
  ],
], { dropUseQuery: true });

// ---- Other seasons: match form -----------------------------------------------
edit("src/routes/notes/scout-form.tsx", "useNoteMatchFormData", [
  [
    'import { LoadingWheel } from "@/components/loading-wheel";\n',
    `import { LoadingWheel } from "@/components/loading-wheel";
import { HeldNotice } from "@/components/held-notice";
import { NeedsConnection } from "@/components/needs-connection";
import { useNoteMatchFormData } from "@/lib/offline/forms";
import { useOnline } from "@/lib/offline/status";
`,
  ],
  [
    '  const data = useQuery(api.notes.matchNote, bad ? "skip" : { matchNumber, teamNumber });\n',
    "  // Online this is notes.matchNote, unchanged. Offline: the saved copy, or rebuilt from the saved lists.\n  const { data, unavailable, blocked } = useNoteMatchFormData(matchNumber, teamNumber, !bad);\n",
  ],
  [
    '  if (data === undefined) return <PageShell title="Match Scouting" description="Loading…" actions={back} />;\n',
    `  if (blocked) {
    // notes.saveMatchReport replaces the earlier report: a blank form saved
    // from here would overwrite one this device does not have.
    return (
      <PageShell title="Match Scouting" actions={back}>
        ${NEEDS("Already scouted", "Your earlier report on this robot is not saved on this device. Connect to edit it.")}
      </PageShell>
    );
  }
  if (data === undefined && unavailable) {
    return (
      <PageShell title="Match Scouting" actions={back}>
        ${NEEDS("Not saved on this device", "Open Match Scouting once while online, and this form will open offline.")}
      </PageShell>
    );
  }
  if (data === undefined) return <PageShell title="Match Scouting" description="Loading…" actions={back} />;
`,
  ],
  [
    "  const navigate = useNavigate();\n  const save = useMutation(api.notes.saveMatchReport);\n",
    "  const navigate = useNavigate();\n  const online = useOnline();\n  const save = useMutation(api.notes.saveMatchReport);\n",
  ],
  [
    '      <Button className="h-14 w-full text-base" disabled={saving} onClick={() => void submit()}>\n        {saving ? <LoadingWheel className="size-4" /> : null}\n        {saved || data.notes !== null ? "Save changes" : "Submit report"}\n',
    '      <HeldNotice saving={saving} />\n      <Button className="h-14 w-full text-base" disabled={saving} onClick={() => void submit()}>\n        {saving ? <LoadingWheel className="size-4" /> : null}\n        {!online ? "Submit when back online" : saved || data.notes !== null ? "Save changes" : "Submit report"}\n',
  ],
], { dropUseQuery: true });

// ---- Other seasons: pit form -------------------------------------------------
edit("src/routes/notes/pit-form.tsx", "useNotePitFormData", [
  [
    'import { LoadingWheel } from "@/components/loading-wheel";\n',
    `import { LoadingWheel } from "@/components/loading-wheel";
import { HeldNotice } from "@/components/held-notice";
import { NeedsConnection } from "@/components/needs-connection";
import { useNotePitFormData } from "@/lib/offline/forms";
import { useOnline } from "@/lib/offline/status";
`,
  ],
  [
    '  const data = useQuery(api.notes.pitNote, Number.isNaN(teamNumber) ? "skip" : { teamNumber });\n',
    "  // Online this is notes.pitNote, unchanged. Offline: the saved copy, or a\n  // blank form for a team the saved list says nobody has scouted.\n  const { data, unavailable, blocked } = useNotePitFormData(teamNumber);\n",
  ],
  [
    '  if (data === undefined) return <PageShell title="Pit Scouting" description="Loading…" actions={back} />;\n',
    `  if (blocked) {
    // notes.savePitReport patches the existing report: a blank form saved
    // from here would overwrite answers this device does not have.
    return (
      <PageShell title="Pit Scouting" actions={back}>
        ${NEEDS("Already scouted", "This team has a pit report that is not saved on this device. Connect to edit it.")}
      </PageShell>
    );
  }
  if (data === undefined && unavailable) {
    return (
      <PageShell title="Pit Scouting" actions={back}>
        ${NEEDS("Not saved on this device", "Open Pit Scouting once while online, and this form will open offline.")}
      </PageShell>
    );
  }
  if (data === undefined) return <PageShell title="Pit Scouting" description="Loading…" actions={back} />;
`,
  ],
  [
    "  const navigate = useNavigate();\n  const teamNumber = data.teamNumber;\n",
    "  const navigate = useNavigate();\n  const online = useOnline();\n  const teamNumber = data.teamNumber;\n",
  ],
  [
    "  const photo = photoPreview ?? data.photoUrl;\n",
    "  // A saved photo lives on the server and cannot be shown offline.\n  const photo = photoPreview ?? (online ? data.photoUrl : null);\n",
  ],
  [
    `          <Button variant="outline" className="h-12 w-full" onClick={() => fileInput.current?.click()}>
            <Camera className="size-4" /> {photo ? "Replace photo" : "Take photo"}
          </Button>
`,
    `          <Button variant="outline" className="h-12 w-full" disabled={!online} onClick={() => fileInput.current?.click()}>
            <Camera className="size-4" /> {photo ? "Replace photo" : "Take photo"}
          </Button>
          {online ? null : (
            <p className="text-muted-foreground text-xs">
              Photos need a connection. Save the rest now and add the photo when you are back online.
              {data.photoUrl ? " The saved photo is not shown offline." : ""}
            </p>
          )}
`,
  ],
  [
    '      <Button className="h-14 w-full text-base" disabled={saving} onClick={() => void submit()}>\n        {saving ? <LoadingWheel className="size-4" /> : null}\n        {saved && saved.status !== "none" ? "Update report" : "Submit report"}\n',
    '      <HeldNotice saving={saving} />\n      <Button className="h-14 w-full text-base" disabled={saving} onClick={() => void submit()}>\n        {saving ? <LoadingWheel className="size-4" /> : null}\n        {!online ? "Save when back online" : saved && saved.status !== "none" ? "Update report" : "Submit report"}\n',
  ],
], { dropUseQuery: true });

// ---- Dashboards: the Offline ready line ---------------------------------------
edit("src/routes/dashboard.tsx", "OfflineReady", [
  [HOOK_IMPORT, 'import { OfflineReady } from "@/components/offline-ready";\n' + HOOK_IMPORT],
  [
    "      {assignments?.upNext ? (\n",
    `      <OfflineReady
        lists={[
          { fn: "events:active", missing: "Waiting for the event." },
          { fn: "matches:listForEvent", missing: "Waiting for the match schedule." },
          { fn: "teams:listWithStatus", missing: "Waiting for the team list." },
        ]}
      />
      {assignments?.upNext ? (
`,
  ],
]);
edit("src/routes/notes/dashboard.tsx", "OfflineReady", [
  [HOOK_IMPORT, 'import { OfflineReady } from "@/components/offline-ready";\n' + HOOK_IMPORT],
  [
    "      {assignments?.upNext ? (\n",
    `      <OfflineReady
        lists={[
          { fn: "events:active", missing: "Waiting for the event." },
          { fn: "matches:listForEvent", missing: "Waiting for the match schedule." },
          // This dashboard does not load the team list; Pit Scouting does.
          { fn: "notes:teams", missing: "Open Pit Scouting once to save the team list." },
        ]}
      />
      {assignments?.upNext ? (
`,
  ],
]);

for (const e of plan) {
  if (e.skip) console.log(`  already patched  ${e.path}`);
  else if (mode === "write") {
    writeFileSync(e.path, e.next);
    console.log(`  patched          ${e.path}`);
  } else console.log(`  ok               ${e.path}`);
}
MJS
bun .patch-offline-forms.mjs check || { echo "ERROR: nothing was changed" >&2; exit 1; }

# ---- 2. New files ----------------------------------------------------------
say "Derive helpers, form hooks, held notice, offline ready"
cat > src/lib/offline/use-cached-only.ts <<'EOF_FILE'
import {
  getFunctionName, type FunctionReference, type FunctionReturnType, type OptionalRestArgs,
} from "convex/server";
import { useEffect, useSyncExternalStore } from "react";

import { useOnline } from "./status";
import { cacheKey, markServed, readCached, storeEpoch, subscribeStore } from "./store";

/**
 * The saved copy of a query, and only while offline. Never subscribes and
 * never calls Convex, so using it costs nothing. Online it returns undefined.
 *
 * For building an offline page out of lists some OTHER page keeps saved (the
 * schedule and the team list). To read a page's own query, use
 * useCachedQuery instead.
 */
export function useCachedOnly<Query extends FunctionReference<"query">>(
  query: Query,
  ...args: OptionalRestArgs<Query>
): FunctionReturnType<Query> | undefined {
  const online = useOnline();
  // Re-read when the store has dropped rows (new user, new event).
  useSyncExternalStore(subscribeStore, storeEpoch);

  const key = online ? null : cacheKey(getFunctionName(query), args[0]);
  const cached = key === null ? undefined : readCached(key);
  const servedAt = cached?.savedAt;
  useEffect(() => {
    if (servedAt === undefined) return;
    return markServed(servedAt);
  }, [servedAt]);

  return cached?.result as FunctionReturnType<Query> | undefined;
}
EOF_FILE
echo "  wrote            src/lib/offline/use-cached-only.ts"
cat > src/lib/offline/derive.ts <<'EOF_FILE'
import type { FunctionReturnType } from "convex/server";

import type { api } from "../../../convex/_generated/api";

/**
 * Rebuilds, from the saved lists, what a per-match or per-team query would
 * have returned (offline plan, section 7). Pure functions, mirrored on the
 * Convex handlers named in each comment: if one of those handlers changes
 * what it returns, change its twin here in the same patch.
 *
 * Each returns:
 *   the data      the form can open
 *   null          the match or team is not at the active event (as the server says)
 *   "blocked"     it exists, but opening a blank form would overwrite saved
 *                 answers that are not on this device
 */

type Matches = FunctionReturnType<typeof api.matches.listForEvent>;
type Teams = FunctionReturnType<typeof api.teams.listWithStatus>;
type MyReports = FunctionReturnType<typeof api.matchReports.mine>;
type NoteTeams = NonNullable<FunctionReturnType<typeof api.notes.teams>>;
type MyNotes = FunctionReturnType<typeof api.notes.mine>;

export type MatchForm = NonNullable<FunctionReturnType<typeof api.matchReports.forMatchAndTeam>>;
export type PitForm = NonNullable<FunctionReturnType<typeof api.pit.forTeamNumber>>;
export type NoteMatchForm = NonNullable<FunctionReturnType<typeof api.notes.matchNote>>;
export type NotePitForm = NonNullable<FunctionReturnType<typeof api.notes.pitNote>>;

/** The part of a team the robot picker needs. */
export type Robot = { _id: string; number: number; nickname: string };
export type MatchRobots = { red: Array<Robot | null>; blue: Array<Robot | null> };

/**
 * matches.teamsInMatch. With a team list, a number missing from it is an
 * unknown team, as on the server. With no team list at all the numbers on
 * the schedule are still enough to open a form, so they are used as they are.
 */
export function deriveRobots(
  matches: Matches,
  teams: ReadonlyArray<Robot> | undefined,
  matchNumber: number,
): MatchRobots | null {
  const match = matches.find((m) => m.matchNumber === matchNumber);
  if (!match) return null;
  const robot = (number: number): Robot | null =>
    teams === undefined
      ? { _id: `team-${number}`, number, nickname: "" }
      : (teams.find((t) => t.number === number) ?? null);
  return { red: match.redTeamNumbers.map(robot), blue: match.blueTeamNumbers.map(robot) };
}

/**
 * matchReports.forMatchAndTeam.
 * - othersCount cannot be known offline; 0 makes the form leave the
 *   "other reports already submitted" line out.
 * - hopper comes from this scouting team's pit report, which the lists do not
 *   carry; pass the one from the last time this form was open, or null.
 */
export function deriveMatchForm(input: {
  matches: Matches;
  teams: Teams;
  myReports: MyReports | undefined;
  practicing: boolean;
  hopper: MatchForm["hopper"];
  matchNumber: number;
  teamNumber: number;
}): MatchForm | null {
  const match = input.matches.find((m) => m.matchNumber === input.matchNumber);
  const team = input.teams.find((t) => t.number === input.teamNumber);
  if (!match || !team) return null;
  return {
    match,
    team,
    myReport: findMyReport(input.myReports, input.practicing, match._id, team._id),
    othersCount: 0,
    alliance: match.redTeamNumbers.includes(team.number) ? "red" : "blue",
    hopper: input.hopper,
  };
}

/** In practice mode a robot can be practised again, so no report counts as mine. */
export function findMyReport(
  myReports: MyReports | undefined,
  practicing: boolean,
  matchId: string,
  teamId: string,
): MatchForm["myReport"] {
  if (practicing || !myReports) return null;
  return myReports.find((r) => r.matchId === matchId && r.teamId === teamId) ?? null;
}

/**
 * pit.forTeamNumber, for a team with no pit report. pit.upsert patches the
 * team's existing report, so a blank form for a team that already has one
 * would overwrite real answers when it syncs: that is "blocked". Practice
 * mode always starts blank and never touches the real report.
 */
export function derivePitForm(
  teams: Teams,
  teamNumber: number,
  practicing: boolean,
): PitForm | null | "blocked" {
  const team = teams.find((t) => t.number === teamNumber);
  if (!team) return null;
  if (!practicing && team.pitStatus !== "none") return "blocked";
  return { team, report: null, photoUrl: null };
}

/**
 * notes.matchNote. notes.saveMatchReport replaces the scout's earlier report
 * on the same robot, so a robot already in "my notes" is "blocked" unless the
 * earlier report is on this device.
 */
export function deriveNoteMatchForm(input: {
  matches: Matches;
  teams: NoteTeams | undefined;
  myNotes: MyNotes | undefined;
  practicing: boolean;
  matchNumber: number;
  teamNumber: number;
}): NoteMatchForm | null | "blocked" {
  const match = input.matches.find((m) => m.matchNumber === input.matchNumber);
  if (!match) return null;
  const alliance = match.redTeamNumbers.includes(input.teamNumber)
    ? ("red" as const)
    : match.blueTeamNumbers.includes(input.teamNumber)
      ? ("blue" as const)
      : null;
  if (alliance === null) return null;
  const team = input.teams?.find((t) => t.number === input.teamNumber);
  if (input.teams !== undefined && !team) return null;
  const already = input.myNotes?.some(
    (n) => n.matchNumber === input.matchNumber && n.teamNumber === input.teamNumber,
  );
  if (!input.practicing && already) return "blocked";
  return {
    matchNumber: match.matchNumber,
    teamNumber: input.teamNumber,
    nickname: team?.nickname ?? "",
    alliance,
    notes: null,
    report: null,
  };
}

/** notes.pitNote, for a team with no pit report. Same guard as derivePitForm. */
export function deriveNotePitForm(
  teams: NoteTeams,
  teamNumber: number,
  practicing: boolean,
): NotePitForm | null | "blocked" {
  const team = teams.find((t) => t.number === teamNumber);
  if (!team) return null;
  if (!practicing && team.pitStatus !== "none") return "blocked";
  return { teamNumber: team.number, nickname: team.nickname, photoUrl: null, note: null };
}
EOF_FILE
echo "  wrote            src/lib/offline/derive.ts"
cat > src/lib/offline/forms.ts <<'EOF_FILE'
import { useMemo } from "react";

import { api } from "../../../convex/_generated/api";
import {
  deriveMatchForm, deriveNoteMatchForm, deriveNotePitForm, derivePitForm, deriveRobots,
  findMyReport,
  type MatchForm, type MatchRobots, type NoteMatchForm, type NotePitForm, type PitForm, type Robot,
} from "./derive";
import { useOnline } from "./status";
import { useCachedOnly } from "./use-cached-only";
import { useCachedQuery } from "./use-cached-query";

/**
 * What a scouting page shows, online or off (offline plan, section 7).
 *
 * Online, each hook is exactly the page's own query. Offline it returns, in
 * order of preference: the copy saved the last time this exact page was
 * open, or the same shape rebuilt from the saved schedule and team list.
 * The lists are read with useCachedOnly, which never calls Convex.
 */
export type OfflineForm<T> = {
  /** undefined: loading. null: not at the active event. */
  data: T | null | undefined;
  /** Offline, and nothing on this device to build the page from. */
  unavailable: boolean;
  /** Offline, and a blank form here would overwrite saved answers. */
  blocked: boolean;
};

const settle = <T,>(online: boolean, data: T | null | undefined, blocked = false): OfflineForm<T> => ({
  data: blocked ? undefined : data,
  unavailable: !online && !blocked && data === undefined,
  blocked,
});

/** The six robots in a match, for the robot picker on Match Scouting. */
export function useMatchRobots(matchNumber: number): MatchRobots | null | undefined {
  const stored = useCachedQuery(api.matches.teamsInMatch, { matchNumber });
  const matches = useCachedOnly(api.matches.listForEvent);
  const teams = useCachedOnly(api.teams.listWithStatus);
  const noteTeams = useCachedOnly(api.notes.teams);
  return useMemo(() => {
    if (stored !== undefined || !matches) return stored;
    // Whichever season's team list this device has.
    const robots: Robot[] | undefined =
      teams ?? noteTeams?.map((t) => ({ _id: t.teamId, number: t.number, nickname: t.nickname }));
    return deriveRobots(matches, robots, matchNumber);
  }, [stored, matches, teams, noteTeams, matchNumber]);
}

/** matchReports.forMatchAndTeam, for the 2026 match form. */
export function useMatchFormData(
  matchNumber: number,
  teamNumber: number,
  valid: boolean,
): OfflineForm<MatchForm> {
  const online = useOnline();
  const stored = useCachedQuery(
    api.matchReports.forMatchAndTeam,
    valid ? { matchNumber, teamNumber } : "skip",
  );
  const matches = useCachedOnly(api.matches.listForEvent);
  const teams = useCachedOnly(api.teams.listWithStatus);
  const myReports = useCachedOnly(api.matchReports.mine);
  const practicing = useCachedOnly(api.profiles.me)?.practiceMode === true;

  return useMemo(() => {
    if (online || !valid) return settle<MatchForm>(online, stored);
    if (stored) {
      // The saved copy may predate a report this scout has since submitted.
      const mine =
        stored.myReport ?? findMyReport(myReports, practicing, stored.match._id, stored.team._id);
      return settle<MatchForm>(online, mine === stored.myReport ? stored : { ...stored, myReport: mine });
    }
    if (stored === null || !matches || !teams) return settle<MatchForm>(online, stored);
    return settle(
      online,
      deriveMatchForm({
        matches, teams, myReports, practicing, hopper: null, matchNumber, teamNumber,
      }),
    );
  }, [online, valid, stored, matches, teams, myReports, practicing, matchNumber, teamNumber]);
}

/** pit.forTeamNumber, for the 2026 pit form. */
export function usePitFormData(teamNumber: number): OfflineForm<PitForm> {
  const online = useOnline();
  const valid = !Number.isNaN(teamNumber);
  const stored = useCachedQuery(api.pit.forTeamNumber, valid ? { teamNumber } : "skip");
  const teams = useCachedOnly(api.teams.listWithStatus);
  const practicing = useCachedOnly(api.profiles.me)?.practiceMode === true;

  return useMemo(() => {
    if (online || !valid) return settle<PitForm>(online, stored);
    if (stored) {
      // A blank copy is only safe while the team list still says "not
      // scouted": a teammate may have scouted this team since.
      const status = teams?.find((t) => t.number === teamNumber)?.pitStatus;
      const stale = stored.report === null && !practicing && status !== undefined && status !== "none";
      return stale ? settle<PitForm>(online, undefined, true) : settle<PitForm>(online, stored);
    }
    if (stored === null || !teams) return settle<PitForm>(online, stored);
    const derived = derivePitForm(teams, teamNumber, practicing);
    return derived === "blocked" ? settle<PitForm>(online, undefined, true) : settle<PitForm>(online, derived);
  }, [online, valid, stored, teams, practicing, teamNumber]);
}

/** notes.matchNote, for the match form of seasons without their own. */
export function useNoteMatchFormData(
  matchNumber: number,
  teamNumber: number,
  valid: boolean,
): OfflineForm<NoteMatchForm> {
  const online = useOnline();
  const stored = useCachedQuery(api.notes.matchNote, valid ? { matchNumber, teamNumber } : "skip");
  const matches = useCachedOnly(api.matches.listForEvent);
  const teams = useCachedOnly(api.notes.teams);
  const myNotes = useCachedOnly(api.notes.mine);
  const practicing = useCachedOnly(api.profiles.me)?.practiceMode === true;

  return useMemo(() => {
    if (online || !valid) return settle<NoteMatchForm>(online, stored);
    if (stored) {
      const already = myNotes?.some(
        (n) => n.matchNumber === matchNumber && n.teamNumber === teamNumber,
      );
      const stale = stored.report === null && stored.notes === null && !practicing && already === true;
      return stale ? settle<NoteMatchForm>(online, undefined, true) : settle<NoteMatchForm>(online, stored);
    }
    if (stored === null || !matches) return settle<NoteMatchForm>(online, stored);
    const derived = deriveNoteMatchForm({
      matches, teams: teams ?? undefined, myNotes, practicing, matchNumber, teamNumber,
    });
    return derived === "blocked"
      ? settle<NoteMatchForm>(online, undefined, true)
      : settle<NoteMatchForm>(online, derived);
  }, [online, valid, stored, matches, teams, myNotes, practicing, matchNumber, teamNumber]);
}

/** notes.pitNote, for the pit form of seasons without their own. */
export function useNotePitFormData(teamNumber: number): OfflineForm<NotePitForm> {
  const online = useOnline();
  const valid = !Number.isNaN(teamNumber);
  const stored = useCachedQuery(api.notes.pitNote, valid ? { teamNumber } : "skip");
  const teams = useCachedOnly(api.notes.teams);
  const practicing = useCachedOnly(api.profiles.me)?.practiceMode === true;

  return useMemo(() => {
    if (online || !valid) return settle<NotePitForm>(online, stored);
    if (stored) {
      const status = teams?.find((t) => t.number === teamNumber)?.pitStatus;
      const stale = stored.note === null && !practicing && status !== undefined && status !== "none";
      return stale ? settle<NotePitForm>(online, undefined, true) : settle<NotePitForm>(online, stored);
    }
    if (stored === null || !teams) return settle<NotePitForm>(online, stored);
    const derived = deriveNotePitForm(teams, teamNumber, practicing);
    return derived === "blocked"
      ? settle<NotePitForm>(online, undefined, true)
      : settle<NotePitForm>(online, derived);
  }, [online, valid, stored, teams, practicing, teamNumber]);
}
EOF_FILE
echo "  wrote            src/lib/offline/forms.ts"
cat > src/components/held-notice.tsx <<'EOF_FILE'
import { useEffect } from "react";
import { CloudOff } from "lucide-react";

import { useOnline } from "@/lib/offline/status";

/**
 * A report submitted with no connection is held in this tab's memory and
 * sent when the connection returns, but only while the app stays open
 * (offline plan, section 7.6). This says so, above the submit button, and
 * asks the browser to warn before the tab is closed or reloaded.
 *
 * It does not make the report safe. Durable storage of held reports is the
 * data transfer plan.
 */
export function HeldNotice({ saving }: { saving: boolean }) {
  const online = useOnline();
  const held = saving && !online;

  useEffect(() => {
    if (!held) return;
    const warn = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      // Older browsers need a return value to show the prompt.
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [held]);

  if (!held) return null;
  return (
    <p
      role="status"
      className="bg-destructive flex items-start gap-2 rounded-lg p-3 text-sm font-medium text-white"
    >
      <CloudOff className="mt-0.5 size-4 shrink-0" aria-hidden />
      <span>
        Held on this device. Keep CircuitScout open until it sends. It will send
        by itself when you are back online.
      </span>
    </p>
  );
}
EOF_FILE
echo "  wrote            src/components/held-notice.tsx"
cat > src/components/offline-ready.tsx <<'EOF_FILE'
import { useEffect, useState, useSyncExternalStore } from "react";
import { CloudCheck, CloudDownload } from "lucide-react";

import { useOnline } from "@/lib/offline/status";
import { cacheKey, readCached, savedTick, subscribeSaved } from "@/lib/offline/store";

const AT = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

/** Whether the service worker that serves the app's files offline is in place. */
function useAppFilesSaved(): boolean {
  const [saved, setSaved] = useState(false);
  useEffect(() => {
    if (!("serviceWorker" in navigator)) return;
    let current = true;
    // Resolves once a worker is active; never, when none is registered (dev).
    void navigator.serviceWorker.ready.then(() => {
      if (current) setSaved(true);
    });
    return () => {
      current = false;
    };
  }, []);
  return saved;
}

function isInstalled(): boolean {
  if (window.matchMedia("(display-mode: standalone)").matches) return true;
  // iOS Safari's own flag for a home screen app.
  return (navigator as { standalone?: boolean }).standalone === true;
}

const isAppleTouch = (): boolean =>
  /iPhone|iPad|iPod/.test(navigator.userAgent) ||
  (navigator.userAgent.includes("Macintosh") && navigator.maxTouchPoints > 1);

/**
 * One line on the dashboard that lets a lead scout check a phone before it
 * goes into the stands (offline plan, section 2). "Offline ready" means both
 * halves are on the device: the app's files, and each list in `lists`.
 *
 * `lists` are Convex function names as "module:function", each with a hint
 * for the scout when that list is not saved yet.
 */
export function OfflineReady({
  lists,
}: {
  lists: ReadonlyArray<{ fn: string; missing: string }>;
}) {
  const online = useOnline();
  const filesSaved = useAppFilesSaved();
  // Re-read when the store writes; the tick itself is not used.
  useSyncExternalStore(subscribeSaved, savedTick);

  // No service worker: a development server, or a browser without support.
  // Saying anything about offline here would be a guess.
  if (!filesSaved) return null;

  let oldest: number | null = null;
  let firstMissing: string | null = null;
  for (const list of lists) {
    const key = cacheKey(list.fn, {});
    const hit = key === null ? undefined : readCached(key);
    if (!hit) {
      firstMissing ??= list.missing;
      continue;
    }
    if (oldest === null || hit.savedAt < oldest) oldest = hit.savedAt;
  }

  const ready = firstMissing === null && oldest !== null;
  const installHint = isInstalled()
    ? null
    : isAppleTouch()
      ? "For the most reliable offline use, tap Share, then Add to Home Screen."
      : "For the most reliable offline use, install CircuitScout from your browser's menu.";

  return (
    <div className="text-muted-foreground space-y-1 text-xs">
      <p className="flex items-center gap-1.5">
        {ready ? (
          <CloudCheck className="size-3.5 shrink-0 text-green-600 dark:text-green-400" aria-hidden />
        ) : (
          <CloudDownload className="size-3.5 shrink-0" aria-hidden />
        )}
        {ready && oldest !== null ? (
          <span>
            <span className="text-foreground font-medium">Offline ready.</span>{" "}
            {online ? `Last saved ${AT.format(oldest)}.` : `Saved ${AT.format(oldest)}.`}
          </span>
        ) : (
          <span>Not ready for offline yet. {firstMissing ?? "Waiting for the event data."}</span>
        )}
      </p>
      {installHint ? <p>{installHint}</p> : null}
    </div>
  );
}
EOF_FILE
echo "  wrote            src/components/offline-ready.tsx"

# ---- 3. Anchored edits -----------------------------------------------------
say "Forms, robot pickers, dashboards"
bun .patch-offline-forms.mjs write

say "Done"
cat <<'TXT'
Next:
  1. bun run typecheck && bun run lint && bun run build
  2. Test against a production build (bunx vite preview, or a Vercel preview):
     a. Sign in and open the Dashboard. It shows "Offline ready" with a time.
     b. DevTools > Network > Offline, reload.
     c. Match Scouting: open any match, the six robots appear with no report
        counts. Open a robot you have never opened: the form loads.
     d. Pit Scouting: a team marked Not scouted opens a blank form. A team
        marked Scouted that you have not opened on this device says
        "Already scouted".
     e. Fill in a pit form and save. "Held on this device" appears and stays.
        Go back online WITHOUT closing the tab: it sends, and the usual
        "Saved team ..." message appears.
  3. Step (e) is the one to watch. A held report is lost if the app is closed
     first. Making held reports survive that is the data transfer plan.
TXT
