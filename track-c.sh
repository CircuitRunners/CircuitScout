#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# track-c.sh — Track C: match scouting (landing, claims, match form).
# Run from the REPO ROOT in Git Bash. Run ONCE; after that edit files directly.
# Owns: convex/claims.ts, convex/matchReports.ts, convex/hub.ts,
#       src/routes/scout/*
# Does NOT touch convex/schema.ts (frozen) or any other track's files.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f package.json ]] || { echo "ERROR: run from the folder with package.json" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

mkdir -p convex src/routes/scout

say "Convex: claims"
cat > convex/claims.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent, requireUser } from "./lib/guards";

/**
 * A scout who opens the form and wanders off must not lock that robot for the
 * rest of the event. Claims expire; an expired claim is free to take.
 */
export const CLAIM_TTL_MS = 20 * 60 * 1000;

export const mine = query({
  args: {},
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const now = Date.now();
    const claims = await ctx.db
      .query("matchClaims")
      .withIndex("by_scout", (q) => q.eq("scoutId", userId))
      .collect();

    const live = claims.filter((c) => c.expiresAt > now);
    return await Promise.all(
      live.map(async (c) => ({
        ...c,
        match: await ctx.db.get(c.matchId),
        team: await ctx.db.get(c.teamId),
      })),
    );
  },
});

/** Which robots in a match are already taken, so the selector can grey them. */
export const forMatchNumber = query({
  args: { matchNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return [];

    const match = await ctx.db
      .query("matches")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("matchNumber", args.matchNumber))
      .unique();
    if (!match) return [];

    const now = Date.now();
    const claims = await ctx.db
      .query("matchClaims")
      .withIndex("by_match_team", (q) => q.eq("matchId", match._id))
      .collect();

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_match", (q) => q.eq("matchId", match._id))
      .collect();

    return [
      ...claims
        .filter((c) => c.expiresAt > now)
        .map((c) => ({ teamId: c.teamId, scoutId: c.scoutId, state: "claimed" as const })),
      ...reports.map((r) => ({
        teamId: r.teamId, scoutId: r.scoutId, state: "submitted" as const,
      })),
    ];
  },
});

/**
 * Convex mutations are serializable, so the by_match_team read-then-write here
 * is genuinely race-free. Two scouts tapping the same robot at the same moment
 * cannot both succeed — no extra locking needed.
 */
export const claim = mutation({
  args: { matchId: v.id("matches"), teamId: v.id("teams") },
  handler: async (ctx, args) => {
    const scoutId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");
    const now = Date.now();

    const existing = await ctx.db
      .query("matchClaims")
      .withIndex("by_match_team", (q) =>
        q.eq("matchId", args.matchId).eq("teamId", args.teamId))
      .unique();

    if (existing) {
      if (existing.scoutId !== scoutId && existing.expiresAt > now) {
        throw new Error("Another scout is already covering that robot.");
      }
      await ctx.db.patch(existing._id, {
        scoutId, claimedAt: now, expiresAt: now + CLAIM_TTL_MS,
      });
      return existing._id;
    }

    return await ctx.db.insert("matchClaims", {
      eventId: event._id,
      matchId: args.matchId,
      teamId: args.teamId,
      scoutId,
      claimedAt: now,
      expiresAt: now + CLAIM_TTL_MS,
    });
  },
});

export const release = mutation({
  args: { matchId: v.id("matches"), teamId: v.id("teams") },
  handler: async (ctx, args) => {
    const scoutId = await requireUser(ctx);
    const existing = await ctx.db
      .query("matchClaims")
      .withIndex("by_match_team", (q) =>
        q.eq("matchId", args.matchId).eq("teamId", args.teamId))
      .unique();
    if (existing && existing.scoutId === scoutId) {
      await ctx.db.delete(existing._id);
    }
  },
});
EOF

say "Convex: hub reconciliation"
cat > convex/hub.ts <<'EOF'
import { v } from "convex/values";
import { query } from "./_generated/server";

/**
 * The alliance scoring MORE auto fuel goes inactive first. When all six robots
 * have reports the winner is derivable, and the scout's entry becomes a
 * cross-check rather than the source of truth.
 */
