#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-rank.sh — TBA qualification rank everywhere team stats appear.
#
#   * Backend: a teamRanks table filled from TBA's /event/{key}/rankings.
#     Refreshed only by the two-hour cron and the Admin refresh button; the
#     fetch is internal, so nothing else can trigger it. A row is only
#     rewritten when its rank changes.
#   * Shown: a #rank badge on Teams list rows and pick list chips, a Rank card
#     in both team modals (2026 and notes), a "Rank (TBA)" row on the compare
#     table (compare page and match preview), the notes match page, and a
#     tbaRank column in the xlsx export.
#   * Sorting: "Rank (TBA)" in the Teams sort menu, "Rank" in the pick list's
#     Sort Uncategorized, and "Rank (TBA)" as a plot axis. Rank 1 is best;
#     unranked teams sort last.
#   * Purging or removing an event deletes its ranks.
#
# Needs patch-match13.sh and patch-seasons.sh first; works with or without
# patch-spares.sh and patch-batteries.sh. Every edit is checked before
# anything is written, and the script is safe to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/schema.ts && -f src/routes/teams/index.tsx ]] || {
  echo "ERROR: run from the repo root" >&2; exit 1; }
command -v bun >/dev/null || { echo "ERROR: bun not found" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# Relative on purpose: Git Bash rewrites /tmp in arguments but not inside
# the strings a script reads, so an absolute /tmp path breaks on Windows.
T=.patch-rank-tmp
rm -rf "$T"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

say "Staging files"
cat > "$T/ranks.ts" <<'PATCH_EOF'
import { v } from "convex/values";
import { internalMutation, query } from "./_generated/server";
import { activeEvent } from "./lib/guards";

/**
 * TBA qualification rankings for the caller's active event. Refreshed only by
 * the two-hour cron and the Admin page's refresh button, through
 * tba.refreshRanks, which nothing outside the backend can call.
 */
export const forEvent = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    const rows = await ctx.db
      .query("teamRanks")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    return rows.map((r) => ({ teamNumber: r.teamNumber, rank: r.rank }));
  },
});

/**
 * Replaces the event's rankings with TBA's current list. Only rows whose rank
 * actually changed are written, so a refresh where nothing moved costs no
 * writes and wakes no pages.
 */
export const store = internalMutation({
  args: {
    eventId: v.id("events"),
    rows: v.array(v.object({ teamNumber: v.number(), rank: v.number() })),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("teamRanks")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    const byTeam = new Map(existing.map((r) => [r.teamNumber, r]));
    const incoming = new Set<number>();

    for (const row of args.rows) {
      incoming.add(row.teamNumber);
      const found = byTeam.get(row.teamNumber);
      if (!found) {
        await ctx.db.insert("teamRanks", { eventId: args.eventId, ...row });
      } else if (found.rank !== row.rank) {
        await ctx.db.patch(found._id, { rank: row.rank });
      }
    }
    // A team TBA no longer ranks (dropped from the event) loses its rank.
    for (const row of existing) {
      if (!incoming.has(row.teamNumber)) await ctx.db.delete(row._id);
    }
    return { ranked: args.rows.length };
  },
});
PATCH_EOF

cat > "$T/ranks-web.ts" <<'PATCH_EOF'
import { useQuery } from "convex/react";
import { useMemo } from "react";

import { api } from "../../convex/_generated/api";

/**
 * TBA rank by team number for the active event, and how many teams are
 * ranked. Rank 1 is best; a team missing from the map is unranked (quals not
 * started, or TBA has not caught up).
 */
export function useRanks() {
  const data = useQuery(api.ranks.forEvent);
  return useMemo(() => {
    const byTeam = new Map<number, number>();
    for (const row of data ?? []) byTeam.set(row.teamNumber, row.rank);
    return { loading: data === undefined, byTeam, total: byTeam.size };
  }, [data]);
}

