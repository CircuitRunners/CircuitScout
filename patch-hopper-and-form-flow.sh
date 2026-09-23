#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-hopper-and-form-flow.sh
#
#   1. Pit form: "Hopper capacity" inside the Scoring capability card.
#      Roof type (solid / expanding solid / net / no roof), max capacity not
#      expanded, and max capacity expanded — the last only shown when the roof
#      is expanding solid or net. Stored as an optional `hopper` field on
#      pitReports, so every existing report still validates.
#
#   2. Match form: a "Switch to Teleop" button under the auto-winner selector.
#
#   3. Match form: "Hopper Capacity: _, Expanded Hopper Capacity: _" under the
#      Auto scoring and Teleop headings, read from YOUR team's pit report for
#      that robot. Expanded only appears for expanding/net roofs. Nothing at
#      all when the robot has no pit report or its hopper was left blank.
#
#   4. Match form always opens on Auto. The tab used to live in the Zustand
#      store, which outlives the page, so the next match reopened wherever the
#      last one was left. It is local state now and the store field is gone.
#      (It also stops a stale "teleop" tab from stamping an estimated match
#      start on a form the scout has not even looked at yet.)
#
#   5. Sort by passing everywhere sorting exists: the pick list board's
#      "Sort Uncategorized" row and the archived-event team table (which also
#      gains a Passing column so the sort is visible).
#
#   6. Hopper shown in the team detail modal's pit report ("Hopper: Net roof ·
#      holds 40 · 55 expanded") and as three columns on the xlsx export's pit
#      sheet (hopperRoof, hopperCapacity, hopperExpandedCapacity).
#
#   7. Teams page: a Sort dropdown beside "No match data" — team number
#      (default), fuel, climb, passing, defense, driver. Stats are only
#      subscribed while a stat sort is chosen.
#
# All anchors are checked across every file BEFORE anything is written: if one
# misses, no file is touched. Safe to re-run; already-patched files are skipped.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/scout/form.tsx && -f convex/pit.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
runjs() { if command -v bun >/dev/null 2>&1; then bun "$1"; else node "$1"; fi; }

say "Hopper capacity, Switch to Teleop, Auto-first tabs, sorting"
cat > /tmp/cs-hopper.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";

const pending = [];
let failed = false;

function edit(path, marker, fn) {
  const original = readFileSync(path, "utf8");
  if (original.includes(marker)) { console.log(`  ${path}: already patched`); return; }
  let s = original;
  const replace = (needle, next, what) => {
    const n = s.split(needle).length - 1;
    if (n !== 1) {
      console.error(`  ABORT: ${path}: ${what} matched ${n} times (expected 1)`);
      failed = true;
      return;
    }
    s = s.replace(needle, () => next);
  };
  fn(replace);
  if (!s.includes(marker)) {
    console.error(`  ABORT: ${path}: marker missing after edits`);
    failed = true;
  }
  pending.push([path, s]);
}

// ---------------------------------------------------------------- schema ---
edit("convex/schema.ts", "hopper: v.optional(v.object({", (r) => {
  r(`    otherNotes: v.string(),
    photoId: v.union(v.id("_storage"), v.null()),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"])
    // Each scouting team's own pit reports.`,
  `    otherNotes: v.string(),
    photoId: v.union(v.id("_storage"), v.null()),
    /** The pit form's hopper section. Optional: reports written before it
     *  existed have none. expandedCapacity is only kept for expanding/net
     *  roofs; the upsert nulls it for anything else. */
    hopper: v.optional(v.object({
      roof: v.union(
        v.literal("solid"), v.literal("expanding"), v.literal("net"),
        v.literal("none"), v.null(),
      ),
      capacity: v.union(v.number(), v.null()),
      expandedCapacity: v.union(v.number(), v.null()),
    })),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"])
    // Each scouting team's own pit reports.`,
  "the pitReports table tail");
});

