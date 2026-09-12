#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-event-export.sh
#   "Download active event as xlsx" at the bottom of the dashboard.
#
#   Admins and team admins only — scouts never see it, and the queries refuse
#   them too. A full admin additionally gets a team chooser, listing only teams
#   that have people on the app AND an active event.
#
#   Team admins are on a 12-hour cooldown, enforced server-side and shown as a
#   countdown beside a greyed-out button. Per admin and per event: each event
#   carries its own timer, so swapping away and back does not clear one.
#
#   Four sheets: Pit scouting, Match scouting, Teams with stats,
#   Match list with stats.
#
# NEW DEPENDENCY: xlsx (SheetJS). Imported dynamically inside the click
# handler, so Vite splits it into its own chunk and nobody downloads ~1.5 MB
# unless they actually export.
#
# SCHEMA CHANGE: exportLog table (fifteenth addition).
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/dashboard.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Dependency"
bun add xlsx

say "Schema: exportLog"
cat > /tmp/xl.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
const TABLE = `  /**
   * The most recent export by one team admin, for one event. One row per
   * person per event, overwritten each time — only the latest matters, and an
   * unbounded download log is not worth the storage. Keeping the event in the
   * key is what lets each event carry its own cooldown, so moving between two
   * competitions does not hand anyone a fresh window on either.
   *
   * Full admins are never recorded; they have no cooldown.
   */
  exportLog: defineTable({
    profileId: v.id("profiles"),
    eventId: v.id("events"),
    at: v.number(),
  })
    .index("by_profile", ["profileId"])
    .index("by_profile_event", ["profileId", "eventId"]),

`;

if (s.includes("by_profile_event")) {
  console.log("  already patched");
  process.exit(0);
}

if (s.includes("exportLog")) {
  // Upgrade path: the table landed in an earlier run without the compound
  // index the per-event cooldown needs.
  const old = `  }).index("by_profile", ["profileId"]),`;
  if (!s.includes(old)) fail("exportLog exists but its index line does not match");
  s = s.replace(old, `  })
    .index("by_profile", ["profileId"])
    .index("by_profile_event", ["profileId", "eventId"]),`);
  writeFileSync(p, s);
  console.log("  convex/schema.ts upgraded (added by_profile_event)");
  process.exit(0);
}

const anchor = "  teams: defineTable({";
if (!s.includes(anchor)) fail("could not find the teams table");
s = s.replace(anchor, TABLE + anchor);
writeFileSync(p, s);
console.log("  convex/schema.ts patched");
MJS
bun /tmp/xl.mjs
rm -f /tmp/xl.mjs

say "Convex: workbook"
cat > convex/workbook.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import type { MutationCtx, QueryCtx } from "./_generated/server";
import { activeEventForTeam, currentProfile, requireTeamAdmin } from "./lib/guards";
import { derive, summarise } from "./lib/summarise";
import type { Doc, Id } from "./_generated/dataModel";

/** Twelve hours, for team admins only. */
const COOLDOWN_MS = 12 * 60 * 60 * 1000;

/**
 * When this person may export the active event again, as a timestamp, or null
 * for no wait.
 *
 * Keyed on profile AND event. Two team admins on one team each get their own
 * window, and each event keeps its own — swapping the active event away and
 * back does not clear a running timer, it just reveals whichever timer belongs
 * to the event now in front of you.
 */
async function cooldownUntil(
  ctx: QueryCtx | MutationCtx,
  profile: Doc<"profiles">,
): Promise<number | null> {
  if (profile.role !== "teamAdmin") return null;
  if (profile.teamNumber === undefined) return null;

  const event = await activeEventForTeam(ctx, profile.teamNumber);
  if (!event) return null;

  const last = await ctx.db
    .query("exportLog")
    .withIndex("by_profile_event", (q) =>
      q.eq("profileId", profile._id).eq("eventId", event._id))
    .unique();

  if (!last) return null;
  const until = last.at + COOLDOWN_MS;
  return until > Date.now() ? until : null;
}

/**
 * The client ticks its own countdown from this, so it returns a fixed
 * timestamp rather than a remaining duration — a duration would be stale the
 * moment the subscription stopped re-firing.
 */
export const cooldown = query({
  args: {},
  handler: async (ctx): Promise<{ until: number | null }> => {
    const profile = await currentProfile(ctx);
    if (!profile) return { until: null };
    return { until: await cooldownUntil(ctx, profile) };
  },
});

/**
 * Recorded after the file is actually produced, not before, so a failed build
 * does not cost someone twelve hours. The gate that matters is in forTeam:
 * the data cannot be fetched while the wait is running.
 */