/** Sorts rank 1 first and unranked teams last, in either direction. */
export function compareRanks(a: number | undefined, b: number | undefined, bestFirst = true): number {
  if (a === b) return 0;
  if (a === undefined) return 1;
  if (b === undefined) return -1;
  return bestFirst ? a - b : b - a;
}
PATCH_EOF

cat > "$T/team-rank.tsx" <<'PATCH_EOF'
import { Badge } from "@/components/ui/badge";

/** "#4", or nothing for an unranked team. */
export function RankBadge({ rank, className }: { rank: number | null | undefined; className?: string }) {
  if (rank === null || rank === undefined) return null;
  return (
    <Badge variant="outline" title={`TBA rank ${rank}`}
      className={["shrink-0 tabular-nums", className ?? ""].join(" ")}>
      #{rank}
    </Badge>
  );
}

/** The rank beside the EPA/xP card in a team modal. */
export function RankCard({ rank, total }: { rank: number | null | undefined; total: number }) {
  if (rank === null || rank === undefined) return null;
  return (
    <div className="rounded-lg border p-3">
      <p className="text-muted-foreground text-xs">Rank</p>
      <p className="text-xl font-semibold tabular-nums">
        {rank}
        <span className="text-muted-foreground text-sm font-normal"> of {total}</span>
      </p>
      <p className="text-muted-foreground text-[10px]">The Blue Alliance</p>
    </div>
  );
}
PATCH_EOF

cat > "$T/apply.mjs" <<'PATCH_EOF'
// Applies every edit in memory first and writes nothing unless all of them
// found their anchors. Safe to re-run: files already patched are skipped.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

const T = process.argv[2];
const staged = new Map();
const eol = new Map();
const report = [];
const fail = (message) => {
  console.error(`\nERROR: ${message}\nNothing was written.`);
  process.exit(1);
};

// Windows checkouts can carry CRLF. Match on LF, write back what was there.
function load(path) {
  if (staged.has(path)) return staged.get(path);
  if (!existsSync(path)) fail(`${path} not found. Run this from the repo root.`);
  const raw = readFileSync(path, "utf8");
  eol.set(path, raw.includes("\r\n") ? "\r\n" : "\n");
  return raw.replace(/\r\n/g, "\n");
}
const snippet = (name) => readFileSync(`${T}/${name}`, "utf8").replace(/\r\n/g, "\n");

function count(haystack, needle) {
  let n = 0;
  for (let i = haystack.indexOf(needle); i !== -1; i = haystack.indexOf(needle, i + 1)) n += 1;
  return n;
}

function once(s, find, replace, where) {
  const n = count(s, find);
  if (n !== 1) {
    fail(`${where}: expected 1 match, found ${n}, for:\n  ${find.split("\n")[0].trim()}`);
  }
  return s.replace(find, () => replace);
}

/** Replace the block from `start` up to (not including) `end`. */
function between(s, start, end, replace, where, mustContain) {
  if (count(s, start) !== 1) fail(`${where}: could not find the start of the block to replace.`);
  const from = s.indexOf(start);
  const to = s.indexOf(end, from);
  if (to === -1) fail(`${where}: could not find the end of the block to replace.`);
  if (mustContain && !s.slice(from, to).includes(mustContain)) {
    fail(`${where}: the block found does not look like the expected one.`);
  }
  return s.slice(0, from) + replace + s.slice(to);
}

/** Replace the first `find` after a unique `anchor`. */
function after(s, anchor, find, replace, where) {
  if (count(s, anchor) !== 1) fail(`${where}: anchor not unique.`);
  const at = s.indexOf(anchor);
  const i = s.indexOf(find, at);
  if (i === -1) fail(`${where}: nothing to replace after the anchor.`);
  return s.slice(0, i) + replace + s.slice(i + find.length);
}

