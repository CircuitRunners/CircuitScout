#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-lint.sh — clears the 12 ESLint problems (11 errors, 1 warning)
#   1. convex/events.ts: `let event` that is never reassigned -> `const`.
#   2. attention-items.tsx: KIND_LABEL is only used in its own file, so it is
#      no longer exported (fast refresh wants component files to export only
#      components).
#   3. ui/badge, ui/button, ui/tabs: shadcn files export their cva variants
#      by design and `shadcn add` would put them back, so eslint.config.js
#      turns react-refresh/only-export-components off for src/components/ui.
#   4. theme-toggle.tsx: the "mounted" flag comes from useSyncExternalStore
#      instead of a setState inside an effect. Same first-render behaviour.
#   5. Admin > deleted events: the "purged in N hours" count reads the clock
#      once when the page opens instead of calling Date.now() while rendering.
#   6. Pick list board: statFor is a useCallback and is listed as a
#      dependency of the board's useMemo (was a missing-dependency warning).
#   7. Pit form, profile page, match form (editing a report): the hydrate-once
#      step runs while rendering as soon as the data arrives, instead of in
#      an effect. Same rule (fill once, never stamp on edits); it also drops
#      the extra render that briefly showed the empty form.
#   8. Match form: the estimated match start (no Match Start tap) is set when
#      the scout moves to the Teleop tab, by the tab change itself, instead of
#      by an effect watching the tab.
#
# Client and lint config only. No Convex schema or function changes (events.ts
# changes one keyword), no dependency changes. Safe to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f vite.config.ts && -f convex/auth.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# ---- 1. Check everything before writing anything --------------------------
say "Checking"
trap 'rm -f .patch-lint.mjs .patch-lint.json' EXIT
cat > .patch-lint.json <<'EOF_JSON'
{
 "convex/events.ts": {
  "marker": "    const event = await ctx.db\n      .query(\"events\")\n      .withIndex(\"by_key\", (q) => q.eq(\"tbaEventKey\", args.tbaEventKey))\n      .unique();\n\n    let eventId: Id<\"events\">;",
  "edits": [
   {
    "old": "  handler: async (ctx, args) => {\n    let event = await ctx.db\n      .query(\"events\")\n",
    "new": "  handler: async (ctx, args) => {\n    const event = await ctx.db\n      .query(\"events\")\n"
   }
  ]
 },
 "eslint.config.js": {
  "marker": "'react-refresh/only-export-components': 'off'",
  "edits": [
   {
    "old": "  },\n])\n",
    "new": "  },\n  {\n    // shadcn/ui files export their cva variants next to the component by\n    // design, and `shadcn add` would put them back. Fast refresh still works\n    // for them; it just reloads the page for a change in one of these files.\n    files: ['src/components/ui/**/*.{ts,tsx}'],\n    rules: {\n      'react-refresh/only-export-components': 'off',\n    },\n  },\n])\n"
   }
  ]
 },
 "src/components/attention-items.tsx": {
  "marker": "\nconst KIND_LABEL = {",
  "edits": [
   {
    "old": "\nexport const KIND_LABEL = {\n  broke: \"Broke down\",\n",
    "new": "\nconst KIND_LABEL = {\n  broke: \"Broke down\",\n"
   }
  ]
 },
 "src/components/theme-toggle.tsx": {
  "marker": "const subscribeNothing = ",
  "edits": [
   {
    "old": "import { useEffect, useState } from \"react\";\nimport { useTheme } from \"next-themes\";\n",
    "new": "import { useSyncExternalStore } from \"react\";\nimport { useTheme } from \"next-themes\";\n"
   },
   {
    "old": "\nexport function ThemeToggle() {\n  const { theme, setTheme } = useTheme();\n  const [mounted, setMounted] = useState(false);\n\n  useEffect(() => setMounted(true), []);\n\n",
    "new": "\nconst subscribeNothing = () => () => {};\n\nexport function ThemeToggle() {\n  const { theme, setTheme } = useTheme();\n  // False for the first render only, so the icon never disagrees with the\n  // theme next-themes settles on. Same result as the old mount effect,\n  // without a second render triggered from inside an effect.\n  const mounted = useSyncExternalStore(subscribeNothing, () => true, () => false);\n\n"
   }
  ]
 },
 "src/routes/admin/index.tsx": {
  "marker": "const [now] = useState(() => Date.now());",
  "edits": [
   {
    "old": "  const [confirmKey, setConfirmKey] = useState(\"\");\n\n",
    "new": "  const [confirmKey, setConfirmKey] = useState(\"\");\n  // Read once when the page opens. Calling Date.now() while rendering gives a\n  // different answer every render; an hour count only needs a fixed moment.\n  const [now] = useState(() => Date.now());\n\n"
   },
   {
    "old": "                    0,\n                    Math.ceil((event.deletedAt! + 24 * 60 * 60 * 1000 - Date.now()) / 3600000),\n                  );\n",
    "new": "                    0,\n                    Math.ceil((event.deletedAt! + 24 * 60 * 60 * 1000 - now) / 3600000),\n                  );\n"
   }
  ]
 },
 "src/routes/picklists/board.tsx": {
  "marker": "const statFor = useCallback(",
  "edits": [
   {
    "old": "import { ArrowDownWideNarrow, ArrowLeft, ArrowUpNarrowWide } from \"lucide-react\";\nimport { useMemo, useState } from \"react\";\nimport { Link, useParams } from \"react-router\";\n",
    "new": "import { ArrowDownWideNarrow, ArrowLeft, ArrowUpNarrowWide } from \"lucide-react\";\nimport { useCallback, useMemo, useState } from \"react\";\nimport { Link, useParams } from \"react-router\";\n"
   },
   {
    "old": "\n  const statFor = (teamId: string): ChipStats | null => {\n    const s = stats?.[teamId];\n    return s ? (s as ChipStats) : null;\n  };\n\n",
    "new": "\n  const statFor = useCallback((teamId: string): ChipStats | null => {\n    const s = stats?.[teamId];\n    return s ? (s as ChipStats) : null;\n  }, [stats]);\n\n"
   },
   {
    "old": "    return map;\n  }, [entries, sort, stats, search, picked, showPicked, ranks]);\n\n",
    "new": "    return map;\n  }, [entries, sort, statFor, search, picked, showPicked, ranks]);\n\n"
   }
  ]
 },
 "src/routes/pit/form.tsx": {
  "marker": "const initial = ((): FormState => {",
  "edits": [
   {
    "old": "import { ArrowLeft, Camera, Plus, X } from \"lucide-react\";\nimport { useEffect, useRef, useState } from \"react\";\nimport { useNavigate, useParams } from \"react-router\";\n",
    "new": "import { ArrowLeft, Camera, Plus, X } from \"lucide-react\";\nimport { useRef, useState } from \"react\";\nimport { useNavigate, useParams } from \"react-router\";\n"
   },
   {
    "old": "\n  // Hydrate once. Re-hydrating on every query update would stamp on edits in\n  // progress each time another scout writes to the same event.\n  useEffect(() => {\n    if (loaded || data === undefined || data === null) return;\n    // Answers saved offline and not sent yet come first: they are newer than\n    // anything the server or the cache has.\n    const held = heldValues<FormState>(`pit:${data.team.number}`);\n    if (held) {\n      setForm(held);\n      setLoaded(true);\n      return;\n    }\n    const report = data.report;\n    if (report) {\n      setForm({\n        ...report.scoring,\n        ...report.climb,\n        drivetrainBase: report.drivetrain.split(\" — \")[0] ?? \"\",\n        drivetrainDetail: report.drivetrain.split(\" — \").slice(1).join(\" — \"),\n        underTrench: report.underTrench,\n        overBump: report.overBump,\n        robotNotes: report.robotNotes,\n        otherNotes: report.otherNotes,\n        hopperRoof: report.hopper?.roof ?? \"\",\n        hopperCapacity: report.hopper?.capacity?.toString() ?? \"\",\n        hopperExpanded: report.hopper?.expandedCapacity?.toString() ?? \"\",\n        drivetrainGearing: report.drivetrainGearing ?? \"\",\n        robotWeight: report.robotWeight?.toString() ?? \"\",\n        ...sparesFromReport(report.spares),\n        batteries: batteriesFromReport(report.batteries),\n      });\n    }\n    setLoaded(true);\n  }, [data, loaded]);\n\n",
    "new": "\n  // Hydrate once, while rendering, as soon as the data arrives. Re-hydrating\n  // on every query update would stamp on edits in progress each time another\n  // scout writes to the same event. (Setting state here rather than in an\n  // effect skips a wasted render with the blank form.)\n  if (!loaded && data !== undefined && data !== null) {\n    const initial = ((): FormState => {\n      // Answers saved offline and not sent yet come first: they are newer than\n      // anything the server or the cache has.\n      const held = heldValues<FormState>(`pit:${data.team.number}`);\n      if (held) return held;\n      const report = data.report;\n      if (report) {\n        return {\n          ...report.scoring,\n          ...report.climb,\n          drivetrainBase: report.drivetrain.split(\" — \")[0] ?? \"\",\n          drivetrainDetail: report.drivetrain.split(\" — \").slice(1).join(\" — \"),\n          underTrench: report.underTrench,\n          overBump: report.overBump,\n          robotNotes: report.robotNotes,\n          otherNotes: report.otherNotes,\n          hopperRoof: report.hopper?.roof ?? \"\",\n          hopperCapacity: report.hopper?.capacity?.toString() ?? \"\",\n          hopperExpanded: report.hopper?.expandedCapacity?.toString() ?? \"\",\n          drivetrainGearing: report.drivetrainGearing ?? \"\",\n          robotWeight: report.robotWeight?.toString() ?? \"\",\n          ...sparesFromReport(report.spares),\n          batteries: batteriesFromReport(report.batteries),\n        };\n      }\n      return BLANK;\n    })();\n    setForm(initial);\n    setLoaded(true);\n  }\n\n"
   }
  ]
 },
 "src/routes/profile.tsx": {
  "marker": "  if (!loaded && profile !== undefined && profile !== null) {",
  "edits": [
   {
    "old": "import { useAuthActions } from \"@convex-dev/auth/react\";\nimport { useEffect, useState } from \"react\";\nimport { toast } from \"sonner\";\n",
    "new": "import { useAuthActions } from \"@convex-dev/auth/react\";\nimport { useState } from \"react\";\nimport { toast } from \"sonner\";\n"
   },
   {
    "old": "\n  // Hydrate once. The query is live, so re-hydrating would overwrite what the\n  // person is typing every time anything else on their profile changed.\n  useEffect(() => {\n    if (loaded || profile === undefined || profile === null) return;\n    setFirstName(profile.firstName ?? \"\");\n",
    "new": "\n  // Hydrate once, while rendering, as soon as the profile arrives. The query is\n  // live, so re-hydrating would overwrite what the person is typing every time\n  // anything else on their profile changed.\n  if (!loaded && profile !== undefined && profile !== null) {\n    setFirstName(profile.firstName ?? \"\");\n"
   },
   {
    "old": "    setLoaded(true);\n  }, [profile, loaded]);\n\n",
    "new": "    setLoaded(true);\n  }\n\n"
   }
  ]
 },
 "src/routes/scout/form.tsx": {
  "marker": "const changePeriod = (next: typeof period) => {",
  "edits": [
   {
    "old": "import { AlertTriangle, ArrowLeft, ArrowRight, Play } from \"lucide-react\";\nimport { useEffect, useState } from \"react\";\nimport { useNavigate, useParams, useSearchParams } from \"react-router\";\n",
    "new": "import { AlertTriangle, ArrowLeft, ArrowRight, Play } from \"lucide-react\";\nimport { useState } from \"react\";\nimport { useNavigate, useParams, useSearchParams } from \"react-router\";\n"
   },
   {
    "old": "  const [showErrors, setShowErrors] = useState(false);\n  // Editing hydrates once. Convex queries are live, so re-hydrating would\n  // stamp on the correction in progress every time anything else changed.\n  useEffect(() => {\n    if (!editing || hydrated) return;\n    setStart(editing.auto.path.start);\n",
    "new": "  const [showErrors, setShowErrors] = useState(false);\n  // Editing hydrates once, while rendering, as soon as the report arrives.\n  // Convex queries are live, so re-hydrating would stamp on the correction in\n  // progress every time anything else changed.\n  if (editing && !hydrated) {\n    setStart(editing.auto.path.start);\n"
   },
   {
    "old": "    setHydrated(true);\n  }, [editing, hydrated]);\n\n  // No Match Start tap: anchor on the first look at teleop. Shifts are 25s, so\n  // a few seconds of drift only misclassifies fuel near a boundary.\n  useEffect(() => {\n    if (editId) return;\n    if (period === \"teleop\" && startedAt === null) {\n      setStartedAt(estimatedStart());\n",
    "new": "    setHydrated(true);\n  }\n\n  // Every tab change goes through here. No Match Start tap: anchor on the\n  // first look at teleop. Shifts are 25s, so a few seconds of drift only\n  // misclassifies fuel near a boundary.\n  const changePeriod = (next: typeof period) => {\n    setPeriod(next);\n    if (!editId && next === \"teleop\" && startedAt === null) {\n      setStartedAt(estimatedStart());\n"
   },
   {
    "old": "    }\n  }, [period, startedAt, editId]);\n\n",
    "new": "    }\n  };\n\n"
   },
   {
    "old": "  const goTo = (next: typeof period) => {\n    setPeriod(next);\n    // The switch buttons sit at the bottom of a tab; land at the top of the next.\n",
    "new": "  const goTo = (next: typeof period) => {\n    changePeriod(next);\n    // The switch buttons sit at the bottom of a tab; land at the top of the next.\n"
   },
   {
    "old": "\n      <Tabs value={period} onValueChange={(v) => setPeriod(v as typeof period)}>\n        <TabsList id=\"match-form-tabs\" className=\"w-full scroll-mt-4\">\n",
    "new": "\n      <Tabs value={period} onValueChange={(v) => changePeriod(v as typeof period)}>\n        <TabsList id=\"match-form-tabs\" className=\"w-full scroll-mt-4\">\n"
   }
  ]
 }
}
EOF_JSON