export const recordExport = mutation({
  args: {},
  handler: async (ctx) => {
    const profile = await currentProfile(ctx);
    if (!profile || profile.role !== "teamAdmin") return;
    if (profile.teamNumber === undefined) return;
    const event = await activeEventForTeam(ctx, profile.teamNumber);
    if (!event) return;

    const existing = await ctx.db
      .query("exportLog")
      .withIndex("by_profile_event", (q) =>
        q.eq("profileId", profile._id).eq("eventId", event._id))
      .unique();

    if (existing) await ctx.db.patch(existing._id, { at: Date.now() });
    else {
      await ctx.db.insert("exportLog", {
        profileId: profile._id,
        eventId: event._id,
        at: Date.now(),
      });
    }
  },
});

/**
 * Teams a full admin may export for: at least one person on the app AND an
 * active event. A team missing either has nothing to export, and offering it
 * would only produce an empty workbook.
 *
 * Returns [] for everyone else, which is what hides the chooser — the dialog
 * renders the dropdown only when this is non-empty.
 */
export const eligibleTeams = query({
  args: {},
  handler: async (ctx) => {
    const me = await currentProfile(ctx);
    if (me?.role !== "admin") return [];

    const profiles = await ctx.db.query("profiles").collect();
    const members = new Map<number, number>();
    for (const p of profiles) {
      if (p.teamNumber === undefined) continue;
      members.set(p.teamNumber, (members.get(p.teamNumber) ?? 0) + 1);
    }

    const out = [];
    for (const [teamNumber, count] of [...members.entries()].sort((a, b) => a[0] - b[0])) {
      const event = await activeEventForTeam(ctx, teamNumber);
      if (!event) continue;
      out.push({
        teamNumber,
        members: count,
        eventName: event.name,
        eventKey: event.tbaEventKey,
      });
    }
    return out;
  },
});

/**
 * Everything the workbook needs, as plain rows. The browser turns these into
 * sheets — building the file server-side would mean shipping a spreadsheet
 * library into Convex for no gain.
 */