function edit(path, doneMarker, fn) {
  const s = load(path);
  if (s.includes(doneMarker)) { report.push(`skip   ${path} (already patched)`); return; }
  staged.set(path, fn(s));
  report.push(`edit   ${path}`);
}

function create(path, name) {
  const content = snippet(name);
  if (existsSync(path)) {
    const current = readFileSync(path, "utf8").replace(/\r\n/g, "\n");
    if (current === content) { report.push(`skip   ${path} (already present)`); return; }
    fail(`${path} already exists with different content. Move it aside and re-run.`);
  }
  staged.set(path, content);
  eol.set(path, "\n");
  report.push(`create ${path}`);
}

// ─── Prerequisites ─────────────────────────────────────────────────────────
for (const needed of ["convex/refresh.ts", "convex/match13.ts", "src/routes/notes/team-detail.tsx"]) {
  if (!existsSync(needed)) fail(`${needed} is missing. Run patch-match13.sh and patch-seasons.sh first.`);
}

// ─── Convex ────────────────────────────────────────────────────────────────

create("convex/ranks.ts", "ranks.ts");

edit("convex/schema.ts", "teamRanks: defineTable", (s) => once(s,
  "  teamEpa: defineTable({",
  `  /**
   * TBA qualification rank for one team at one event. Refreshed with EPA,
   * xP and scores (cron and Admin button); a row is only rewritten when the
   * rank changes.
   */
  teamRanks: defineTable({
    eventId: v.id("events"),
    teamNumber: v.number(),
    rank: v.number(),
  }).index("by_event", ["eventId"]),

  teamEpa: defineTable({`,
  "schema.ts"));

edit("convex/tba.ts", "refreshRanks", (s) => {
  const w = "tba.ts";
  s = once(s, `import { action } from "./_generated/server";`,
    `import { action, internalAction } from "./_generated/server";`, w);
  s = s.trimEnd() + `

type TbaRankings = {
  rankings?: { rank: number; team_key: string }[] | null;
} | null;

/**
 * Qualification rankings for one event. Internal: only refresh.now (the
 * Admin button, which checks the caller first) and the two-hour cron reach
 * it. Before quals start TBA has no rankings, which stores none.
 */
export const refreshRanks = internalAction({
  args: { eventId: v.id("events"), eventKey: v.string() },
  handler: async (ctx, args): Promise<{ ranked: number }> => {
    const body = await tbaFetch<TbaRankings>(\`/event/\${args.eventKey}/rankings\`);
    const rows = (body?.rankings ?? []).flatMap((r) => {
      const teamNumber = teamNumberFromKey(r.team_key);
      return Number.isInteger(teamNumber) && Number.isInteger(r.rank) && r.rank > 0
        ? [{ teamNumber, rank: r.rank }]
        : [];
    });
    return await ctx.runMutation(internal.ranks.store, { eventId: args.eventId, rows });
  },
});
`;
  return s;
});

edit("convex/refresh.ts", "refreshRanks", (s) => {
  const w = "refresh.ts";
  s = once(s,
    `    xpTeams: number;
    matchesUpdated: number;
    problems: string[];
  }> => {`,
    `    xpTeams: number;
    matchesUpdated: number;
    rankedTeams: number;
    problems: string[];
  }> => {`, w);
  s = once(s, "    let matchesUpdated = 0;\n", "    let matchesUpdated = 0;\n    let rankedTeams = 0;\n", w);
  s = once(s,
    `      matchesUpdated = result.updated;
    } catch (error) {
      problems.push(message(error));
    }
`,
    `      matchesUpdated = result.updated;
    } catch (error) {
      problems.push(message(error));
    }

    try {
      const result = await ctx.runAction(internal.tba.refreshRanks, {
        eventId: event.eventId as Id<"events">,
        eventKey: event.eventKey,
      });
      rankedTeams = result.ranked;
    } catch (error) {
      problems.push(message(error));
    }
`, w);
  s = once(s,
    "    if (epaTeams === 0 && xpTeams === 0 && matchesUpdated === 0 && problems.length > 0) {",
    "    if (epaTeams === 0 && xpTeams === 0 && matchesUpdated === 0 && rankedTeams === 0\n      && problems.length > 0) {", w);
  s = once(s, "    return { epaTeams, xpTeams, matchesUpdated, problems };",
    "    return { epaTeams, xpTeams, matchesUpdated, rankedTeams, problems };", w);
  s = once(s,
    `      } catch {
        // Nor must match13 having nothing for it yet.
      }`,
    `      } catch {
        // Nor must match13 having nothing for it yet.
      }
      try {
        await ctx.runAction(internal.tba.refreshRanks, {
          eventId: event.eventId as Id<"events">,
          eventKey: event.eventKey,
        });
      } catch {
        // Nor TBA having no rankings before quals start.
      }`, w);
  return s;
});