// ------------------------------------------------------------- convex/pit ---
edit("convex/pit.ts", "cleanHopper", (r) => {
  r(`import { v } from "convex/values";`,
    `import { v, type Infer } from "convex/values";`,
    "the convex/values import");

  r(`const climbInput = v.object({
  low: v.boolean(),
  mid: v.boolean(),
  high: v.boolean(),
  duringAuto: v.boolean(),
});
`,
  `const climbInput = v.object({
  low: v.boolean(),
  mid: v.boolean(),
  high: v.boolean(),
  duringAuto: v.boolean(),
});

const hopperInput = v.object({
  roof: v.union(
    v.literal("solid"), v.literal("expanding"), v.literal("net"),
    v.literal("none"), v.null(),
  ),
  capacity: v.union(v.number(), v.null()),
  expandedCapacity: v.union(v.number(), v.null()),
});

/** Whole numbers only, and an expanded capacity only where the roof expands. */
function cleanHopper(h: Infer<typeof hopperInput>): Infer<typeof hopperInput> {
  const count = (n: number | null, what: string): number | null => {
    if (n === null) return null;
    if (!Number.isInteger(n) || n < 0 || n > 999) {
      throw new Error(\`\${what} must be a whole number from 0 to 999.\`);
    }
    return n;
  };
  const expands = h.roof === "expanding" || h.roof === "net";
  return {
    roof: h.roof,
    capacity: count(h.capacity, "Hopper capacity"),
    expandedCapacity: expands
      ? count(h.expandedCapacity, "Expanded hopper capacity")
      : null,
  };
}
`,
  "the climbInput validator");

  // The match form reads the same per-team report, so share the lookup.
  r(`async function mine(`, `export async function mine(`, "the mine() helper");

  r(`    photoId: v.union(v.id("_storage"), v.null()),
  },
  handler: async (ctx, args) => {`,
  `    photoId: v.union(v.id("_storage"), v.null()),
    // Optional so a phone still running the old bundle can save mid-event.
    hopper: v.optional(hopperInput),
  },
  handler: async (ctx, args) => {`,
  "the upsert args");

  r(`      photoId: args.photoId ?? existing?.photoId ?? null,
`,
  `      photoId: args.photoId ?? existing?.photoId ?? null,
      // An old client that sends no hopper keeps whatever is stored.
      hopper: args.hopper ? cleanHopper(args.hopper) : existing?.hopper,
`,
  "the photoId field line");
});

// ---------------------------------------------------- convex/matchReports ---
edit("convex/matchReports.ts", "myPitReport", (r) => {
  r(`import { activeEvent, requireUser } from "./lib/guards";
`,
  `import { activeEvent, requireUser } from "./lib/guards";
import { mine as myPitReport } from "./pit";
`,
  "the guards import");

  r(`    const onRed = match.redTeamNumbers.includes(team.number);
    return {
      match,
      team,
      myReport,
      othersCount: existing.length - (myReport ? 1 : 0),
      alliance: onRed ? "red" : "blue",
    };`,
  `    const onRed = match.redTeamNumbers.includes(team.number);

    // This scouting team's own pit report, same as the pit page shows. null
    // means not pit scouted, and the form shows no hopper line at all.
    const pit = await myPitReport(ctx, event._id, team._id);
    const expands = pit?.hopper?.roof === "expanding" || pit?.hopper?.roof === "net";
    const hopper = pit
      ? {
          capacity: pit.hopper?.capacity ?? null,
          expandedCapacity: expands ? (pit.hopper?.expandedCapacity ?? null) : null,
        }
      : null;

    return {
      match,
      team,
      myReport,
      othersCount: existing.length - (myReport ? 1 : 0),
      alliance: onRed ? "red" : "blue",
      hopper,
    };`,
  "the forMatchAndTeam return");
});