cat > .patch-lint.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";

const mode = process.argv[2]; // "check" | "write"
const plan = JSON.parse(readFileSync(".patch-lint.json", "utf8"));
const staged = [];
let already = 0;

for (const [path, { marker, edits }] of Object.entries(plan)) {
  let source;
  try {
    source = readFileSync(path, "utf8").replace(/\r\n/g, "\n");
  } catch {
    throw new Error(`${path} is missing`);
  }
  if (source.includes(marker)) {
    already += 1;
    console.log(`  already applied  ${path}`);
    continue;
  }
  for (const { old, new: next } of edits) {
    const found = source.split(old).length - 1;
    if (found !== 1) {
      throw new Error(
        `${path} is not the version this patch expects (${found === 0 ? "not found" : "found more than once"}):\n` +
        old.split("\n").slice(0, 4).join("\n"),
      );
    }
    source = source.replace(old, () => next);
  }
  if (!source.includes(marker)) throw new Error(`${path}: the edit did not take`);
  staged.push([path, source]);
}

for (const [path, source] of staged) {
  if (mode === "write") {
    writeFileSync(path, source);
    console.log(`  patched          ${path}`);
  } else console.log(`  ok               ${path}`);
}
if (mode === "write" && staged.length === 0 && already > 0) console.log("  nothing to do");
MJS
bun .patch-lint.mjs check || { echo "ERROR: nothing was changed" >&2; exit 1; }

# ---- 2. Edits --------------------------------------------------------------
say "Lint fixes"
bun .patch-lint.mjs write

say "Done"
cat <<'TXT'
Next:
  1. bun run lint && bun run typecheck && bunx tsc -p convex
     Lint should finish with no problems.
  2. bun run go, then check the spots that changed behaviour-wise:
     a. Profile: the name and team fields fill in on load; edit one and it
        is not overwritten while you type.
     b. Pit form: open a scouted team, the answers load; open an unscouted
        team, the form is blank.
     c. Match form, new report: go to Teleop without tapping Match Start;
        the estimated start is set as before.
     d. Admin: edit a match report from the report list; every field fills
        in, including the auto path.
     e. Theme toggle still cycles light / dark / system.
TXT