edit("convex/events.ts", `query("teamRanks")`, (s) => once(s,
  `  for (const row of xp) await ctx.db.delete(row._id);
}`,
  `  for (const row of xp) await ctx.db.delete(row._id);
  const ranks = await ctx.db
    .query("teamRanks")
    .withIndex("by_event", (q) => q.eq("eventId", eventId))
    .collect();
  for (const row of ranks) await ctx.db.delete(row._id);
}`,
  "events.ts deleteRatings"));

edit("convex/workbook.ts", "rankByNumber", (s) => {
  const w = "workbook.ts";
  s = once(s,
    "const [reports, matches, teams, pit, epaRows, xpRows, profiles] = await Promise.all([",
    "const [reports, matches, teams, pit, epaRows, xpRows, rankRows, profiles] = await Promise.all([", w);
  s = once(s,
    `      ctx.db.query("teamXp").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),\n`,
    `      ctx.db.query("teamXp").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ctx.db.query("teamRanks").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),\n`, w);
  s = once(s, "    const xpByNumber = new Map(xpRows.map((r) => [r.teamNumber, r]));",
    "    const xpByNumber = new Map(xpRows.map((r) => [r.teamNumber, r]));\n    const rankByNumber = new Map(rankRows.map((r) => [r.teamNumber, r.rank]));", w);
  s = once(s, "          pitScouted: pitScouted.has(t._id),",
    `          pitScouted: pitScouted.has(t._id),\n          tbaRank: rankByNumber.get(t.number) ?? "",`, w);
  return s;
});

{
  const path = "convex/_generated/api.d.ts";
  let s = load(path);
  if (s.includes(`import type * as ranks from "../ranks.js";`)) {
    report.push(`skip   ${path} (already lists ranks)`);
  } else {
    s = once(s, `import type * as refresh from "../refresh.js";`,
      `import type * as ranks from "../ranks.js";\nimport type * as refresh from "../refresh.js";`, "api.d.ts import");
    s = once(s, "  refresh: typeof refresh;", "  ranks: typeof ranks;\n  refresh: typeof refresh;", "api.d.ts entry");
    staged.set(path, s);
    report.push(`edit   ${path}`);
  }
}

// ─── Shared frontend ───────────────────────────────────────────────────────

create("src/lib/ranks.ts", "ranks-web.ts");
create("src/components/team-rank.tsx", "team-rank.tsx");

edit("src/routes/admin/stat-sources-card.tsx", "rankedTeams", (s) => {
  const w = "stat-sources-card.tsx";
  s = once(s,
    `          EPA, xP and match scores refresh together every two hours, and only
          while a team has an event active.`,
    `          EPA, xP, match scores and TBA rankings refresh together every two
          hours, and only while a team has an event active.`, w);
  s = once(s, "                    `${r.matchesUpdated} matches updated.`;",
    "                    `${r.matchesUpdated} matches updated · ${r.rankedTeams} teams ranked.`;", w);
  return s;
});

// ─── Teams list ────────────────────────────────────────────────────────────