export const reconcile = query({
  args: { matchId: v.id("matches") },
  handler: async (ctx, args) => {
    const match = await ctx.db.get(args.matchId);
    if (!match) return { derived: null, coverage: 0, entries: [], disagree: false };

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_match", (q) => q.eq("matchId", args.matchId))
      .collect();

    let red = 0;
    let blue = 0;
    let counted = 0;
    for (const report of reports) {
      const team = await ctx.db.get(report.teamId);
      if (!team) continue;
      if (match.redTeamNumbers.includes(team.number)) {
        red += report.auto.fuel;
        counted++;
      } else if (match.blueTeamNumbers.includes(team.number)) {
        blue += report.auto.fuel;
        counted++;
      }
    }

    // Only trust the derivation with full coverage; a partial alliance total
    // is not a comparison, it is a guess.
    const derived =
      counted === 6 ? (red === blue ? null : red > blue ? "red" : "blue") : null;

    const entries = reports
      .map((r) => r.autoWinner)
      .filter((w): w is "red" | "blue" => w !== null);

    const disagree =
      new Set(entries).size > 1 ||
      (derived !== null && entries.length > 0 && entries.some((e) => e !== derived));

    return { derived, coverage: counted, entries, disagree };
  },
});
EOF

say "Convex: match reports"
cat > convex/matchReports.ts <<'EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { activeEvent, requireUser } from "./lib/guards";

const lane = v.union(
  v.literal("trench-left"), v.literal("bump-left"),
  v.literal("bump-right"), v.literal("trench-right"),
);

const reportInput = {
  auto: v.object({
    path: v.object({
      start: v.union(lane, v.literal("hub"), v.null()),
      cycles: v.array(v.object({ outbound: lane, inbound: lane })),
      depotPickups: v.number(),
      outpostPickups: v.number(),
    }),
    climbL1: v.boolean(),
    fuel: v.number(),
    fouls: v.number(),
    notes: v.string(),
  }),
  teleop: v.object({
    byShift: v.object({
      transition: v.number(),
      s1: v.number(), s2: v.number(), s3: v.number(), s4: v.number(),
    }),
    passedNeutral: v.number(),
    passedFullField: v.number(),
    stoleFuel: v.number(),
    defended: v.boolean(),
    notes: v.string(),
  }),
  endgame: v.object({
    climb: v.union(v.literal("none"), v.literal("low"),
                   v.literal("mid"), v.literal("high")),
    fuel: v.number(),
    passedNeutral: v.number(),
    passedFullField: v.number(),
    notes: v.string(),
  }),
  ratings: v.object({
    driver: v.number(), defense: v.number(), accuracy: v.number(),
    shootsOnMove: v.boolean(),
    broke: v.boolean(), brokeNotes: v.string(),
    inconsistent: v.boolean(), inconsistentNotes: v.string(),
  }),
  matchStartedAt: v.union(v.number(), v.null()),
  autoWinner: v.union(v.literal("red"), v.literal("blue"), v.null()),
  hubStateSource: v.union(v.literal("timed"), v.literal("estimated"), v.literal("none")),
};

export const listForTeam = query({
  args: { teamId: v.id("teams") },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    return await ctx.db
      .query("matchReports")
      .withIndex("by_event_team", (q) =>
        q.eq("eventId", event._id).eq("teamId", args.teamId))
      .collect();
  },
});

/** My submitted reports, newest first — the "did it save?" surface. */
export const mine = query({
  args: {},
  handler: async (ctx) => {
    const userId = await requireUser(ctx);
    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_scout", (q) => q.eq("scoutId", userId))
      .collect();

    const rows = await Promise.all(
      reports.map(async (r) => ({
        ...r,
        match: await ctx.db.get(r.matchId),
        team: await ctx.db.get(r.teamId),
      })),
    );
    return rows.sort((a, b) => b.submittedAt - a.submittedAt);
  },
});

export const forMatchAndTeam = query({
  args: { matchNumber: v.number(), teamNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return null;

    const match = await ctx.db
      .query("matches")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("matchNumber", args.matchNumber))
      .unique();
    const team = await ctx.db
      .query("teams")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("number", args.teamNumber))
      .unique();
    if (!match || !team) return null;

    const existing = await ctx.db
      .query("matchReports")
      .withIndex("by_match", (q) => q.eq("matchId", match._id))
      .collect();
    const report = existing.find((r) => r.teamId === team._id) ?? null;

    const onRed = match.redTeamNumbers.includes(team.number);
    return { match, team, report, alliance: onRed ? "red" : "blue" };
  },
});

export const editHistory = query({
  args: { reportId: v.id("matchReports") },
  handler: async (ctx, args) =>
    await ctx.db
      .query("reportEdits")
      .withIndex("by_report", (q) => q.eq("reportId", args.reportId))
      .collect(),
});

