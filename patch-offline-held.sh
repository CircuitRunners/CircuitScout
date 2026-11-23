#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-offline-held.sh — offline plan, patch 4b: see what is waiting to send
#
# Before this patch, a report saved with no connection was sent when the
# connection came back, but nothing showed it in the meantime: leave the form
# and come back, and it looked blank.
#
#   1. src/lib/offline/held.ts — a list of reports saved offline and not sent
#      yet. A form saved with no connection hands its report to this list and
#      returns to its landing page, instead of sitting on a spinner.
#   2. Dashboard: a "Waiting to send" card listing each one, with the time it
#      was saved and a View button. The offline banner shows the count, and
#      says "Sending N reports" once the connection is back.
#   3. Reopening a held form shows what was entered:
#        - pit forms and other-season forms reopen with your answers filled
#          in, and can be changed and saved again (the latest answers win);
#        - a 2026 match report is shown as a read-only summary, because a
#          submitted match report can only be changed with a reason on record.
#   4. When a held report reaches the server it leaves the list and a "Sent"
#      message appears. If the server refuses it, it stays in the list with
#      the server's reason.
#   5. The browser warns before the tab is closed while anything is waiting.
#
# STILL TRUE: the list lives in this tab's memory. Closing or reloading the
# app loses what is waiting. Making held reports survive that is the data
# transfer plan, and held.ts is the module it will replace the storage of.
#
# Requires patch-offline-forms.sh (patch 4).
# No Convex change, no schema change, no new dependency. Safe to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f vite.config.ts && -f convex/auth.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
[[ -f src/lib/offline/forms.ts && -f src/components/offline-ready.tsx ]] || {
  echo "ERROR: run patch-offline-forms.sh (patch 4) first; nothing was changed" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# ---- 1. Check every anchor before writing anything ------------------------
say "Checking anchors"
if grep -q "useHeldItems" src/components/offline-banner.tsx; then
  echo "  already patched  src/components/offline-banner.tsx"
elif grep -q "oldestServed" src/components/offline-banner.tsx && [[ $(wc -l < src/components/offline-banner.tsx) -lt 45 ]]; then
  echo "  ok               src/components/offline-banner.tsx"
else
  echo "ERROR: src/components/offline-banner.tsx is not the file this patch expects; nothing was changed" >&2
  exit 1
fi
trap 'rm -f .patch-offline-held.mjs' EXIT
cat > .patch-offline-held.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";

const mode = process.argv[2]; // "check" | "write"
const plan = [];
const read = (path) => readFileSync(path, "utf8").replace(/\r\n/g, "\n");

/** Skip when `marker` is present; otherwise every anchor must appear exactly once. */
function edit(path, marker, pairs) {
  let source = read(path);
  if (source.includes(marker)) return plan.push({ path, skip: true });
  for (const [anchor] of pairs) {
    const count = source.split(anchor).length - 1;
    if (count !== 1) throw new Error(`${path}: expected anchor once, found ${count}:\n  ${anchor}`);
  }
  for (const [anchor, replacement] of pairs) source = source.replace(anchor, replacement);
  plan.push({ path, skip: false, next: source });
}

const STATUS_IMPORT = 'import { useOnline } from "@/lib/offline/status";\n';

// ---- 2026 pit form: hand off when offline, show held answers on return -------
edit("src/routes/pit/form.tsx", "holdSubmission", [
  [
    STATUS_IMPORT,
    'import { HeldFormNotice } from "@/components/held";\nimport { forgetHeld, heldValues, holdSubmission } from "@/lib/offline/held";\n' + STATUS_IMPORT,
  ],
  [
    "      await upsert({ teamId: data.team._id, ...draft, photoId });\n",
    "      await upsert({ teamId: data.team._id, ...draft, photoId });\n      forgetHeld(`pit:${data.team.number}`);\n",
  ],
  [
    "    if (loaded || data === undefined || data === null) return;\n    const report = data.report;\n",
    `    if (loaded || data === undefined || data === null) return;
    // Answers saved offline and not sent yet come first: they are newer than
    // anything the server or the cache has.
    const held = heldValues<FormState>(\`pit:\${data.team.number}\`);
    if (held) {
      setForm(held);
      setLoaded(true);
      return;
    }
    const report = data.report;
`,
  ],
  [
    '    setSaving(true);\n    try {\n      let photoId: Id<"_storage"> | null = null;\n',
    `    if (!online && !photoFile) {
      // No connection: hand the report to the held list rather than waiting
      // here. It sends when the connection returns, while the app stays open.
      const team = data.team;
      holdSubmission({
        key: \`pit:\${team.number}\`,
        label: \`Team \${team.number} pit report\`,
        to: \`/pit/\${team.number}\`,
        values: form,
        send: () => upsert({ teamId: team._id, ...draft, photoId: null }),
      });
      void navigate("/pit");
      return;
    }
    setSaving(true);
    try {
      let photoId: Id<"_storage"> | null = null;
`,
  ],
  [
    "    >\n      <Card>\n        <CardHeader><CardTitle>Scoring capability</CardTitle></CardHeader>\n",
    "    >\n      <HeldFormNotice heldKey={`pit:${data.team.number}`} />\n      <Card>\n        <CardHeader><CardTitle>Scoring capability</CardTitle></CardHeader>\n",
  ],
]);

// ---- 2026 match form: hand off when offline, show a summary on return --------
edit("src/routes/scout/form.tsx", "holdSubmission", [
  [
    STATUS_IMPORT,
    `import { HeldSummary } from "@/components/held";
import { holdSubmission, useHeld } from "@/lib/offline/held";
import { summarizeMatchReport } from "@/lib/offline/held-match-summary";
` + STATUS_IMPORT,
  ],
  [
    "  const online = useOnline();\n",
    "  const online = useOnline();\n  const heldKey = `match:${matchNumber}:${teamNumber}`;\n  const held = useHeld(heldKey);\n",
  ],
  [
    `        await submit({
          matchId: data.match._id,
          teamId: data.team._id,
          ...payload,
        });
        toast.success(\`Qual \${matchNumber} · team \${teamNumber} submitted\`);
`,
    `        const args = { matchId: data.match._id, teamId: data.team._id, ...payload };
        if (!online) {
          // No connection: hand the report to the held list rather than
          // waiting here. It sends when the connection returns, while the
          // app stays open.
          holdSubmission({
            key: heldKey,
            label: \`Qual \${matchNumber} · team \${teamNumber}\`,
            to: \`/scout/\${matchNumber}/\${teamNumber}\`,
            values: payload,
            send: () => submit(args),
          });
          void navigate("/scout");
          return;
        }
        await submit(args);
        toast.success(\`Qual \${matchNumber} · team \${teamNumber} submitted\`);
`,
  ],
  [
    "  if (data.myReport && !editId) {\n",
    `  if (held && !editId) {
    // A submitted match report can only be changed with a reason on record,
    // so a held one is shown, not reopened as a form.
    return (
      <PageShell
        title={\`Qual \${matchNumber} · \${data.team.number}\`}
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
`,
  ],
]);

// ---- Other seasons: match form -----------------------------------------------
edit("src/routes/notes/scout-form.tsx", "holdSubmission", [
  [
    STATUS_IMPORT,
    'import { HeldFormNotice } from "@/components/held";\nimport { forgetHeld, holdSubmission, useHeld } from "@/lib/offline/held";\n' + STATUS_IMPORT,
  ],
  [
    "      });\n      toast.success(`Qual ${data.matchNumber} · team ${data.teamNumber} ${saved",
    "      });\n      forgetHeld(`note-match:${data.matchNumber}:${data.teamNumber}`);\n      toast.success(`Qual ${data.matchNumber} · team ${data.teamNumber} ${saved",
  ],
  [
    "  const { data, unavailable, blocked } = useNoteMatchFormData(matchNumber, teamNumber, !bad);\n",
    "  const { data, unavailable, blocked } = useNoteMatchFormData(matchNumber, teamNumber, !bad);\n  const held = useHeld(`note-match:${matchNumber}:${teamNumber}`);\n",
  ],
  [
    "  return <MatchReportForm key={`${data.matchNumber}:${data.teamNumber}`} data={data} back={back} />;\n",
    `  // Answers saved offline and not sent yet seed the form: they are newer
  // than anything the server or the cache has.
  const seeded = held ? { ...data, report: held.values as MatchData["report"] } : data;
  return <MatchReportForm key={\`\${data.matchNumber}:\${data.teamNumber}\`} data={seeded} back={back} />;
`,
  ],
  [
    "    setSaving(true);\n    try {\n      await save({\n        matchNumber: data.matchNumber,\n        teamNumber: data.teamNumber,\n",
    `    if (!online) {
      // No connection: hand the report to the held list rather than waiting
      // here. It sends when the connection returns, while the app stays open.
      const report = {
        autoPath, autoScoring, teleopScoring, endgame,
        driver, defense,
        broke, brokeNotes: broke ? brokeNotes : "",
        inconsistent, inconsistentNotes: inconsistent ? inconsistentNotes : "",
        notes: finalNotes,
      };
      holdSubmission({
        key: \`note-match:\${data.matchNumber}:\${data.teamNumber}\`,
        label: \`Qual \${data.matchNumber} · team \${data.teamNumber}\`,
        to: \`/scout/\${data.matchNumber}/\${data.teamNumber}\`,
        values: report,
        send: () => save({ matchNumber: data.matchNumber, teamNumber: data.teamNumber, ...report }),
      });
      void navigate("/scout");
      return;
    }
    setSaving(true);
    try {
      await save({
        matchNumber: data.matchNumber,
        teamNumber: data.teamNumber,
`,
  ],
  [
    "      actions={back}\n    >\n      <Tabs value={period} onValueChange={(v) => setPeriod(v as Period)}>\n",
    "      actions={back}\n    >\n      <HeldFormNotice heldKey={`note-match:${data.matchNumber}:${data.teamNumber}`} />\n      <Tabs value={period} onValueChange={(v) => setPeriod(v as Period)}>\n",
  ],
]);

// ---- Other seasons: pit form -------------------------------------------------
edit("src/routes/notes/pit-form.tsx", "holdSubmission", [
  [
    STATUS_IMPORT,
    'import { HeldFormNotice } from "@/components/held";\nimport { forgetHeld, heldValues, holdSubmission } from "@/lib/offline/held";\n' + STATUS_IMPORT,
  ],
  [
    "      await save({ teamNumber, ...draft, photoId });\n",
    "      await save({ teamNumber, ...draft, photoId });\n      forgetHeld(`note-pit:${teamNumber}`);\n",
  ],
  [
    "  const [form, setForm] = useState<FormState>(() => formFromSaved(data));\n",
    "  // Answers saved offline and not sent yet come first: they are newer than\n  // anything the server or the cache has.\n  const [form, setForm] = useState<FormState>(\n    () => heldValues<FormState>(`note-pit:${data.teamNumber}`) ?? formFromSaved(data),\n  );\n",
  ],
  [
    '    setSaving(true);\n    try {\n      let photoId: Id<"_storage"> | null = null;\n',
    `    if (!online && !photoFile) {
      // No connection: hand the report to the held list rather than waiting
      // here. It sends when the connection returns, while the app stays open.
      holdSubmission({
        key: \`note-pit:\${teamNumber}\`,
        label: \`Team \${teamNumber} pit report\`,
        to: \`/pit/\${teamNumber}\`,
        values: form,
        send: () => save({ teamNumber, ...draft, photoId: null }),
      });
      void navigate("/pit");
      return;
    }
    setSaving(true);
    try {
      let photoId: Id<"_storage"> | null = null;
`,
  ],
  [
    "      actions={back}\n    >\n      <Card>\n        <CardHeader>\n          <CardTitle>Scoring capability</CardTitle>\n",
    "      actions={back}\n    >\n      <HeldFormNotice heldKey={`note-pit:${teamNumber}`} />\n      <Card>\n        <CardHeader>\n          <CardTitle>Scoring capability</CardTitle>\n",
  ],
]);

// ---- Dashboards: the Waiting to send card ------------------------------------
const READY_IMPORT = 'import { OfflineReady } from "@/components/offline-ready";\n';
for (const path of ["src/routes/dashboard.tsx", "src/routes/notes/dashboard.tsx"]) {
  edit(path, "HeldList", [
    [READY_IMPORT, 'import { HeldList } from "@/components/held";\n' + READY_IMPORT],
    ["      />\n      {assignments?.upNext ? (\n", "      />\n      <HeldList />\n      {assignments?.upNext ? (\n"],
  ]);
}

for (const e of plan) {
  if (e.skip) console.log(`  already patched  ${e.path}`);
  else if (mode === "write") {
    writeFileSync(e.path, e.next);
    console.log(`  patched          ${e.path}`);
  } else console.log(`  ok               ${e.path}`);
}
MJS
bun .patch-offline-held.mjs check || { echo "ERROR: nothing was changed" >&2; exit 1; }

# ---- 2. New files ----------------------------------------------------------
say "Held list, summary, banner"
cat > src/lib/offline/held.ts <<'EOF_FILE'
import { useSyncExternalStore } from "react";
import { toast } from "sonner";

/**
 * Reports submitted with no connection, and what happened to them.
 *
 * A form that is saved offline hands its report to holdSubmission() instead
 * of waiting on it. The Convex client keeps the mutation queued and sends it
 * when the connection returns; this module keeps the part a scout needs to
 * see in the meantime: what is waiting, since when, and what was entered.
 *
 * Everything here lives in this tab's memory. Closing or reloading the app
 * loses both the queued mutation and this list. Making held reports survive
 * that is the data transfer plan; when it is built, this is the module whose
 * storage changes, and the forms and the list keep calling the same functions.
 */
export type HeldItem = {
  id: number;
  /** One per form: "pit:1002", "match:12:1002", "note-pit:254", "note-match:3:254". */
  key: string;
  /** What the scout calls it: "Team 1002 pit report". */
  label: string;
  /** The route that shows it. */
  to: string;
  heldAt: number;
  /** What was entered, in whatever shape the form can show again. */
  values: unknown;
  status: "waiting" | "failed";
  /** The server's reason, when status is "failed". */
  error: string | null;
};

let sequence = 0;
// A new array on every change, so it works as a useSyncExternalStore snapshot.
let items: ReadonlyArray<HeldItem> = [];
const listeners = new Set<() => void>();

function publish(next: ReadonlyArray<HeldItem>) {
  items = next;
  for (const listener of listeners) listener();
}

/**
 * Take over a submission made with no connection. `send` must start the
 * Convex mutation and return its promise; it is called once, now, so the
 * mutation joins the client's queue in the order the scout pressed save.
 *
 * Saving the same form again replaces its entry here. Both mutations stay
 * queued and are sent in order, so for forms whose save replaces the earlier
 * one (pit reports, other-season reports) the latest answers win.
 */
export function holdSubmission(input: {
  key: string;
  label: string;
  to: string;
  values: unknown;
  send: () => Promise<unknown>;
}) {
  const id = (sequence += 1);
  const item: HeldItem = {
    id,
    key: input.key,
    label: input.label,
    to: input.to,
    heldAt: Date.now(),
    values: input.values,
    status: "waiting",
    error: null,
  };
  publish([...items.filter((i) => i.key !== input.key), item]);
  toast("Held on this device", {
    description: `${input.label} will send when you are back online. Keep CircuitScout open until then.`,
  });

  const settle = (error: unknown) => {
    // An entry replaced by a later save of the same form is no longer listed.
    if (!items.some((i) => i.id === id)) return;
    if (error === null) {
      publish(items.filter((i) => i.id !== id));
      toast.success(`Sent: ${input.label}`);
      return;
    }
    const message = error instanceof Error ? error.message : String(error);
    publish(items.map((i) => (i.id === id ? { ...i, status: "failed" as const, error: message } : i)));
    toast.error(`Could not send: ${input.label}`, { description: message });
  };

  let sending: Promise<unknown>;
  try {
    sending = input.send();
  } catch (error) {
    settle(error);
    return;
  }
  sending.then(
    () => settle(null),
    (error: unknown) => settle(error),
  );
}

/** Remove a failed entry from the list. A waiting entry cannot be withdrawn. */
export function dismissHeld(id: number) {
  publish(items.filter((i) => i.id !== id || i.status === "waiting"));
}

/**
 * The form was saved the ordinary way, with a connection: an entry left over
 * from an earlier failed attempt no longer describes anything.
 */
export function forgetHeld(key: string) {
  if (items.some((i) => i.key === key && i.status === "failed")) {
    publish(items.filter((i) => i.key !== key || i.status !== "failed"));
  }
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
const snapshot = (): ReadonlyArray<HeldItem> => items;

/** For reading once, outside render (a form seeding its state). */
export function heldValues<T>(key: string): T | undefined {
  return items.find((i) => i.key === key)?.values as T | undefined;
}

/** Every held report, oldest first. */
export function useHeldItems(): ReadonlyArray<HeldItem> {
  return useSyncExternalStore(subscribe, snapshot);
}

/** The held report for one form, if there is one. */
export function useHeld(key: string): HeldItem | undefined {
  return useHeldItems().find((i) => i.key === key);
}
EOF_FILE
echo "  wrote            src/lib/offline/held.ts"
cat > src/lib/offline/held-match-summary.ts <<'EOF_FILE'
/**
 * A held 2026 match report, as a few readable rows. A match report cannot be
 * changed once it is submitted without a reason on record, so a held one is
 * shown rather than reopened as an editable form.
 *
 * `values` is the payload the form built for matchReports.submit. It is read
 * defensively: this is display only, and a field that is missing or renamed
 * should cost a row, not the page.
 */
export function summarizeMatchReport(values: unknown): Array<[label: string, value: string]> {
  const report = record(values);
  const auto = record(report.auto);
  const path = record(auto.path);
  const teleop = record(report.teleop);
  const endgame = record(report.endgame);
  const ratings = record(report.ratings);

  const steps = Array.isArray(path.steps) ? path.steps.length : 0;
  const teleopFuel = Object.values(record(teleop.byShift)).reduce<number>(
    (sum, n) => sum + (typeof n === "number" ? n : 0),
    0,
  );
  const rows: Array<[string, string]> = [
    ["Auto start", pretty(path.start)],
    ["Auto", `${number(auto.fuel)} fuel, ${steps} step${steps === 1 ? "" : "s"}${auto.climbL1 === true ? ", L1 climb" : ""}`],
    ["Auto winner", pretty(report.autoWinner)],
    ["Teleop fuel", String(teleopFuel)],
    ["Climb", pretty(endgame.climb)],
    ["Driver", String(number(ratings.driver))],
    ["Defense", String(number(ratings.defense))],
    ["Shooting accuracy", `${number(ratings.accuracy)}%`],
    ["Balls per second", String(number(report.avgBps))],
  ];
  if (ratings.broke === true) rows.push(["Broke", text(ratings.brokeNotes) || "Yes"]);
  if (ratings.inconsistent === true) rows.push(["Inconsistent", text(ratings.inconsistentNotes) || "Yes"]);
  rows.push(["Final notes", text(report.finalNotes)]);
  return rows.filter(([, value]) => value !== "");
}

const record = (value: unknown): Record<string, unknown> =>
  value !== null && typeof value === "object" ? (value as Record<string, unknown>) : {};
const number = (value: unknown): number => (typeof value === "number" ? value : 0);
const text = (value: unknown): string =>
  typeof value === "string" ? value : typeof value === "number" ? String(value) : "";
/** "trench-left" -> "Trench left": stored values, made readable. */
const pretty = (value: unknown): string => {
  const raw = text(value).replace(/-/g, " ");
  return raw === "" ? "" : raw.charAt(0).toUpperCase() + raw.slice(1);
};
EOF_FILE
echo "  wrote            src/lib/offline/held-match-summary.ts"
cat > src/components/held.tsx <<'EOF_FILE'
import { Clock, TriangleAlert } from "lucide-react";
import { Link } from "react-router";

import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { dismissHeld, useHeld, useHeldItems, type HeldItem } from "@/lib/offline/held";

const AT = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

function Status({ item }: { item: HeldItem }) {
  if (item.status === "waiting") {
    return (
      <span className="text-muted-foreground flex items-center gap-1.5 text-xs">
        <Clock className="size-3.5 shrink-0" aria-hidden />
        Waiting to send since {AT.format(item.heldAt)}
      </span>
    );
  }
  return (
    <span className="text-destructive flex items-start gap-1.5 text-xs">
      <TriangleAlert className="mt-0.5 size-3.5 shrink-0" aria-hidden />
      <span>Could not send: {item.error}</span>
    </span>
  );
}

/**
 * Dashboard card: every report that was saved with no connection and has not
 * reached the server yet. Renders nothing when there are none.
 */
export function HeldList() {
  const items = useHeldItems();
  if (items.length === 0) return null;
  return (
    <Card>
      <CardHeader>
        <CardTitle>Waiting to send</CardTitle>
        <CardDescription>
          Saved on this device only. Each one sends by itself when you are back
          online. Keep CircuitScout open until this list is empty: closing or
          reloading the app loses them.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        {items.map((item) => (
          <div key={item.id} className="flex items-center gap-3 rounded-md border p-3">
            <div className="min-w-0 flex-1 space-y-1">
              <p className="truncate text-sm font-medium">{item.label}</p>
              <Status item={item} />
            </div>
            <Button variant="outline" size="sm" render={<Link to={item.to} />}>View</Button>
            {item.status === "failed" ? (
              <Button variant="ghost" size="sm" onClick={() => dismissHeld(item.id)}>Dismiss</Button>
            ) : null}
          </div>
        ))}
      </CardContent>
    </Card>
  );
}

/**
 * At the top of a form whose answers are held: says so, so reopening the form
 * and seeing your own entries is not mistaken for the server having them.
 */
export function HeldFormNotice({ heldKey }: { heldKey: string }) {
  const item = useHeld(heldKey);
  if (!item) return null;
  return (
    <div role="status" className="space-y-1 rounded-lg border border-dashed p-3">
      <Status item={item} />
      <p className="text-muted-foreground text-xs">
        {item.status === "waiting"
          ? "These are the answers you saved. You can change them and save again."
          : "These are the answers you saved. Fix what the message says and save again."}
      </p>
    </div>
  );
}

/** A held report shown as read-only rows, for forms that cannot be reopened. */
export function HeldSummary({
  item,
  rows,
}: {
  item: HeldItem;
  rows: ReadonlyArray<readonly [label: string, value: string]>;
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>What you entered</CardTitle>
        <CardDescription><Status item={item} /></CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        <dl className="divide-y text-sm">
          {rows.map(([label, value]) => (
            <div key={label} className="flex gap-3 py-2">
              <dt className="text-muted-foreground w-2/5 shrink-0">{label}</dt>
              <dd className="min-w-0 flex-1 break-words whitespace-pre-wrap">{value}</dd>
            </div>
          ))}
        </dl>
        {item.status === "failed" ? (
          <Button variant="outline" onClick={() => dismissHeld(item.id)}>
            Dismiss and start again
          </Button>
        ) : null}
      </CardContent>
    </Card>
  );
}
EOF_FILE
echo "  wrote            src/components/held.tsx"
cat > src/components/offline-banner.tsx <<'EOF_FILE'
import { useEffect, useSyncExternalStore } from "react";
import { CloudOff, CloudUpload } from "lucide-react";

import { useHeldItems } from "@/lib/offline/held";
import { useOnline } from "@/lib/offline/status";
import { oldestServed, subscribeServed } from "@/lib/offline/store";

const AS_OF = new Intl.DateTimeFormat(undefined, {
  month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
});

const reports = (n: number) => `${n} report${n === 1 ? "" : "s"}`;

/**
 * Under the nav.
 *
 * Offline: says how old the data on screen is (the oldest cached result any
 * query on the page is showing; a clock time rather than "5 minutes ago", so
 * it stays right without ticking) and how many reports are waiting to send.
 *
 * Back online with reports still waiting: says they are being sent.
 *
 * While any report is waiting, the browser is asked to warn before the tab
 * is closed or reloaded, because that would lose it.
 */
export function OfflineBanner() {
  const online = useOnline();
  const oldest = useSyncExternalStore(subscribeServed, oldestServed);
  const waiting = useHeldItems().filter((i) => i.status === "waiting").length;

  useEffect(() => {
    if (waiting === 0) return;
    const warn = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      // Older browsers need a return value to show the prompt.
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [waiting]);

  if (online && waiting === 0) return null;
  if (online) {
    return (
      <div
        role="status"
        className="bg-primary text-primary-foreground flex items-center justify-center gap-2 px-4 py-1.5 text-center text-xs font-medium"
      >
        <CloudUpload className="size-3.5 shrink-0" />
        <span>Back online. Sending {reports(waiting)}. Keep CircuitScout open.</span>
      </div>
    );
  }
  return (
    <div
      role="status"
      className="bg-destructive flex items-center justify-center gap-2 px-4 py-1.5 text-center text-xs font-medium text-white"
    >
      <CloudOff className="size-3.5 shrink-0" />
      <span>
        Offline.{" "}
        {oldest === null
          ? "New data will load when you reconnect."
          : `Showing data as of ${AS_OF.format(oldest)}.`}
        {waiting > 0 ? ` ${reports(waiting)} waiting to send.` : ""}
      </span>
    </div>
  );
}
EOF_FILE
echo "  wrote            src/components/offline-banner.tsx"

# ---- 3. Anchored edits -----------------------------------------------------
say "Forms and dashboards"
bun .patch-offline-held.mjs write

say "Done"
cat <<'TXT'
Next:
  1. bun run typecheck && bun run lint && bun run build
  2. Against a production build (bunx vite preview, or a Vercel preview):
     a. Sign in, open the Dashboard, then DevTools > Network > Offline.
     b. Pit Scouting: fill in a team and press "Save when back online". You
        return to the team list with a "Held on this device" message.
     c. The banner says "1 report waiting to send". The Dashboard has a
        "Waiting to send" card. Press View: the form opens with your answers.
     d. Change something and save again: still one entry, with the new answers.
     e. Do the same with a match report. View shows a summary of what you
        entered rather than an editable form.
     f. Go back online WITHOUT closing the tab. The banner turns to "Sending",
        a "Sent: ..." message appears for each, and the card empties.
  3. Reloading while something is waiting loses it, and the browser should
     warn you first. That is expected until the data transfer plan.
TXT