edit("src/components/scouting/team-card.tsx", "RankBadge", (s) => {
  const w = "team-card.tsx";
  s = once(s, `import { AttentionBadge } from "@/components/attention-items";`,
    `import { AttentionBadge } from "@/components/attention-items";\nimport { RankBadge } from "@/components/team-rank";`, w);
  s = once(s, "  attention = 0,\n  onClick,\n}: {", "  attention = 0,\n  rank,\n  onClick,\n}: {", w);
  s = once(s, "  attention?: number;\n  onClick?: () => void;",
    "  attention?: number;\n  /** TBA rank; shown when the caller passes one. */\n  rank?: number | null;\n  onClick?: () => void;", w);
  s = once(s, "        <AttentionBadge count={attention} />",
    "        <AttentionBadge count={attention} />\n        <RankBadge rank={rank} />", w);
  return s;
});

edit("src/routes/teams/index.tsx", "useRanks", (s) => {
  const w = "teams/index.tsx";
  s = once(s, `import { api } from "../../../convex/_generated/api";`,
    `import { api } from "../../../convex/_generated/api";\nimport { compareRanks, useRanks } from "@/lib/ranks";`, w);
  s = once(s,
    `type TeamSort = "number" | "totalFuel" | "climbPoints" | "passing" | "defense" | "driver";

/** Team number ascending; every stat highest first. */`,
    `type TeamSort = "number" | "rank" | "totalFuel" | "climbPoints" | "passing" | "defense" | "driver";

/** Team number and rank ascending (unranked last); every stat highest first. */`, w);
  s = once(s, `  { value: "number", label: "Team number" },`,
    `  { value: "number", label: "Team number" },\n  { value: "rank", label: "Rank (TBA)" },`, w);
  s = once(s,
    `  // Only subscribed while a stat sort is chosen; team-number order needs none.
  const stats = useQuery(api.stats.forEvent, sort === "number" ? "skip" : {});`,
    `  // Only subscribed while a stat sort is chosen; number and rank need none.
  const stats = useQuery(api.stats.forEvent, sort === "number" || sort === "rank" ? "skip" : {});
  const ranks = useRanks();`, w);
  s = once(s,
    `  const sorted = useMemo(() => {
    if (sort === "number" || !stats) return shown;`,
    `  const sorted = useMemo(() => {
    if (sort === "rank") {
      return [...shown].sort((a, b) =>
        compareRanks(ranks.byTeam.get(a.number), ranks.byTeam.get(b.number)) || a.number - b.number);
    }
    if (sort === "number" || !stats) return shown;`, w);
  s = once(s, "  }, [shown, sort, stats]);", "  }, [shown, sort, stats, ranks]);", w);
  s = once(s, "                attention={attentionByTeam.get(team.number) ?? 0}\n",
    "                attention={attentionByTeam.get(team.number) ?? 0}\n                rank={ranks.byTeam.get(team.number) ?? null}\n", w);
  return s;
});

// ─── Team modals ───────────────────────────────────────────────────────────

const RATING_2026 = `              {rating ? (
                <div className="rounded-lg border p-3">
                  <p className="text-muted-foreground text-xs">{ratings.metric}</p>
                  <p className="text-xl font-semibold tabular-nums">
                    {rating.total.toFixed(1)}
                  </p>
                  <p className="text-muted-foreground text-[10px]">
                    {ratings.siteName}, not your scouting
                  </p>
                </div>
              ) : null}`;