// ------------------------------------------------------------- pit form ---
edit("src/routes/pit/form.tsx", "HOPPER_ROOFS", (r) => {
  r(`const DRIVETRAINS = ["Swerve", "Tank / WCD", "Mecanum", "Other"] as const;
`,
  `const DRIVETRAINS = ["Swerve", "Tank / WCD", "Mecanum", "Other"] as const;

type HopperRoof = "solid" | "expanding" | "net" | "none";

const HOPPER_ROOFS: ReadonlyArray<{ value: HopperRoof; label: string }> = [
  { value: "solid", label: "Solid" },
  { value: "expanding", label: "Expanding solid" },
  { value: "net", label: "Net" },
  { value: "none", label: "No roof" },
];

const roofExpands = (roof: HopperRoof | "") => roof === "expanding" || roof === "net";
/** Digits only, three at most: a phone keyboard can still slip in a "." or "-". */
const digitsOnly = (text: string) => text.replace(/\\D/g, "").slice(0, 3);
const toCount = (text: string) => (text === "" ? null : Number.parseInt(text, 10));
`,
  "the DRIVETRAINS const");

  r(`  otherText: string;
  low: boolean;`,
  `  otherText: string;
  hopperRoof: HopperRoof | "";
  hopperCapacity: string;
  hopperExpanded: string;
  low: boolean;`,
  "the FormState otherText field");

  r(`  kitbot: false, other: false, otherText: "",
`,
  `  kitbot: false, other: false, otherText: "",
  hopperRoof: "", hopperCapacity: "", hopperExpanded: "",
`,
  "the BLANK scoring line");

  r(`        otherNotes: report.otherNotes,
      });`,
  `        otherNotes: report.otherNotes,
        hopperRoof: report.hopper?.roof ?? "",
        hopperCapacity: report.hopper?.capacity?.toString() ?? "",
        hopperExpanded: report.hopper?.expandedCapacity?.toString() ?? "",
      });`,
  "the hydrate setForm tail");

  r(`        otherNotes: form.otherNotes,
        photoId,`,
  `        otherNotes: form.otherNotes,
        photoId,
        hopper: {
          roof: form.hopperRoof === "" ? null : form.hopperRoof,
          capacity: toCount(form.hopperCapacity),
          expandedCapacity: roofExpands(form.hopperRoof)
            ? toCount(form.hopperExpanded)
            : null,
        },`,
  "the upsert payload tail");

  r(`              onChange={(e) => set("otherText", e.target.value)}
            />
          ) : null}
        </CardContent>`,
  `              onChange={(e) => set("otherText", e.target.value)}
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
        </CardContent>`,
  "the end of the scoring capability card");
});