export const submit = mutation({
  args: { matchId: v.id("matches"), teamId: v.id("teams"), ...reportInput },
  handler: async (ctx, args) => {
    const scoutId = await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");

    const { matchId, teamId, ...rest } = args;
    const now = Date.now();

    const duplicate = (
      await ctx.db
        .query("matchReports")
        .withIndex("by_match", (q) => q.eq("matchId", matchId))
        .collect()
    ).find((r) => r.teamId === teamId);
    if (duplicate) {
      throw new Error("A report for that robot in that match already exists.");
    }

    const reportId = await ctx.db.insert("matchReports", {
      eventId: event._id,
      matchId,
      teamId,
      scoutId,
      submittedAt: now,
      updatedAt: now,
      autoWinnerFlagged: false,
      ...rest,
    });

    // The robot is covered; free the claim for whoever scouts it next match.
    const claim = await ctx.db
      .query("matchClaims")
      .withIndex("by_match_team", (q) =>
        q.eq("matchId", matchId).eq("teamId", teamId))
      .unique();
    if (claim) await ctx.db.delete(claim._id);

    return reportId;
  },
});

/**
 * Every edit needs a reason, appended to reportEdits and never overwritten.
 * A wrong number quietly poisons every average the team appears in, so the
 * history of what changed and why is part of judging whether to trust it.
 */
export const update = mutation({
  args: { reportId: v.id("matchReports"), reason: v.string(), ...reportInput },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const reason = args.reason.trim();
    if (reason === "") throw new Error("An edit reason is required.");

    const report = await ctx.db.get(args.reportId);
    if (!report) throw new Error("That report no longer exists.");

    const profile = await ctx.db
      .query("profiles")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .unique();
    const isAuthor = report.scoutId === userId;
    if (!isAuthor && profile?.role !== "admin") {
      throw new Error("Only the scout who wrote this report, or an admin, can edit it.");
    }

    await ctx.db.patch(args.reportId, {
      auto: args.auto,
      teleop: args.teleop,
      endgame: args.endgame,
      ratings: args.ratings,
      matchStartedAt: args.matchStartedAt,
      autoWinner: args.autoWinner,
      hubStateSource: args.hubStateSource,
      updatedAt: Date.now(),
    });
    await ctx.db.insert("reportEdits", {
      reportId: args.reportId,
      editedBy: userId,
      editedAt: Date.now(),
      reason,
    });
  },
});
EOF

say "Client: match scouting landing"
cat > src/routes/scout/index.tsx <<'EOF'
import { useQuery } from "convex/react";
import { CheckCircle2, ChevronRight, Lock } from "lucide-react";
import { useState } from "react";
import { useNavigate } from "react-router";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

function MatchRobots({ matchNumber }: { matchNumber: number }) {
  const data = useQuery(api.matches.teamsInMatch, { matchNumber });
  const claims = useQuery(api.claims.forMatchNumber, { matchNumber });
  const me = useQuery(api.profiles.me);
  const navigate = useNavigate();

  if (data === undefined || data === null) {
    return <p className="text-muted-foreground p-3 text-sm">Loading…</p>;
  }

  const statusFor = (teamId: string) =>
    claims?.find((c) => c.teamId === teamId) ?? null;

  const column = (
    teams: typeof data.red,
    label: string,
    tone: string,
  ) => (
    <div className="space-y-2">
      <p className={`text-xs font-medium uppercase tracking-wide ${tone}`}>{label}</p>
      {teams.map((team, index) =>
        team === null ? (
          <div key={index} className="text-muted-foreground rounded-md border p-3 text-sm">
            Unknown team
          </div>
        ) : (
          (() => {
            const status = statusFor(team._id);
            const takenByOther =
              status !== null && status.scoutId !== me?.userId;
            return (
              <button
                key={team._id}
                disabled={takenByOther}
                onClick={() => void navigate(`/scout/${matchNumber}/${team.number}`)}
                className="hover:bg-accent/50 flex min-h-14 w-full items-center gap-2 rounded-md border p-3 text-left transition-colors disabled:cursor-not-allowed disabled:opacity-50"
              >
                <span className="font-semibold tabular-nums">{team.number}</span>
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {team.nickname}
                </span>
                {status?.state === "submitted" ? (
                  <CheckCircle2 className="size-4 shrink-0" />
                ) : status?.state === "claimed" ? (
                  <Lock className="size-4 shrink-0" />
                ) : null}
              </button>
            );
          })()
        ),
      )}
    </div>
  );

  return (
    <div className="grid grid-cols-2 gap-4 p-3">
      {column(data.red, "Red", "text-red-600 dark:text-red-400")}
      {column(data.blue, "Blue", "text-blue-600 dark:text-blue-400")}
    </div>
  );
}