edit("src/routes/teams/team-detail.tsx", "RankCard", (s) => {
  const w = "teams/team-detail.tsx";
  s = once(s, `import { useRatings } from "@/lib/stat-site";`,
    `import { useRatings } from "@/lib/stat-site";
import { useRanks } from "@/lib/ranks";
import { RankCard } from "@/components/team-rank";`, w);
  s = once(s,
    "  const rating = teamNumber === null ? null : (ratings.byTeam.get(teamNumber) ?? null);",
    `  const rating = teamNumber === null ? null : (ratings.byTeam.get(teamNumber) ?? null);
  const ranks = useRanks();
  const rank = teamNumber === null ? null : (ranks.byTeam.get(teamNumber) ?? null);`, w);
  s = once(s, RATING_2026,
    `            {rating || rank !== null ? (
              <div className="grid grid-cols-2 gap-2">
${RATING_2026.split("\n").map((l) => `  ${l}`).join("\n")}
                <RankCard rank={rank} total={ranks.total} />
              </div>
            ) : null}`, w);
  return s;
});

const RATING_NOTES = `            {rating ? (
              <div className="w-fit rounded-lg border p-3">
                <p className="text-muted-foreground text-xs">{ratings.metric}</p>
                <p className="text-xl font-semibold tabular-nums">{rating.total.toFixed(1)}</p>
                <p className="text-muted-foreground text-[10px]">
                  {ratings.siteName}, not your scouting
                </p>
              </div>
            ) : null}`;

edit("src/routes/notes/team-detail.tsx", "RankCard", (s) => {
  const w = "notes/team-detail.tsx";
  s = once(s, `import { useRatings } from "@/lib/stat-site";`,
    `import { useRatings } from "@/lib/stat-site";
import { useRanks } from "@/lib/ranks";
import { RankCard } from "@/components/team-rank";`, w);
  s = once(s,
    "  const rating = teamNumber === null ? null : (ratings.byTeam.get(teamNumber) ?? null);",
    `  const rating = teamNumber === null ? null : (ratings.byTeam.get(teamNumber) ?? null);
  const ranks = useRanks();
  const rank = teamNumber === null ? null : (ranks.byTeam.get(teamNumber) ?? null);`, w);
  s = once(s, RATING_NOTES,
    `            {rating || rank !== null ? (
              <div className="flex flex-wrap gap-2">
${RATING_NOTES.replace('className="w-fit rounded-lg border p-3"', 'className="rounded-lg border p-3"').split("\n").map((l) => `  ${l}`).join("\n")}
                <RankCard rank={rank} total={ranks.total} />
              </div>
            ) : null}`, w);
  return s;
});

// ─── Compare table (compare page and match preview) ────────────────────────

edit("src/components/compare-table.tsx", "useRanks", (s) => {
  const w = "compare-table.tsx";
  s = `import { useRanks } from "@/lib/ranks";\n\n` + s;
  s = once(s,
    `export function CompareTable({ columns }: { columns: CompareColumn[] }) {
  if (columns.length === 0) return null;`,
    `export function CompareTable({ columns }: { columns: CompareColumn[] }) {
  const ranks = useRanks();
  if (columns.length === 0) return null;

  // Rank comes from TBA, not the summaries, so it is its own row. Lower is
  // better, and an unranked team never counts as best.
  const rankOf = (c: CompareColumn) => ranks.byTeam.get(c.teamNumber);
  const ranked = columns.map(rankOf).filter((r): r is number => r !== undefined);
  const bestRank = ranked.length > 1 && new Set(ranked).size > 1 ? Math.min(...ranked) : null;`, w);
  s = once(s, "        <tbody>\n          {METRICS.map((metric) => {",
    `        <tbody>
          <tr className="border-b">
            <td className="text-muted-foreground p-3">Rank (TBA)</td>
            {columns.map((c) => {
              const rank = rankOf(c);
              return (
                <td key={c.teamNumber}
                  className={[
                    "p-3 text-right tabular-nums",
                    rank !== undefined && rank === bestRank ? "font-semibold" : "",
                  ].join(" ")}>
                  {rank ?? "—"}
                </td>
              );
            })}
          </tr>
          {METRICS.map((metric) => {`, w);
  return s;
});

// ─── Pick list board ───────────────────────────────────────────────────────