// ----------------------------------------------------------- match form ---
edit("src/routes/scout/form.tsx", "hopperLine", (r) => {
  r(`import { AlertTriangle, ArrowLeft, LoaderCircle, Play } from "lucide-react";`,
    `import { AlertTriangle, ArrowLeft, ArrowRight, LoaderCircle, Play } from "lucide-react";`,
    "the lucide import");

  r(`import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";`,
    `import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";`,
    "the card import");

  r(`import { useUIStore } from "@/stores/ui-store";
`, ``, "the ui-store import");

  r(`  const period = useUIStore((s) => s.matchFormPeriod);
  const setPeriod = useUIStore((s) => s.setMatchFormPeriod);`,
  `  // Local state, not the UI store: every match opens on Auto rather than on
  // whichever tab the previous one was left on.
  const [period, setPeriod] = useState<"auto" | "teleop" | "conclusion">("auto");`,
  "the period store lines");

  r(`  const suspicious = dead > counted && dead > 0;
`,
  `  const suspicious = dead > counted && dead > 0;

  // From this scouting team's own pit report. No line at all when the robot
  // was never pit scouted or its hopper capacity was left blank.
  const hopper = data?.hopper ?? null;
  const hopperLine =
    hopper && hopper.capacity !== null
      ? \`Hopper Capacity: \${hopper.capacity}\`
        + (hopper.expandedCapacity !== null
          ? \`, Expanded Hopper Capacity: \${hopper.expandedCapacity}\`
          : "")
      : null;

  const goToTeleop = () => {
    setPeriod("teleop");
    // The winner card sits at the bottom of Auto; land at the top of Teleop.
    document.getElementById("match-form-tabs")
      ?.scrollIntoView({ block: "start", behavior: "smooth" });
  };
`,
  "the suspicious line");

  r(`        <TabsList className="w-full">`,
    `        <TabsList id="match-form-tabs" className="w-full scroll-mt-4">`,
    "the TabsList");

  r(`            <CardHeader><CardTitle>Auto scoring</CardTitle></CardHeader>`,
    `            <CardHeader>
              <CardTitle>Auto scoring</CardTitle>
              {hopperLine ? <CardDescription>{hopperLine}</CardDescription> : null}
            </CardHeader>`,
    "the Auto scoring header");

  r(`            <CardHeader><CardTitle>Teleop</CardTitle></CardHeader>`,
    `            <CardHeader>
              <CardTitle>Teleop</CardTitle>
              {hopperLine ? <CardDescription>{hopperLine}</CardDescription> : null}
            </CardHeader>`,
    "the Teleop header");

  r(`              ) : null}
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="teleop"`,
  `              ) : null}
              <Button variant="outline" className="h-12 w-full" onClick={goToTeleop}>
                Switch to Teleop
                <ArrowRight className="size-4" />
              </Button>
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="teleop"`,
  "the end of the auto winner card");
});

// ------------------------------------------------------------- ui store ---
edit("src/stores/ui-store.ts", `| "passing"`, (r) => {
  r(`export type SortKey = "totalFuel" | "climbPoints" | "defense" | "driver";`,
    `export type SortKey = "totalFuel" | "climbPoints" | "passing" | "defense" | "driver";`,
    "the SortKey type");
  r(`  matchFormPeriod: "auto" | "teleop" | "conclusion";
`, ``, "the matchFormPeriod state field");
  r(`  setMatchFormPeriod: (period: UIState["matchFormPeriod"]) => void;
`, ``, "the setMatchFormPeriod action type");
  r(`  matchFormPeriod: "auto",
`, ``, "the matchFormPeriod initial value");
  r(`  setMatchFormPeriod: (matchFormPeriod) => set({ matchFormPeriod }),
`, ``, "the setMatchFormPeriod implementation");
});

// ------------------------------------------------------- pick list board ---
edit("src/routes/picklists/team-chip.tsx", "avgPassing", (r) => {
  r(`  avgClimbPoints: number;
`, `  avgClimbPoints: number;
  avgPassing: number;
`, "the ChipStats avgClimbPoints field");
});

edit("src/routes/picklists/board.tsx", `case "passing"`, (r) => {
  r(`  { key: "climbPoints", label: "Climb" },
`, `  { key: "climbPoints", label: "Climb" },
  { key: "passing", label: "Passing" },
`, "the SORTS climb entry");
  r(`            case "climbPoints": return s.avgClimbPoints;
`, `            case "climbPoints": return s.avgClimbPoints;
            case "passing": return s.avgPassing;
`, "the sort value switch");
});