export default function ScoutLandingPage() {
  const matches = useQuery(api.matches.listForEvent);
  const myReports = useQuery(api.matchReports.mine);
  const [open, setOpen] = useState<number | null>(null);

  return (
    <PageShell
      title="Match Scouting"
      description="Pick a match, then pick a robot. Greyed-out robots are already covered."
    >
      <Card>
        <CardHeader>
          <CardTitle>Matches</CardTitle>
          <CardDescription>
            {matches === undefined
              ? "Loading…"
              : matches.length === 0
                ? "No schedule imported yet."
                : `${matches.length} qualification matches.`}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-1">
          {(matches ?? []).map((match) => (
            <div key={match._id} className="rounded-lg border">
              <button
                onClick={() =>
                  setOpen(open === match.matchNumber ? null : match.matchNumber)
                }
                className="hover:bg-accent/50 flex min-h-14 w-full items-center gap-3 p-3 text-left transition-colors"
              >
                <span className="font-medium">Qual {match.matchNumber}</span>
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {match.redTeamNumbers.join(", ")} vs {match.blueTeamNumbers.join(", ")}
                </span>
                <ChevronRight
                  className={`size-4 shrink-0 transition-transform ${
                    open === match.matchNumber ? "rotate-90" : ""
                  }`}
                />
              </button>
              {open === match.matchNumber ? (
                <MatchRobots matchNumber={match.matchNumber} />
              ) : null}
            </div>
          ))}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>My reports</CardTitle>
          <CardDescription>Newest first.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {myReports === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : myReports.length === 0 ? (
            <p className="text-muted-foreground text-sm">Nothing submitted yet.</p>
          ) : (
            myReports.slice(0, 20).map((report) => (
              <div
                key={report._id}
                className="flex items-center gap-3 rounded-md border p-3 text-sm"
              >
                <span className="font-medium">
                  Qual {report.match?.matchNumber ?? "?"}
                </span>
                <span className="tabular-nums">{report.team?.number ?? "?"}</span>
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {report.team?.nickname ?? ""}
                </span>
                {report.hubStateSource === "none" ? (
                  <Badge variant="outline">No shift split</Badge>
                ) : null}
              </div>
            ))
          )}
        </CardContent>
      </Card>
    </PageShell>
  );
}
EOF

say "Client: match form"
cat > src/routes/scout/use-match-clock.ts <<'EOF'
import { useEffect, useState } from "react";
import { MATCH_TIMING, phaseAt, type Phase, type ShiftKey } from "@/lib/scoring";

/**
 * Teleop fuel is banked per shift window so the counted/uncounted split can be
 * recomputed later if the auto winner turns out to be wrong. That needs a time
 * anchor, which is what "Match Start" provides.
 *
 * Transition is active for BOTH alliances, so it is the safe default bucket:
 * banking there can never fabricate dead-hub fuel that did not happen.
 */
export function bucketFor(phase: Phase): ShiftKey {
  switch (phase) {
    case "s1": case "s2": case "s3": case "s4":
      return phase;
    default:
      return "transition";
  }
}

export const PHASE_LABELS: Record<Phase, string> = {
  pre: "Not started",
  auto: "Auto",
  pause: "Auto scoring",
  transition: "Transition",
  s1: "Shift 1", s2: "Shift 2", s3: "Shift 3", s4: "Shift 4",
  endgame: "Endgame",
  over: "Match over",
};

export function useMatchClock(startedAt: number | null) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (startedAt === null) return;
    const id = window.setInterval(() => setNow(Date.now()), 500);
    return () => window.clearInterval(id);
  }, [startedAt]);

  if (startedAt === null) {
    return { phase: "pre" as Phase, elapsed: 0, bucket: "transition" as ShiftKey };
  }

  const elapsed = (now - startedAt) / 1000;
  const phase = phaseAt(elapsed);
  return { phase, elapsed, bucket: bucketFor(phase) };
}

/** Anchor used when the scout never tapped Match Start. */
export function estimatedStart(): number {
  const offset = (MATCH_TIMING.autoSeconds + MATCH_TIMING.autoPauseSeconds) * 1000;
  return Date.now() - offset;
}
EOF