edit("src/stores/ui-store.ts", `"rank"`, (s) => once(s,
  `export type SortKey = "totalFuel" | "climbPoints" | "passing" | "defense" | "driver";`,
  `export type SortKey = "rank" | "totalFuel" | "climbPoints" | "passing" | "defense" | "driver";`,
  "ui-store.ts"));

edit("src/routes/picklists/team-chip.tsx", "RankBadge", (s) => {
  const w = "team-chip.tsx";
  s = once(s, `import { Button } from "@/components/ui/button";`,
    `import { Button } from "@/components/ui/button";\nimport { RankBadge } from "@/components/team-rank";`, w);
  s = once(s, "  stats,\n  draggable,", "  stats,\n  rank,\n  draggable,", w);
  s = once(s, "  stats: ChipStats | null;\n  draggable: boolean;",
    "  stats: ChipStats | null;\n  /** TBA rank, or null when unranked. */\n  rank?: number | null;\n  draggable: boolean;", w);
  s = once(s,
    `        <Badge variant={pitScouted ? "secondary" : "outline"} className="shrink-0 text-[10px]">`,
    `        <RankBadge rank={rank} className="text-[10px]" />
        <Badge variant={pitScouted ? "secondary" : "outline"} className="shrink-0 text-[10px]">`, w);
  return s;
});

edit("src/routes/picklists/board.tsx", "useRanks", (s) => {
  const w = "picklists/board.tsx";
  s = once(s, `import { useUIStore, type SortKey } from "@/stores/ui-store";`,
    `import { useUIStore, type SortKey } from "@/stores/ui-store";\nimport { compareRanks, useRanks } from "@/lib/ranks";`, w);
  s = once(s, `  { key: "totalFuel", label: "Fuel" },`, `  { key: "rank", label: "Rank" },\n  { key: "totalFuel", label: "Fuel" },`, w);
  s = once(s, "  const stats = useQuery(api.stats.forEvent);\n",
    "  const stats = useQuery(api.stats.forEvent);\n  const ranks = useRanks();\n", w);
  s = once(s,
    `      if (tier === "uncategorized" && sort) {
        const value = (r: Row) => {`,
    `      if (tier === "uncategorized" && sort?.key === "rank") {
        // Rank 1 is best, so "desc" (best first) is ascending rank. Unranked
        // teams go last either way.
        rows.sort((a, b) => compareRanks(
          ranks.byTeam.get(a.teamNumber), ranks.byTeam.get(b.teamNumber),
          sort.direction === "desc"));
      } else if (tier === "uncategorized" && sort) {
        const sortKey = sort.key;
        const value = (r: Row) => {`, w);
  s = once(s, "          switch (sort.key) {",
    "          switch (sortKey) {\n            case \"rank\": return -1; // sorted in the branch above", w);
  s = once(s, "  }, [entries, sort, stats, search, picked, showPicked]);",
    "  }, [entries, sort, stats, search, picked, showPicked, ranks]);", w);
  s = once(s, "                      stats={statFor(row.teamId)}\n",
    "                      stats={statFor(row.teamId)}\n                      rank={ranks.byTeam.get(row.teamNumber) ?? null}\n", w);
  return s;
});

// ─── Plot ──────────────────────────────────────────────────────────────────