export const forTeam = query({
  args: { teamNumber: v.optional(v.number()) },
  handler: async (ctx, args) => {
    // Scouts have no use for this and the button is hidden from them, but the
    // refusal belongs here rather than only in the UI.
    const me = await requireTeamAdmin(ctx);

    // Your own team's event is yours to export. Someone else's is a cross-team
    // read, so that is full admin only.
    if (
      args.teamNumber !== undefined &&
      args.teamNumber !== me.teamNumber &&
      me.role !== "admin"
    ) {
      throw new Error("Admins only.");
    }

    const teamNumber = args.teamNumber ?? me.teamNumber;
    if (teamNumber === undefined) throw new Error("You are not on a team yet.");

    const until = await cooldownUntil(ctx, me);
    if (until !== null) {
      const mins = Math.ceil((until - Date.now()) / 60000);
      throw new Error(
        `You can export this event again in ${Math.floor(mins / 60)}h ${mins % 60}m.`,
      );
    }

    const event = await activeEventForTeam(ctx, teamNumber);
    if (!event) return null;

    const [reports, matches, teams, pit, epaRows, profiles] = await Promise.all([
      ctx.db.query("matchReports").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ctx.db.query("matches").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ctx.db.query("teams").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ctx.db.query("pitReports").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ctx.db.query("teamEpa").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ctx.db.query("profiles").collect(),
    ]);

    const teamById = new Map(teams.map((t) => [t._id, t]));
    const matchById = new Map(matches.map((m) => [m._id, m]));
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));
    const epaByNumber = new Map(epaRows.map((r) => [r.teamNumber, r]));

    const allianceOf = (report: Doc<"matchReports">) => {
      const team = teamById.get(report.teamId);
      const match = matchById.get(report.matchId);
      if (!team || !match) return "";
      return match.redTeamNumbers.includes(team.number) ? "red" : "blue";
    };
    const winnerFlag = (report: Doc<"matchReports">) => {
      if (report.autoWinner === null) return null;
      const side = allianceOf(report);
      return side === "" ? null : report.autoWinner === side;
    };

    // --- Pit scouting -------------------------------------------------------
    // Scoped to the chosen team. Pit reports are per scouting team by design;
    // match reports pool. Keeping that split here means the workbook says the
    // same thing the app does.
    const pitRows = pit
      .filter((p) => p.scoutingTeamNumber === teamNumber)
      .flatMap((p) => {
        const team = teamById.get(p.teamId);
        if (!team) return [];
        return [{
          team: team.number,
          nickname: team.nickname,
          scout: nameByUser.get(p.scoutId) ?? "",
          drivetrain: p.drivetrain,
          turret: p.scoring.turret,
          drumFullWidth: p.scoring.drumFullWidth,
          drumNarrow: p.scoring.drumNonFullWidth,
          fixedShooter: p.scoring.fixed,
          kitbot: p.scoring.kitbot,
          otherScoring: p.scoring.other ? p.scoring.otherText : "",
          climbLow: p.climb.low,
          climbMid: p.climb.mid,
          climbHigh: p.climb.high,
          climbAuto: p.climb.duringAuto,
          underTrench: p.underTrench,
          overBump: p.overBump,
          robotNotes: p.robotNotes,
          otherNotes: p.otherNotes,
        }];
      })
      .sort((a, b) => a.team - b.team);

    // --- Match scouting -----------------------------------------------------
    const reportRows = reports
      .flatMap((r) => {
        const team = teamById.get(r.teamId);
        const match = matchById.get(r.matchId);
        if (!team) return [];
        const d = derive(r, winnerFlag(r));
        return [{
          match: match?.matchNumber ?? "",
          team: team.number,
          nickname: team.nickname,
          alliance: allianceOf(r),
          scout: nameByUser.get(r.scoutId) ?? "",
          autoFuel: r.auto.fuel,
          autoClimbL1: r.auto.climbL1,
          autoFouls: r.auto.fouls,
          teleopCounted: d.counted,
          teleopDead: d.dead,
          transition: r.teleop.byShift.transition,
          s1: r.teleop.byShift.s1,
          s2: r.teleop.byShift.s2,
          s3: r.teleop.byShift.s3,
          s4: r.teleop.byShift.s4,
          endgameFuel: r.endgame.fuel,
          endgameClimb: r.endgame.climb,
          totalFuel: d.total,
          climbPoints: d.climb,
          driver: r.ratings.driver,
          defense: r.ratings.defense,
          accuracy: r.ratings.accuracy,
          avgBps: r.avgBps ?? "",
          adjustedBps: r.avgBps === undefined
            ? ""
            : Number((r.avgBps * (r.ratings.accuracy / 100)).toFixed(2)),
          shootsOnMove: r.ratings.shootsOnMove,
          broke: r.ratings.broke,
          inconsistent: r.ratings.inconsistent,
          autoWinner: r.autoWinner ?? "",
          hubStateSource: r.hubStateSource,
          finalNotes: r.finalNotes ?? "",
        }];
      })
      .sort((a, b) => Number(a.match) - Number(b.match) || a.team - b.team);

    // --- Teams with stats ---------------------------------------------------
    const byTeam = new Map<Id<"teams">, { report: Doc<"matchReports">; isAutoWinner: boolean | null }[]>();
    for (const r of reports) {
      const list = byTeam.get(r.teamId) ?? [];
      list.push({ report: r, isAutoWinner: winnerFlag(r) });
      byTeam.set(r.teamId, list);
    }
    const pitScouted = new Set(
      pit.filter((p) => p.scoutingTeamNumber === teamNumber).map((p) => p.teamId),
    );

    const summaryByNumber = new Map<number, ReturnType<typeof summarise>>();
    const teamRows = teams
      .sort((a, b) => a.number - b.number)
      .map((t) => {
        const s = summarise(byTeam.get(t._id) ?? []);
        summaryByNumber.set(t.number, s);
        const epa = epaByNumber.get(t.number);
        return {
          number: t.number,
          nickname: t.nickname,
          city: t.city,
          stateProv: t.stateProv,
          country: t.country,
          tbaTeamKey: t.tbaTeamKey,
          pitScouted: pitScouted.has(t._id),
          reportCount: s.reportCount,
          avgAutoFuel: s.avgAutoFuel,
          avgTeleopFuel: s.avgTeleopFuel,
          avgUncountedFuel: s.avgUncountedFuel,
          avgEndgameFuel: s.avgEndgameFuel,
          avgTotalFuel: s.avgTotalFuel,
          avgClimbPoints: s.avgClimbPoints,
          avgDriver: s.avgDriver,
          avgDefense: s.avgDefense,
          avgAccuracy: s.avgAccuracy,
          avgBps: s.avgBps,
          avgAdjustedBps: s.avgAdjustedBps,
          bpsReportCount: s.bpsReportCount,
          minTotalFuel: s.minTotalFuel,
          maxTotalFuel: s.maxTotalFuel,
          brokeCount: s.brokeCount,
          inconsistentCount: s.inconsistentCount,
          epa: epa?.epa ?? "",
          autoEpa: epa?.autoEpa ?? "",
          teleopEpa: epa?.teleopEpa ?? "",
          endgameEpa: epa?.endgameEpa ?? "",
        };
      });

    // --- Match list with stats ---------------------------------------------
    // Same projection the match preview shows, so the two never disagree:
    // avgTotalFuel + avgClimbPoints, summed over the alliance.
    const round1 = (n: number) => Number(n.toFixed(1));
    const projScouting = (nums: number[]) =>
      round1(nums.reduce((sum, n) => {
        const s = summaryByNumber.get(n);
        return sum + (s ? s.avgTotalFuel + s.avgClimbPoints : 0);
      }, 0));
    const projEpa = (nums: number[]) =>
      round1(nums.reduce((sum, n) => sum + (epaByNumber.get(n)?.epa ?? 0), 0));
    const reportsFor = (matchId: Id<"matches">, side: string) =>
      reports.filter((r) => r.matchId === matchId && allianceOf(r) === side).length;
    const stamp = (t: number | null | undefined) =>
      t === null || t === undefined ? "" : new Date(t).toISOString();

    const matchRows = matches
      .sort((a, b) => a.matchNumber - b.matchNumber)
      .map((m) => ({
        matchNumber: m.matchNumber,
        tbaMatchKey: m.tbaMatchKey,
        scheduledTime: stamp(m.scheduledTime),
        actualTime: stamp(m.actualTime),
        red1: m.redTeamNumbers[0] ?? "",
        red2: m.redTeamNumbers[1] ?? "",
        red3: m.redTeamNumbers[2] ?? "",
        blue1: m.blueTeamNumbers[0] ?? "",
        blue2: m.blueTeamNumbers[1] ?? "",
        blue3: m.blueTeamNumbers[2] ?? "",
        redScore: m.redScore ?? "",
        blueScore: m.blueScore ?? "",
        winningAlliance: m.winningAlliance ?? "",
        redProjScouting: projScouting(m.redTeamNumbers),
        blueProjScouting: projScouting(m.blueTeamNumbers),
        redProjEpa: projEpa(m.redTeamNumbers),
        blueProjEpa: projEpa(m.blueTeamNumbers),
        redReportsCollected: reportsFor(m._id, "red"),
        blueReportsCollected: reportsFor(m._id, "blue"),
      }));

    return {
      eventName: event.name,
      eventKey: event.tbaEventKey,
      teamNumber,
      pit: pitRows,
      matchReports: reportRows,
      teams: teamRows,
      matches: matchRows,
    };
  },
});
EOF
echo "convex/workbook.ts written"