cat > src/routes/scout/form.tsx <<'EOF'
import { useMutation, useQuery } from "convex/react";
import { AlertTriangle, ArrowLeft, LoaderCircle, Play, Plus, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
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
import type { AutoCycle, ClimbLevel, Lane, StartPosition } from "@/lib/types";
import { useUIStore } from "@/stores/ui-store";

const LANE_OPTIONS: ReadonlyArray<{ value: Lane; label: string }> = [
  { value: "trench-left", label: "Trench L" },
  { value: "trench-right", label: "Trench R" },
  { value: "bump-left", label: "Bump L" },
  { value: "bump-right", label: "Bump R" },
];

const START_OPTIONS: ReadonlyArray<{ value: StartPosition; label: string }> = [
  ...LANE_OPTIONS,
  { value: "hub", label: "Hub" },
];

const CLIMB_OPTIONS: ReadonlyArray<{ value: ClimbLevel; label: string }> = [
  { value: "none", label: "No climb" },
  { value: "low", label: "Low (L1)" },
  { value: "mid", label: "Middle (L2)" },
  { value: "high", label: "High (L3)" },
];

const DRIVER_HINT = "left / right as that alliance's drivers see it";

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
  const claim = useMutation(api.claims.claim);
  const release = useMutation(api.claims.release);
  const submit = useMutation(api.matchReports.submit);

  const period = useUIStore((s) => s.matchFormPeriod);
  const setPeriod = useUIStore((s) => s.setMatchFormPeriod);

  const [startedAt, setStartedAt] = useState<number | null>(null);
  const [estimated, setEstimated] = useState(false);
  const { phase, bucket } = useMatchClock(startedAt);

  const [start, setStart] = useState<StartPosition | null>(null);
  const [cycles, setCycles] = useState<AutoCycle[]>([]);
  const [depotPickups, setDepot] = useState(0);
  const [outpostPickups, setOutpost] = useState(0);
  const [autoClimb, setAutoClimb] = useState(false);
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
  const [endNotes, setEndNotes] = useState("");

  const [driver, setDriver] = useState<number | null>(null);
  const [defense, setDefense] = useState<number | null>(null);
  const [accuracy, setAccuracy] = useState<number | null>(null);
  const [shootsOnMove, setShootsOnMove] = useState(false);
  const [broke, setBroke] = useState(false);
  const [brokeNotes, setBrokeNotes] = useState("");
  const [inconsistent, setInconsistent] = useState(false);
  const [inconsistentNotes, setInconsistentNotes] = useState("");

  const [autoWinner, setAutoWinner] = useState<"red" | "blue" | null>(null);
  const [saving, setSaving] = useState(false);
  const [override, setOverride] = useState(false);
  const [claimError, setClaimError] = useState<string | null>(null);

  useEffect(() => {
    if (!data?.match || !data.team) return;
    claim({ matchId: data.match._id, teamId: data.team._id }).catch(
      (error: unknown) =>
        setClaimError(error instanceof Error ? error.message : String(error)),
    );
  }, [data?.match, data?.team, claim]);

  // No Match Start tap: anchor on the first look at teleop. Shifts are 25s, so
  // a few seconds of drift only misclassifies fuel near a boundary.
  useEffect(() => {
    if (period === "teleop" && startedAt === null) {
      setStartedAt(estimatedStart());
      setEstimated(true);
    }
  }, [period, startedAt]);

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

  const hubStateSource = startedAt === null ? "none" : estimated ? "estimated" : "timed";

  const save = async () => {
    if (!data?.match || !data.team) return;
    setSaving(true);
    try {
      await submit({
        matchId: data.match._id,
        teamId: data.team._id,
        auto: {
          path: { start, cycles, depotPickups, outpostPickups },
          climbL1: autoClimb, fuel: autoFuel, fouls: autoFouls, notes: autoNotes,
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
          notes: endNotes,
        },
        ratings: {
          driver: driver ?? 0, defense: defense ?? 0, accuracy: accuracy ?? 0,
          shootsOnMove,
          broke, brokeNotes: broke ? brokeNotes : "",
          inconsistent, inconsistentNotes: inconsistent ? inconsistentNotes : "",
        },
        matchStartedAt: startedAt,
        autoWinner,
        hubStateSource,
      });
      await release({ matchId: data.match._id, teamId: data.team._id });
      toast.success(`Qual ${matchNumber} · team ${teamNumber} submitted`);
      void navigate("/scout");
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
  if (data.report) {
    return (
      <PageShell
        title={`Qual ${matchNumber} · ${data.team.number}`}
        description="This robot already has a report for this match."
      >
        <Button variant="outline" onClick={() => void navigate("/scout")}>
          <ArrowLeft className="size-4" /> Back
        </Button>
      </PageShell>
    );
  }
  if (claimError) {
    return (
      <PageShell title={`Qual ${matchNumber} · ${data.team.number}`} description={claimError}>
        <Button variant="outline" onClick={() => void navigate("/scout")}>
          <ArrowLeft className="size-4" /> Pick another robot
        </Button>
      </PageShell>
    );
  }

  return (
    <PageShell
      title={`Qual ${matchNumber} · ${data.team.number}`}
      description={`${data.team.nickname} · ${data.alliance} alliance`}
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
        </TabsList>

        <TabsContent value="auto" className="space-y-4 pt-4">
          <Card>
            <CardHeader><CardTitle>Start position</CardTitle></CardHeader>
            <CardContent>
              <SegmentedChoice
                label="Lined up in front of"
                hint={DRIVER_HINT}
                options={START_OPTIONS}
                value={start}
                onChange={setStart}
              />
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>Neutral zone cycles</CardTitle></CardHeader>
            <CardContent className="space-y-4">
              {cycles.map((cycle, index) => (
                <div key={index} className="space-y-3 rounded-lg border p-3">
                  <div className="flex items-center justify-between">
                    <span className="text-sm font-medium">Cycle {index + 1}</span>
                    <Button
                      variant="ghost" size="icon"
                      aria-label={`Remove cycle ${index + 1}`}
                      onClick={() => setCycles(cycles.filter((_, i) => i !== index))}
                    >
                      <Trash2 className="size-4" />
                    </Button>
                  </div>
                  <SegmentedChoice
                    label="Out through" hint={DRIVER_HINT} options={LANE_OPTIONS}
                    value={cycle.outbound}
                    onChange={(lane) =>
                      setCycles(cycles.map((c, i) =>
                        i === index ? { ...c, outbound: lane } : c))}
                  />
                  <SegmentedChoice
                    label="Back through" hint={DRIVER_HINT} options={LANE_OPTIONS}
                    value={cycle.inbound}
                    onChange={(lane) =>
                      setCycles(cycles.map((c, i) =>
                        i === index ? { ...c, inbound: lane } : c))}
                  />
                </div>
              ))}
              <Button
                variant="outline" className="h-12 w-full"
                onClick={() =>
                  setCycles([...cycles,
                    { outbound: "bump-left", inbound: "bump-left" }])}
              >
                <Plus className="size-4" /> Add cycle
              </Button>
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>In-zone pickups</CardTitle></CardHeader>
            <CardContent className="space-y-6">
              <Stepper label="Depot" value={depotPickups} onChange={setDepot} />
              <Stepper label="Outpost" value={outpostPickups} onChange={setOutpost} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>Auto scoring</CardTitle></CardHeader>
            <CardContent className="space-y-6">
              <Stepper label="Fuel scored" value={autoFuel} onChange={setAutoFuel} />
              <Stepper label="Fouls" value={autoFouls} onChange={setAutoFouls} />
              <CapabilityCheck
                id="auto-climb" label="Climbed L1 in auto"
                checked={autoClimb} onChange={setAutoClimb}
              />
              <Textarea placeholder="Auto notes" rows={2}
                value={autoNotes} onChange={(e) => setAutoNotes(e.target.value)} />
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
              <Textarea placeholder="Endgame notes" rows={2}
                value={endNotes} onChange={(e) => setEndNotes(e.target.value)} />
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>

      <Card>
        <CardHeader><CardTitle>Ratings</CardTitle></CardHeader>
        <CardContent className="space-y-6">
          <RatingScale label="Driver" value={driver} onChange={setDriver} />
          <RatingScale label="Defense" value={defense} onChange={setDefense} />
          <RatingScale label="Shooting accuracy" value={accuracy} onChange={setAccuracy} />
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
        <CardHeader><CardTitle>Which alliance won auto?</CardTitle></CardHeader>
        <CardContent className="space-y-4">
          <p className="text-muted-foreground text-sm">
            The alliance scoring more auto fuel has its hub inactive first. This
            decides which of your teleop fuel actually scored points.
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

      <Button
        className="h-14 w-full text-base"
        disabled={saving || (suspicious && !override)}
        onClick={() => void save()}
      >
        {saving ? <LoaderCircle className="size-4 animate-spin" /> : null}
        Submit report
      </Button>
    </PageShell>
  );
}
EOF

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Track C written. Open /scout, pick a match, pick a robot.

DONE