// --------------------------------------------------------- archive table ---
edit("src/routes/archive/event.tsx", `"passing"`, (r) => {
  r(`type SortKey = "number" | "totalFuel" | "climbPoints" | "driver" | "defense";`,
    `type SortKey = "number" | "totalFuel" | "climbPoints" | "passing" | "driver" | "defense";`,
    "the SortKey type");
  r(`  { key: "climbPoints", label: "Climb" },
`, `  { key: "climbPoints", label: "Climb" },
  { key: "passing", label: "Passing" },
`, "the COLUMNS climb entry");
  r(`        case "climbPoints": return b.stats.avgClimbPoints - a.stats.avgClimbPoints;
`, `        case "climbPoints": return b.stats.avgClimbPoints - a.stats.avgClimbPoints;
        case "passing": return b.stats.avgPassing - a.stats.avgPassing;
`, "the sort switch");
  r(`              <th className="p-3 text-right font-medium">Climb</th>
`, `              <th className="p-3 text-right font-medium">Climb</th>
              <th className="p-3 text-right font-medium">Passing</th>
`, "the Climb header cell");
  r(`                  {row.stats.reportCount === 0 ? "—" : row.stats.avgClimbPoints.toFixed(1)}
                </td>
`, `                  {row.stats.reportCount === 0 ? "—" : row.stats.avgClimbPoints.toFixed(1)}
                </td>
                <td className="p-3 text-right tabular-nums">
                  {row.stats.reportCount === 0 ? "—" : row.stats.avgPassing.toFixed(1)}
                </td>
`, "the Climb body cell");
});

// ------------------------------------------------------ team detail modal ---
edit("src/routes/teams/team-detail.tsx", "hopperSummary", (r) => {
  r(`import { AlertTriangle, Pencil, Wrench } from "lucide-react";`,
    `import { AlertTriangle, Package, Pencil, Wrench } from "lucide-react";`,
    "the lucide import");

  r(`function Stat({`,
  `const ROOF_LABELS = {
  solid: "Solid roof",
  expanding: "Expanding solid roof",
  net: "Net roof",
  none: "No roof",
} as const;

type HopperRecord = {
  roof: keyof typeof ROOF_LABELS | null;
  capacity: number | null;
  expandedCapacity: number | null;
};

/** One line, or null when the pit scout left the whole section blank. */
function hopperSummary(h: HopperRecord | undefined): string | null {
  if (!h) return null;
  const parts: string[] = [];
  if (h.roof) parts.push(ROOF_LABELS[h.roof]);
  if (h.capacity !== null) parts.push(\`holds \${h.capacity}\`);
  const expands = h.roof === "expanding" || h.roof === "net";
  if (expands && h.expandedCapacity !== null) parts.push(\`\${h.expandedCapacity} expanded\`);
  return parts.length > 0 ? \`Hopper: \${parts.join(" · ")}\` : null;
}

function Stat({`,
  "the Stat component");

  r(`                <p className="text-sm">
                  <Wrench className="mr-1 inline size-3" />`,
  `                {hopperSummary(data.pitReport.hopper) ? (
                  <p className="text-sm">
                    <Package className="mr-1 inline size-3" />
                    {hopperSummary(data.pitReport.hopper)}
                  </p>
                ) : null}
                <p className="text-sm">
                  <Wrench className="mr-1 inline size-3" />`,
  "the drivetrain line");
});

// ------------------------------------------------------ xlsx pit sheet ---
edit("convex/workbook.ts", "hopperRoof:", (r) => {
  r(`          otherScoring: p.scoring.other ? p.scoring.otherText : "",
`,
  `          otherScoring: p.scoring.other ? p.scoring.otherText : "",
          // Blank cells, not zeros, for reports written before the hopper
          // section existed or where the scout left it empty.
          hopperRoof: p.hopper?.roof ? HOPPER_ROOF_LABELS[p.hopper.roof] : "",
          hopperCapacity: p.hopper?.capacity ?? "",
          hopperExpandedCapacity:
            p.hopper?.roof === "expanding" || p.hopper?.roof === "net"
              ? (p.hopper.expandedCapacity ?? "")
              : "",
`,
  "the otherScoring column");

  r(`import type { Doc, Id } from "./_generated/dataModel";
`,
  `import type { Doc, Id } from "./_generated/dataModel";

const HOPPER_ROOF_LABELS = {
  solid: "Solid",
  expanding: "Expanding solid",
  net: "Net",
  none: "No roof",
} as const;
`,
  "the dataModel import");
});