say "Component: export dialog"
cat > src/components/event-export.tsx <<'EOF'
import { useConvex, useMutation, useQuery } from "convex/react";
import { ChevronDown, Download } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { api } from "../../convex/_generated/api";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import {
  Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";

const SHEETS = [
  ["pit", "Pit scouting"],
  ["matchReports", "Match scouting"],
  ["teams", "Teams with stats"],
  ["matches", "Match list with stats"],
] as const;

function formatLeft(ms: number) {
  const total = Math.max(0, Math.ceil(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const sec = total % 60;
  if (h > 0) return `${h}h ${String(m).padStart(2, "0")}m`;
  if (m > 0) return `${m}m ${String(sec).padStart(2, "0")}s`;
  return `${sec}s`;
}

export function EventExport() {
  const convex = useConvex();
  const me = useQuery(api.profiles.me);
  // Non-empty only for a full admin, which is what gates the chooser.
  const eligible = useQuery(api.workbook.eligibleTeams);
  const cooldown = useQuery(api.workbook.cooldown);
  const recordExport = useMutation(api.workbook.recordExport);

  const [now, setNow] = useState(() => Date.now());
  const [open, setOpen] = useState(false);
  const [pickerOpen, setPickerOpen] = useState(false);
  const [team, setTeam] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);

  const until = cooldown?.until ?? null;
  const waiting = until !== null && until > now;

  // Ticks only while there is something to count down.
  useEffect(() => {
    if (until === null || until <= Date.now()) return;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [until]);

  const choices = eligible ?? [];
  const chosen = choices.find((c) => c.teamNumber === team) ?? null;

  const download = async () => {
    setBusy(true);
    try {
      const data = await convex.query(api.workbook.forTeam, {
        teamNumber: team ?? undefined,
      });
      if (!data) {
        toast.error("No active event", {
          description: "That team has no event set up right now.",
        });
        return;
      }

      // Dynamic import: ~1.5 MB that nobody pays for until they export.
      const XLSX = await import("xlsx");
      const book = XLSX.utils.book_new();
      for (const [key, label] of SHEETS) {
        const rows = data[key];
        XLSX.utils.book_append_sheet(
          book,
          XLSX.utils.json_to_sheet(rows.length > 0 ? rows : [{}]),
          label,
        );
      }

      XLSX.writeFile(book, `circuitscout-${data.eventKey}-team${data.teamNumber}.xlsx`);
      // After the file exists, so a failure costs nobody their window.
      await recordExport({});
      toast.success("Downloaded", {
        description: `${data.teams.length} teams · ${data.matchReports.length} match reports · ${data.pit.length} pit reports.`,
      });
      setOpen(false);
    } catch (error) {
      toast.error("Could not build the workbook", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  // Scouts do not need this. A lead shares the file with their team once it
  // is downloaded.
  if (me === undefined) return null;
  if (me === null || (me.role !== "admin" && me.role !== "teamAdmin")) return null;

  return (
    <>
      <Card>
        <CardHeader>
          <CardTitle>Export</CardTitle>
          <CardDescription>
            Everything collected at the active event, as a spreadsheet. Useful
            for strategy work off the app, and a fallback when venue wifi fails.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-wrap items-center gap-3">
          <Button variant="outline" disabled={waiting} onClick={() => setOpen(true)}>
            <Download className="size-4" /> Download active event as xlsx
          </Button>
          {waiting ? (
            <span className="text-muted-foreground text-sm">
              Available in <span className="tabular-nums">{formatLeft(until - now)}</span> for this event
            </span>
          ) : null}
        </CardContent>
      </Card>

      <Dialog open={open} onOpenChange={(next) => { if (!next) setOpen(false); }}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Download event data as an xlsx spreadsheet?</DialogTitle>
            <DialogDescription>
              Four sheets: pit scouting, match scouting, teams with stats, and
              the match list with stats.
            </DialogDescription>
          </DialogHeader>

          {choices.length > 0 ? (
            <div className="space-y-1">
              <Button variant="outline" className="w-full justify-between"
                onClick={() => setPickerOpen(!pickerOpen)}>
                {chosen
                  ? `Team ${chosen.teamNumber} — ${chosen.eventName}`
                  : "Your team's active event"}
                <ChevronDown className={`size-4 transition-transform ${pickerOpen ? "rotate-180" : ""}`} />
              </Button>

              {pickerOpen ? (
                <div className="max-h-56 space-y-1 overflow-y-auto rounded-lg border p-2">
                  <Button variant={team === null ? "default" : "ghost"}
                    className="w-full justify-start"
                    onClick={() => { setTeam(null); setPickerOpen(false); }}>
                    Your team
                  </Button>
                  {choices.map((c) => (
                    <Button key={c.teamNumber}
                      variant={team === c.teamNumber ? "default" : "ghost"}
                      className="w-full justify-between"
                      onClick={() => { setTeam(c.teamNumber); setPickerOpen(false); }}>
                      <span>Team {c.teamNumber}</span>
                      <span className="text-muted-foreground truncate text-xs">
                        {c.eventName} · {c.members} on the app
                      </span>
                    </Button>
                  ))}
                </div>
              ) : null}

              <p className="text-muted-foreground text-xs">
                Only teams with people on the app and an active event appear here.
              </p>
            </div>
          ) : null}

          <div className="flex flex-wrap gap-2">
            <Button disabled={busy} onClick={() => void download()}>
              {busy ? "Building…" : "Download"}
            </Button>
            <Button variant="ghost" disabled={busy} onClick={() => setOpen(false)}>
              Cancel
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}
EOF
echo "src/components/event-export.tsx written"

say "Dashboard: mount it at the bottom"
cat > /tmp/ee.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/dashboard.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(`ABORT (${p} untouched): ${m}`); process.exit(1); };
if (s.includes("EventExport")) { console.log("already patched"); process.exit(0); }

const importAnchor = `import { ShiftRow } from "@/components/shift-picker";`;
if (!s.includes(importAnchor)) fail("could not find the shift-picker import");

const tail = `    </PageShell>
  );
}`;
if (!s.includes(tail)) fail("could not find the end of the page");

s = s.replace(importAnchor, `import { EventExport } from "@/components/event-export";
${importAnchor}`);

// Last thing on the page, as asked.
s = s.replace(tail, `      <EventExport />
${tail}`);

writeFileSync(p, s);
console.log("src/routes/dashboard.tsx patched");
MJS
bun /tmp/ee.mjs
rm -f /tmp/ee.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