edit("src/routes/teams/plot.tsx", "useRanks", (s) => {
  const w = "teams/plot.tsx";
  s = once(s, `import { api } from "../../../convex/_generated/api";`,
    `import { api } from "../../../convex/_generated/api";\nimport { useRanks } from "@/lib/ranks";`, w);
  s = once(s, `type Source = "scouting" | "epa" | "xp";`, `type Source = "scouting" | "epa" | "xp" | "rank";`, w);
  s = once(s,
    "  xp: { xp: number; autoXp: number | null; teleopXp: number | null; endgameXp: number | null } | null;\n};",
    "  xp: { xp: number; autoXp: number | null; teleopXp: number | null; endgameXp: number | null } | null;\n  rank: number | null;\n};", w);
  s = once(s,
    `  { key: "xpEndgame", label: "xP endgame", source: "xp", get: (r) => r.xp?.endgameXp ?? null },`,
    `  { key: "xpEndgame", label: "xP endgame", source: "xp", get: (r) => r.xp?.endgameXp ?? null },
  // Plotted negative, like dead-hub fuel, so rank 1 lands top right with the
  // best of everything else; labels show it unsigned.
  { key: "rank", label: "Rank (TBA)", source: "rank", get: (r) => (r.rank === null ? null : -r.rank) },`, w);
  s = once(s, `  return metric.key === "avgUncountedFuel" ? Math.abs(v) : v;`,
    `  return metric.key === "avgUncountedFuel" || metric.key === "rank" ? Math.abs(v) : v;`, w);
  s = once(s, "  const shown = display(metric, v);\n",
    "  const shown = display(metric, v);\n  if (metric.key === \"rank\") return shown.toFixed(0);\n", w);
  s = once(s, "  const xpData = useQuery(api.match13.forEvent);\n",
    "  const xpData = useQuery(api.match13.forEvent);\n  const ranks = useRanks();\n", w);
  s = once(s, "      xp: xpByTeam.get(t.number) ?? null,\n",
    "      xp: xpByTeam.get(t.number) ?? null,\n      rank: ranks.byTeam.get(t.number) ?? null,\n", w);
  s = once(s, "  }, [teams, stats, epaData, xpData]);", "  }, [teams, stats, epaData, xpData, ranks]);", w);
  s = once(s, "Pick EPA or xP on both axes and these plot too.",
    "Pick EPA, xP or rank on both axes and these plot too.", w);
  return s;
});

// ─── Notes match page ──────────────────────────────────────────────────────

edit("src/routes/notes/match.tsx", "RankBadge", (s) => {
  const w = "notes/match.tsx";
  s = once(s, `import { useRatings } from "@/lib/stat-site";`,
    `import { useRatings } from "@/lib/stat-site";
import { useRanks } from "@/lib/ranks";
import { RankBadge } from "@/components/team-rank";`, w);
  s = once(s,
    `function Side({ label, robots, red }: { label: string; robots: Robot[]; red: boolean }) {
  return (`,
    `function Side({ label, robots, red }: { label: string; robots: Robot[]; red: boolean }) {
  const ranks = useRanks();
  return (`, w);
  s = once(s,
    `              <span className="text-muted-foreground text-sm font-normal">{robot.nickname}</span>`,
    `              <span className="text-muted-foreground text-sm font-normal">{robot.nickname}</span>
              <RankBadge rank={ranks.byTeam.get(robot.teamNumber)} className="ml-auto" />`, w);
  return s;
});

// ─── Write ─────────────────────────────────────────────────────────────────

for (const [path, content] of staged) {
  // Only when missing: Bun on Windows throws EEXIST for mkdir(".") even with
  // recursive set, which is the folder index.html sits in.
  const dir = dirname(path);
  if (dir !== "." && !existsSync(dir)) mkdirSync(dir, { recursive: true });
  writeFileSync(path, eol.get(path) === "\r\n" ? content.replace(/\n/g, "\r\n") : content);
}
console.log(report.join("\n"));
PATCH_EOF

say "Applying"
bun "$T/apply.mjs" "$T"

say "Typecheck"
if [[ -d node_modules ]]; then
  bunx tsc -b --noEmit && bunx tsc -p convex --noEmit && echo "Typecheck clean."
else
  echo "node_modules missing; run bun install, then bun run typecheck."
fi

cat <<'NEXT'

Next:
  1. bunx convex dev   (adds the teamRanks table), before the site goes live.
  2. Admin page -> Refresh Statbotics/match13/TBA to pull ranks now, or wait
     for the two-hour cron. Before quals start TBA has no rankings.
NEXT