// ---------------------------------------------------------- teams page ---
edit("src/routes/teams/index.tsx", "TEAM_SORTS", (r) => {
  r(`import { useMemo, useState } from "react";`,
    `import { ChevronDown } from "lucide-react";
import { useMemo, useState } from "react";`,
    "the react import");

  r(`import { Button } from "@/components/ui/button";
`,
  `import { Button } from "@/components/ui/button";
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuRadioGroup,
  DropdownMenuRadioItem, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
`,
  "the button import");

  r(`export default function TeamsPage() {`,
  `type TeamSort = "number" | "totalFuel" | "climbPoints" | "passing" | "defense" | "driver";

/** Team number ascending; every stat highest first. */
const TEAM_SORTS: ReadonlyArray<{ value: TeamSort; label: string }> = [
  { value: "number", label: "Team number" },
  { value: "totalFuel", label: "Fuel" },
  { value: "climbPoints", label: "Climb" },
  { value: "passing", label: "Passing" },
  { value: "defense", label: "Defense" },
  { value: "driver", label: "Driver" },
];

export default function TeamsPage() {`,
  "the TeamsPage signature");

  r(`  const [filter, setFilter] = useState<Filter>("all");
`,
  `  const [filter, setFilter] = useState<Filter>("all");
  const [sort, setSort] = useState<TeamSort>("number");
  // Only subscribed while a stat sort is chosen; team-number order needs none.
  const stats = useQuery(api.stats.forEvent, sort === "number" ? "skip" : {});
`,
  "the filter state");

  r(`  const open = (teamNumber: number) => {`,
  `  // Until stats arrive the list stays in team-number order rather than
  // flashing an empty page.
  const sorted = useMemo(() => {
    if (sort === "number" || !stats) return shown;
    const value = (teamId: string): number => {
      const s = stats[teamId];
      if (!s) return -1;
      switch (sort) {
        case "totalFuel": return s.avgTotalFuel;
        case "climbPoints": return s.avgClimbPoints;
        case "passing": return s.avgPassing;
        case "defense": return s.avgDefense;
        case "driver": return s.avgDriver;
      }
    };
    return [...shown].sort((a, b) => value(b._id) - value(a._id) || a.number - b.number);
  }, [shown, sort, stats]);

  const sortLabel = TEAM_SORTS.find((s) => s.value === sort)?.label ?? "";

  const open = (teamNumber: number) => {`,
  "the open() helper");

  r(`          );
        })}
        <Input
          className="ml-auto max-w-56"`,
  `          );
        })}
        <DropdownMenu>
          <DropdownMenuTrigger
            render={<Button size="sm" variant={sort === "number" ? "outline" : "default"} />}
          >
            {sort === "number" ? "Sort" : \`Sort: \${sortLabel}\`}
            <ChevronDown className="size-3" />
          </DropdownMenuTrigger>
          <DropdownMenuContent className="min-w-40">
            <DropdownMenuRadioGroup
              value={sort}
              onValueChange={(value) => setSort(value as TeamSort)}
            >
              {TEAM_SORTS.map((s) => (
                <DropdownMenuRadioItem key={s.value} value={s.value} className="py-2.5">
                  {s.label}
                </DropdownMenuRadioItem>
              ))}
            </DropdownMenuRadioGroup>
          </DropdownMenuContent>
        </DropdownMenu>
        <Input
          className="ml-auto max-w-56"`,
  "the end of the filter buttons");

  r(`          {shown.map((team) => (`,
    `          {sorted.map((team) => (`,
    "the team list map");
});

if (failed) {
  console.error("\nNothing was written. Paste the ABORT lines back to Claude.");
  process.exit(1);
}
for (const [path, s] of pending) {
  writeFileSync(path, s);
  console.log(`  ${path}: patched`);
}
MJS
runjs /tmp/cs-hopper.mjs
rm -f /tmp/cs-hopper.mjs

say "Done"
echo "If 'bun run go' is running, Convex pushes the schema change on its own."
echo "Otherwise run: bunx convex dev --once"
