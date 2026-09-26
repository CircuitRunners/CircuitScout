#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-match13.sh — match13 xP beside Statbotics EPA.
#
#   * match13 refreshes with Statbotics and TBA: the two-hour cron and the
#     Admin button. The key stays on the deployment (MATCH13_API_KEY).
#   * Admin: the refresh card is renamed and gains the stat-site toggle.
#     Full admins set the site-wide default (Statbotics / match13); team
#     admins set their own team (Default / Statbotics / match13).
#   * Team detail and match preview show EPA or xP, whichever the team
#     chose. The data plot always offers both.
#   * TBA, Statbotics and match13 icon links on the dashboard event name,
#     the open match's title and the team detail header. The dashboard's
#     "The Blue Alliance" text goes. Logos: public/statbotics.png and
#     public/match13.png, which you add yourself.
#   * xlsx export: xP columns on the teams sheet, projected xP on the
#     match sheet, alongside the EPA ones.
#   * statbotics.refreshAll is full-admin only; the cron uses an internal
#     twin. Purging or removing an event deletes its EPA and xP rows.
#   * Favicon points at logo.png.
#
# Every edit is checked before anything is written, and the script is safe
# to re-run: files already patched are skipped. It also upgrades a repo
# that already ran the first version of this patch.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/schema.ts && -f src/routes/dashboard.tsx ]] || {
  echo "ERROR: run from the repo root" >&2; exit 1; }
command -v bun >/dev/null || { echo "ERROR: bun not found" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# Relative on purpose: Git Bash rewrites /tmp in arguments but not inside
# the strings a script reads, so an absolute /tmp path breaks on Windows.
T=.patch-match13-tmp
rm -rf "$T"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

say "Staging files"
cat > "$T/match13.ts" <<'PATCH_EOF'
/// <reference types="node" />

import { v } from "convex/values";
import { internalAction, internalMutation, query } from "./_generated/server";
import { internal } from "./_generated/api";
import { activeEvent } from "./lib/guards";

const BASE = "https://actions.match13.com/v1";

/**
 * match13 xP for the caller's active event. The twin of statbotics.forEvent,
 * with the same shape of answer so the two can sit side by side.
 */
export const forEvent = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return { rows: [], fetchedAt: null };
    const rows = await ctx.db
      .query("teamXp")
      .withIndex("by_event", (q) => q.eq("eventId", event._id))
      .collect();
    return {
      rows: rows.map((r) => ({
        teamNumber: r.teamNumber,
        xp: r.xp,
        autoXp: r.autoXp,
        teleopXp: r.teleopXp,
        endgameXp: r.endgameXp,
      })),
      fetchedAt: rows.reduce<number | null>(
        (max, r) => (max === null || r.fetchedAt > max ? r.fetchedAt : max), null),
    };
  },
});

export const store = internalMutation({
  args: {
    eventId: v.id("events"),
    rows: v.array(v.object({
      teamNumber: v.number(),
      xp: v.number(),
      autoXp: v.union(v.number(), v.null()),
      teleopXp: v.union(v.number(), v.null()),
      endgameXp: v.union(v.number(), v.null()),
    })),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("teamXp")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    const byTeam = new Map(existing.map((r) => [r.teamNumber, r]));
    const now = Date.now();

    for (const row of args.rows) {
      const fields = { ...row, fetchedAt: now };
      const found = byTeam.get(row.teamNumber);
      if (found) await ctx.db.patch(found._id, fields);
      else await ctx.db.insert("teamXp", { eventId: args.eventId, ...fields });
    }
    return { stored: args.rows.length };
  },
});

const num = (value: unknown): number | null =>
  typeof value === "number" && Number.isFinite(value) ? value : null;

async function fetchEvent(eventKey: string) {
  // The key stays on the deployment. match13 sends no CORS headers, so a
  // browser could not call it anyway — and every key on one account shares
  // one allowance, which is why this runs on a cron and never per page view.
  const key = process.env.MATCH13_API_KEY;
  if (!key) {
    throw new Error("MATCH13_API_KEY is not set on this deployment.");
  }

  // One request for the whole event, like Statbotics: one call per active
  // event every two hours is nowhere near the 1,000-an-hour allowance.
  const response = await fetch(
    `${BASE}/events/${encodeURIComponent(eventKey)}/teams`,
    { headers: { Authorization: `Bearer ${key}`, Accept: "application/json" } },
  );
  if (response.status === 404) {
    throw new Error(`match13 has no data for ${eventKey} yet.`);
  }
  if (response.status === 401 || response.status === 403) {
    throw new Error("match13 rejected the API key. Check MATCH13_API_KEY.");
  }
  if (response.status === 429) {
    const after = response.headers.get("Retry-After");
    throw new Error(
      `match13 rate limit reached${after ? `; try again in ${after}s` : ""}.`,
    );
  }
  if (!response.ok) {
    throw new Error(`match13 returned ${response.status} for ${eventKey}.`);
  }

  const body = (await response.json()) as { teams?: unknown } | null;
  const list: unknown[] = Array.isArray(body?.teams) ? body.teams : [];
  if (list.length === 0) {
    throw new Error(`match13 has no teams for ${eventKey} yet.`);
  }

  // xpEnd is the rating a team holds now, or left the event with.
  // xAuto + xTele + xEnd add up to it.
  const rows = list.flatMap((row) => {
    const r = (row ?? {}) as Record<string, unknown>;
    const teamNumber = num(r.teamNumber);
    const xp = num(r.xpEnd);
    if (teamNumber === null || xp === null) return [];
    return [{
      teamNumber,
      xp,
      autoXp: num(r.xAuto),
      teleopXp: num(r.xTele),
      endgameXp: num(r.xEnd),
    }];
  });

  // Rows arrived but nothing parsed: a changed field name, not an empty
  // event. Show the shape rather than storing nothing and calling it done.
  if (rows.length === 0) {
    throw new Error(
      `Got ${list.length} rows from match13 but found no xpEnd. First row: ${JSON.stringify(list[0]).slice(0, 400)}`,
    );
  }
  return rows;
}

/**
 * Pull one event. Internal only: the Admin button reaches it through
 * refresh.now, which checks the caller is an admin first, and the cron calls
 * it directly. Nothing outside can spend the account's allowance.
 */
export const refreshEvent = internalAction({
  args: { eventId: v.id("events"), eventKey: v.string() },
  handler: async (ctx, args): Promise<{ stored: number }> => {
    const rows = await fetchEvent(args.eventKey);
    return await ctx.runMutation(internal.match13.store, {
      eventId: args.eventId,
      rows,
    });
  },
});
PATCH_EOF

cat > "$T/statSite.ts" <<'PATCH_EOF'
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import type { QueryCtx } from "./_generated/server";
import { currentProfile, requireAdmin, requireTeamAdmin } from "./lib/guards";

type StatSite = "statbotics" | "match13";

const site = v.union(v.literal("statbotics"), v.literal("match13"));

/** Statbotics until a full admin says otherwise. */
async function siteWideDefault(ctx: QueryCtx): Promise<StatSite> {
  const row = await ctx.db.query("siteSettings").first();
  return row?.defaultStatSite ?? "statbotics";
}

/**
 * Which rating the caller's team sees. `team` is null when the team follows
 * the site-wide default, which is what "Default" in the team admin's toggle
 * means — so changing the default moves every team that never chose.
 */
export const mine = query({
  args: {},
  handler: async (ctx) => {
    const profile = await currentProfile(ctx);
    const siteWide = await siteWideDefault(ctx);
    const teamNumber = profile?.teamNumber;

    let team: StatSite | null = null;
    if (teamNumber !== undefined) {
      const settings = await ctx.db
        .query("teamSettings")
        .withIndex("by_team", (q) => q.eq("teamNumber", teamNumber))
        .unique();
      team = settings?.statSite ?? null;
    }
    return {
      siteWide,
      team,
      effective: team ?? siteWide,
      teamNumber: teamNumber ?? null,
    };
  },
});

/** Full admins only: the site every team on Default follows. */
export const setDefault = mutation({
  args: { site },
  handler: async (ctx, args) => {
    const me = await requireAdmin(ctx);
    const existing = await ctx.db.query("siteSettings").first();
    const fields = { defaultStatSite: args.site, updatedAt: Date.now(), updatedBy: me.userId };
    if (existing) await ctx.db.patch(existing._id, fields);
    else await ctx.db.insert("siteSettings", fields);
  },
});

/**
 * A team admin's choice for their own team. Always the caller's own team —
 * there is no team argument to get wrong. "default" clears the choice.
 */
export const setForTeam = mutation({
  args: { site: v.union(v.literal("default"), site) },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const teamNumber = me.teamNumber;
    if (teamNumber === undefined) {
      throw new Error("Your profile has no team number.");
    }
    const statSite = args.site === "default" ? undefined : args.site;

    const existing = await ctx.db
      .query("teamSettings")
      .withIndex("by_team", (q) => q.eq("teamNumber", teamNumber))
      .unique();
    if (existing) {
      // Patching a field to undefined removes it, which is exactly "Default".
      await ctx.db.patch(existing._id, {
        statSite, updatedAt: Date.now(), updatedBy: me.userId,
      });
      return;
    }
    // A team that has never activated an event still gets a row, with no
    // event, the same state "Stand down" leaves behind.
    await ctx.db.insert("teamSettings", {
      teamNumber,
      activeEventId: null,
      statSite,
      updatedAt: Date.now(),
      updatedBy: me.userId,
    });
  },
});
PATCH_EOF

cat > "$T/refresh.ts" <<'PATCH_EOF'
import { action, internalAction } from "./_generated/server";
import { internal, api } from "./_generated/api";
import type { Id } from "./_generated/dataModel";

const message = (error: unknown) =>
  error instanceof Error ? error.message : String(error);

/**
 * Statbotics EPA, match13 xP and TBA scores together — they go stale at the
 * same rate and for the same reason, so refreshing them separately just means
 * one of them is always older than the others.
 */
export const now = action({
  args: {},
  handler: async (ctx): Promise<{
    epaTeams: number;
    xpTeams: number;
    matchesUpdated: number;
    problems: string[];
  }> => {
    await ctx.runQuery(internal.statbotics.requireAdminCheck, {});
    const event = await ctx.runQuery(internal.statbotics.activeEventKey, {});
    if (!event) throw new Error("No active event.");

    // Independent failures: one source having no data for a new event should
    // not stop the other two. What did fail is returned, not swallowed, so a
    // missing match13 key shows up instead of a quiet "Refreshed".
    let epaTeams = 0;
    let xpTeams = 0;
    let matchesUpdated = 0;
    const problems: string[] = [];

    try {
      const result = await ctx.runAction(api.statbotics.refresh, {});
      epaTeams = result.stored;
    } catch (error) {
      problems.push(message(error));
    }

    try {
      const result = await ctx.runAction(internal.match13.refreshEvent, {
        eventId: event.eventId as Id<"events">,
        eventKey: event.eventKey,
      });
      xpTeams = result.stored;
    } catch (error) {
      problems.push(message(error));
    }

    try {
      const result = await ctx.runAction(api.tba.refreshScores, {
        eventKey: event.eventKey,
      });
      matchesUpdated = result.updated;
    } catch (error) {
      problems.push(message(error));
    }

    if (epaTeams === 0 && xpTeams === 0 && matchesUpdated === 0 && problems.length > 0) {
      throw new Error(problems.join(" · "));
    }
    return { epaTeams, xpTeams, matchesUpdated, problems };
  },
});

/**
 * The cron. Iterates only events some team currently has active, so a
 * deployment sitting idle between competitions makes no outbound calls at all.
 */
export const scheduled = internalAction({
  args: {},
  handler: async (ctx): Promise<{ events: number }> => {
    const events = await ctx.runQuery(internal.statbotics.activeEventKeys, {});
    if (events.length === 0) return { events: 0 };

    for (const event of events) {
      try {
        await ctx.runAction(api.tba.refreshScores, { eventKey: event.eventKey });
      } catch {
        // A single event failing must not stop the rest.
      }
      try {
        await ctx.runAction(internal.match13.refreshEvent, {
          eventId: event.eventId as Id<"events">,
          eventKey: event.eventKey,
        });
      } catch {
        // Nor must match13 having nothing for it yet.
      }
    }
    const epa = await ctx.runAction(internal.statbotics.refreshAllScheduled, {});
    return { events: epa.events };
  },
});
PATCH_EOF

cat > "$T/stat-site.ts" <<'PATCH_EOF'
import { useQuery } from "convex/react";
import { useMemo } from "react";

import { api } from "../../convex/_generated/api";

export type StatSite = "statbotics" | "match13";

export type Rating = {
  total: number;
  auto: number | null;
  teleop: number | null;
  endgame: number | null;
};

export const STAT_SITE_NAME: Record<StatSite, string> = {
  statbotics: "Statbotics",
  match13: "match13",
};

export const STAT_SITE_METRIC: Record<StatSite, string> = {
  statbotics: "EPA",
  match13: "xP",
};

/**
 * The rating the user's team has chosen, Statbotics EPA or match13 xP, keyed
 * by team number. Only the chosen source is subscribed to; the other query
 * is skipped rather than read and thrown away.
 *
 * The data plot does not use this: it offers both, whatever is chosen.
 */
export function useRatings() {
  const choice = useQuery(api.statSite.mine);
  const site = choice?.effective;
  const epa = useQuery(api.statbotics.forEvent, site === "statbotics" ? {} : "skip");
  const xp = useQuery(api.match13.forEvent, site === "match13" ? {} : "skip");

  const byTeam = useMemo(() => {
    const map = new Map<number, Rating>();
    if (site === "statbotics") {
      for (const r of epa?.rows ?? []) {
        map.set(r.teamNumber, {
          total: r.epa, auto: r.autoEpa, teleop: r.teleopEpa, endgame: r.endgameEpa,
        });
      }
    } else if (site === "match13") {
      for (const r of xp?.rows ?? []) {
        map.set(r.teamNumber, {
          total: r.xp, auto: r.autoXp, teleop: r.teleopXp, endgame: r.endgameXp,
        });
      }
    }
    return map;
  }, [site, epa, xp]);

  const loading =
    site === "statbotics" ? epa === undefined
      : site === "match13" ? xp === undefined
        : true;
  const shown: StatSite = site ?? "statbotics";

  return {
    loading,
    site: shown,
    siteName: STAT_SITE_NAME[shown],
    metric: STAT_SITE_METRIC[shown],
    byTeam,
  };
}
PATCH_EOF

cat > "$T/stat-links.tsx" <<'PATCH_EOF'
import { ExternalLink } from "lucide-react";
import { useState } from "react";

type Target =
  | { kind: "event"; eventKey: string }
  | { kind: "match"; eventKey: string; matchKey: string }
  | { kind: "team"; eventKey: string; teamNumber: number };

const TBA = "https://www.thebluealliance.com";
const STATBOTICS = "https://www.statbotics.io";
const MATCH13 = "https://www.match13.com";

/** The season, from the event key's first four characters. */
function season(eventKey: string): number | null {
  const year = Number.parseInt(eventKey.slice(0, 4), 10);
  return Number.isNaN(year) ? null : year;
}

/**
 * All three sites key events and matches the same way, so one key serves
 * every link. Team pages are pinned to the event's season, so an archived
 * event's links still land on the year it was played.
 */
function urls(target: Target) {
  if (target.kind === "event") {
    const key = encodeURIComponent(target.eventKey);
    return {
      tba: `${TBA}/event/${key}`,
      statbotics: `${STATBOTICS}/event/${key}`,
      match13: `${MATCH13}/event/${key}`,
    };
  }
  if (target.kind === "match") {
    const key = encodeURIComponent(target.matchKey);
    return {
      tba: `${TBA}/match/${key}`,
      statbotics: `${STATBOTICS}/match/${key}`,
      match13: `${MATCH13}/match/${key}`,
    };
  }
  const n = target.teamNumber;
  const year = season(target.eventKey);
  return {
    tba: `${TBA}/team/${n}${year ? `/${year}` : ""}`,
    statbotics: `${STATBOTICS}/team/${n}${year ? `/${year}` : ""}`,
    match13: `${MATCH13}/team/${n}${year ? `?year=${year}` : ""}`,
  };
}

/**
 * The logos live in public/ and can go missing — a renamed file, a failed
 * deploy. Falls back to a generic external-link icon rather than leaving a
 * broken image in a heading.
 */
function SiteLink({ href, src, name }: { href: string; src: string; name: string }) {
  const [failed, setFailed] = useState(false);
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer noopener"
      title={name}
      aria-label={`Open on ${name}`}
      className="text-muted-foreground hover:text-foreground hover:bg-accent inline-flex size-8 shrink-0 items-center justify-center rounded-md transition-colors"
    >
      {failed ? (
        <ExternalLink className="size-4" />
      ) : (
        <img src={src} alt="" className="size-4 rounded-sm object-contain"
          onError={() => setFailed(true)} />
      )}
    </a>
  );
}

/**
 * The Blue Alliance, Statbotics and match13, icon only. Sized as 32px tap
 * targets so a thumb on a phone hits the logo it meant to.
 */
export function StatLinks(props: Target) {
  const u = urls(props);
  return (
    <span className="inline-flex shrink-0 items-center self-center">
      <SiteLink href={u.tba} src="/tba.png" name="The Blue Alliance" />
      <SiteLink href={u.statbotics} src="/statbotics.png" name="Statbotics" />
      <SiteLink href={u.match13} src="/match13.png" name="match13" />
    </span>
  );
}
PATCH_EOF

cat > "$T/stat-sources-card.tsx" <<'PATCH_EOF'
import { useAction, useMutation, useQuery } from "convex/react";
import { LoaderCircle } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import { STAT_SITE_METRIC, STAT_SITE_NAME, type StatSite } from "@/lib/stat-site";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

const errorText = (error: unknown) =>
  error instanceof Error ? error.message : String(error);

/** A row of joined buttons, one of which is on. */
function Segmented<T extends string>({
  value, options, onChange, disabled, label,
}: {
  value: T;
  options: ReadonlyArray<{ value: T; label: string }>;
  onChange: (next: T) => void;
  disabled: boolean;
  label: string;
}) {
  return (
    <div role="radiogroup" aria-label={label}
      className="inline-flex overflow-hidden rounded-md border">
      {options.map((option, i) => {
        const on = option.value === value;
        return (
          <button key={option.value} type="button" role="radio" aria-checked={on}
            disabled={disabled}
            onClick={() => { if (!on) onChange(option.value); }}
            className={[
              "px-3 py-2 text-sm transition-colors disabled:opacity-60",
              i > 0 ? "border-l" : "",
              on ? "bg-primary text-primary-foreground" : "hover:bg-accent",
            ].join(" ")}>
            {option.label}
          </button>
        );
      })}
    </div>
  );
}

const SITE_OPTIONS = [
  { value: "statbotics", label: "Statbotics" },
  { value: "match13", label: "match13" },
] as const satisfies ReadonlyArray<{ value: StatSite; label: string }>;

const TEAM_OPTIONS = [
  { value: "default", label: "Default" },
  ...SITE_OPTIONS,
] as const;

/**
 * Statbotics, match13 and TBA: the manual refresh, and which rating teams
 * see. A full admin sets the site-wide default; a team admin sets their own
 * team, where Default means "whatever the full admin chose".
 */
export function StatSourcesCard({ isFullAdmin }: { isFullAdmin: boolean }) {
  const refreshAll = useAction(api.refresh.now);
  const epa = useQuery(api.statbotics.forEvent);
  const xp = useQuery(api.match13.forEvent);
  const choice = useQuery(api.statSite.mine);
  const setDefault = useMutation(api.statSite.setDefault);
  const setForTeam = useMutation(api.statSite.setForTeam);
  const [refreshing, setRefreshing] = useState(false);
  const [saving, setSaving] = useState(false);

  const counts = [
    epa?.fetchedAt ? `EPA ${epa.rows.length} teams` : null,
    xp?.fetchedAt ? `xP ${xp.rows.length} teams` : null,
  ].filter((part): part is string => part !== null);
  const pulledAt = Math.max(epa?.fetchedAt ?? 0, xp?.fetchedAt ?? 0);
  const status = counts.length === 0
    ? "Never pulled yet"
    : `${counts.join(" · ")} · pulled ${new Date(pulledAt).toLocaleString()}`;

  const save = (run: () => Promise<unknown>, done: string) => {
    setSaving(true);
    void run()
      .then(() => toast.success(done))
      .catch((error: unknown) =>
        toast.error("Could not save", { description: errorText(error) }))
      .finally(() => setSaving(false));
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>Statbotics, match13 &amp; TBA</CardTitle>
        <CardDescription>
          EPA, xP and match scores refresh together every two hours, and only
          while a team has an event active. Pull them now if you want the
          numbers current before alliance selection.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="flex flex-wrap items-center gap-3">
          <Button variant="outline" disabled={refreshing}
            onClick={() => {
              setRefreshing(true);
              void refreshAll({})
                .then((r) => {
                  const summary =
                    `EPA for ${r.epaTeams} teams · xP for ${r.xpTeams} teams · ` +
                    `${r.matchesUpdated} matches updated.`;
                  if (r.problems.length > 0) {
                    toast.warning("Refreshed, with problems", {
                      description: `${summary} ${r.problems.join(" · ")}`,
                    });
                  } else {
                    toast.success("Refreshed", { description: summary });
                  }
                })
                .catch((error: unknown) =>
                  toast.error("Refresh failed", { description: errorText(error) }))
                .finally(() => setRefreshing(false));
            }}>
            {refreshing ? <LoaderCircle className="size-4 animate-spin" /> : null}
            Refresh Statbotics/match13/TBA
          </Button>
          <span className="text-muted-foreground text-xs">{status}</span>
        </div>

        {choice === undefined ? null : isFullAdmin ? (
          <div className="space-y-2 border-t pt-4">
            <p className="text-sm font-medium">Default stat site</p>
            <Segmented label="Default stat site" value={choice.siteWide}
              options={SITE_OPTIONS} disabled={saving}
              onChange={(next) => save(
                () => setDefault({ site: next }),
                `Default stat site is now ${STAT_SITE_NAME[next]}`,
              )} />
            <p className="text-muted-foreground text-xs">
              Used by every team left on Default. Teams that picked a site keep
              their choice.
            </p>
          </div>
        ) : choice.teamNumber === null ? (
          <p className="text-muted-foreground border-t pt-4 text-xs">
            Add a team number to your profile to choose a stat site for your team.
          </p>
        ) : (
          <div className="space-y-2 border-t pt-4">
            <p className="text-sm font-medium">Stat site for team {choice.teamNumber}</p>
            <Segmented label={`Stat site for team ${choice.teamNumber}`}
              value={choice.team ?? "default"} options={TEAM_OPTIONS} disabled={saving}
              onChange={(next) => save(
                () => setForTeam({ site: next }),
                next === "default"
                  ? "Following the site-wide default"
                  : `Team ${choice.teamNumber} now uses ${STAT_SITE_NAME[next]}`,
              )} />
            <p className="text-muted-foreground text-xs">
              {choice.team === null
                ? `Follows the site-wide default, currently ${STAT_SITE_NAME[choice.siteWide]}. ` +
                  `Your team sees ${STAT_SITE_METRIC[choice.siteWide]}.`
                : `Your team sees ${STAT_SITE_METRIC[choice.team]} from ` +
                  `${STAT_SITE_NAME[choice.team]}, whatever the site-wide default is.`}
            </p>
          </div>
        )}
      </CardContent>
    </Card>
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

// ─── Convex ────────────────────────────────────────────────────────────────

create("convex/match13.ts", "match13.ts");
create("convex/statSite.ts", "statSite.ts");

edit("convex/schema.ts", "teamXp: defineTable", (s) => {
  s = once(s,
    `    activeEventId: v.union(v.id("events"), v.null()),
    updatedAt: v.number(),
    updatedBy: v.id("users"),
  }).index("by_team", ["teamNumber"]),`,
    `    activeEventId: v.union(v.id("events"), v.null()),
    /** Absent means "follow the site-wide default" in siteSettings. */
    statSite: v.optional(v.union(v.literal("statbotics"), v.literal("match13"))),
    updatedAt: v.number(),
    updatedBy: v.id("users"),
  }).index("by_team", ["teamNumber"]),`,
    "schema.ts teamSettings");
  s = once(s,
    `  /**
   * Statbotics EPA for one team at one event.`,
    `  /**
   * match13 xP for one team at one event: teamEpa's twin. Refreshed on the
   * same cron and kept apart, so either source failing leaves the other
   * intact. xp is match13's xpEnd, the rating the team holds now.
   */
  teamXp: defineTable({
    eventId: v.id("events"),
    teamNumber: v.number(),
    xp: v.number(),
    autoXp: v.union(v.number(), v.null()),
    teleopXp: v.union(v.number(), v.null()),
    endgameXp: v.union(v.number(), v.null()),
    fetchedAt: v.number(),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamNumber"]),

  /**
   * Deployment-wide settings, one row. For now only the default stat site:
   * what a team sees until its own admin picks one in teamSettings.
   */
  siteSettings: defineTable({
    defaultStatSite: v.union(v.literal("statbotics"), v.literal("match13")),
    updatedAt: v.number(),
    updatedBy: v.id("users"),
  }),

  /**
   * Statbotics EPA for one team at one event.`,
    "schema.ts tables");
  return s;
});

edit("convex/refresh.ts", "refreshAllScheduled", (s) => {
  if (!s.includes("export const now = action({")
      || !s.includes("export const scheduled = internalAction({")
      || count(s, "export const ") !== 2) {
    fail("convex/refresh.ts has changed from the version this patch knows; not overwriting it.");
  }
  return snippet("refresh.ts");
});

edit("convex/statbotics.ts", "refreshAllScheduled", (s) => {
  const w = "statbotics.ts";
  s = once(s,
    `import { action, internalMutation, internalQuery, query } from "./_generated/server";`,
    `import { action, internalAction, internalMutation, internalQuery, query } from "./_generated/server";
import type { ActionCtx } from "./_generated/server";`, w);
  s = once(s,
    `import { activeEvent, requireTeamAdmin } from "./lib/guards";`,
    `import { activeEvent, requireAdmin, requireTeamAdmin } from "./lib/guards";`, w);
  s = between(s,
    "/** Called by the cron for every event a team currently has active. */",
    "export const activeEventKeys = internalQuery({",
    `/** Every event a team currently has active, one request each. */
async function refreshActiveEvents(ctx: ActionCtx): Promise<{ events: number }> {
  const events = await ctx.runQuery(internal.statbotics.activeEventKeys, {});
  let done = 0;
  for (const event of events) {
    try {
      const { rows, sample } = await fetchEvent(event.eventKey);
      await ctx.runMutation(internal.statbotics.store, {
        eventId: event.eventId as Id<"events">,
        rows,
        sample,
      });
      done += 1;
    } catch {
      // One event without Statbotics data must not stop the others.
    }
  }
  return { events: done };
}

/**
 * Every active event at once. Full admins only: it was public with no check,
 * so any signed-out client could make the deployment call Statbotics.
 */
export const refreshAll = action({
  args: {},
  handler: async (ctx): Promise<{ events: number }> => {
    await ctx.runQuery(internal.statbotics.requireFullAdminCheck, {});
    return await refreshActiveEvents(ctx);
  },
});

/** The cron's way in. It runs with no signed-in user, so it cannot pass the check above. */
export const refreshAllScheduled = internalAction({
  args: {},
  handler: async (ctx): Promise<{ events: number }> => await refreshActiveEvents(ctx),
});

export const requireFullAdminCheck = internalQuery({
  args: {},
  handler: async (ctx) => {
    await requireAdmin(ctx);
    return true;
  },
});

`, `${w} refreshAll`, "export const refreshAll = action({");
  return s;
});

edit("convex/events.ts", "deleteRatings", (s) => {
  const w = "events.ts";
  s = once(s,
    "/** Shared by the immediate purge and the scheduled one. */",
    `/**
 * Statbotics EPA and match13 xP for one event. Both can be fetched again at
 * any time, so nothing is lost; left behind, they sat in the tables forever.
 */
async function deleteRatings(ctx: MutationCtx, eventId: Id<"events">) {
  const epa = await ctx.db
    .query("teamEpa")
    .withIndex("by_event", (q) => q.eq("eventId", eventId))
    .collect();
  for (const row of epa) await ctx.db.delete(row._id);
  const xp = await ctx.db
    .query("teamXp")
    .withIndex("by_event", (q) => q.eq("eventId", eventId))
    .collect();
  for (const row of xp) await ctx.db.delete(row._id);
}

/** Shared by the immediate purge and the scheduled one. */`, w);
  // The 24-hour purge, and Purge now, which share purgeEventData.
  s = after(s, "async function purgeEventData(",
    "    // Any team pointing at this event is left with none rather than a",
    `    await deleteRatings(ctx, args.eventId);

    // Any team pointing at this event is left with none rather than a`, `${w} purge`);
  // Remove, for an imported event nobody scouted.
  s = once(s,
    `    for (const team of teams) await ctx.db.delete(team._id);

    for (const list of lists) await ctx.db.delete(list._id);`,
    `    for (const team of teams) await ctx.db.delete(team._id);

    for (const list of lists) await ctx.db.delete(list._id);

    await deleteRatings(ctx, args.eventId);`, `${w} remove`);
  return s;
});

edit("convex/workbook.ts", "xpByNumber", (s) => {
  const w = "workbook.ts";
  s = once(s,
    "const [reports, matches, teams, pit, epaRows, profiles] = await Promise.all([",
    "const [reports, matches, teams, pit, epaRows, xpRows, profiles] = await Promise.all([", w);
  s = once(s,
    `      ctx.db.query("teamEpa").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),`,
    `      ctx.db.query("teamEpa").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),
      ctx.db.query("teamXp").withIndex("by_event", (q) => q.eq("eventId", event._id)).collect(),`, w);
  s = once(s,
    "    const epaByNumber = new Map(epaRows.map((r) => [r.teamNumber, r]));",
    `    const epaByNumber = new Map(epaRows.map((r) => [r.teamNumber, r]));
    const xpByNumber = new Map(xpRows.map((r) => [r.teamNumber, r]));`, w);
  s = once(s,
    "        const epa = epaByNumber.get(t.number);",
    "        const epa = epaByNumber.get(t.number);\n        const xp = xpByNumber.get(t.number);", w);
  // Both ratings, whichever site the team has chosen: a spreadsheet is
  // where someone goes to compare them.
  s = once(s,
    `          endgameEpa: epa?.endgameEpa ?? "",`,
    `          endgameEpa: epa?.endgameEpa ?? "",
          xp: xp?.xp ?? "",
          autoXp: xp?.autoXp ?? "",
          teleopXp: xp?.teleopXp ?? "",
          endgameXp: xp?.endgameXp ?? "",`, w);
  s = once(s,
    `    const projEpa = (nums: number[]) =>
      round1(nums.reduce((sum, n) => sum + (epaByNumber.get(n)?.epa ?? 0), 0));`,
    `    const projEpa = (nums: number[]) =>
      round1(nums.reduce((sum, n) => sum + (epaByNumber.get(n)?.epa ?? 0), 0));
    const projXp = (nums: number[]) =>
      round1(nums.reduce((sum, n) => sum + (xpByNumber.get(n)?.xp ?? 0), 0));`, w);
  s = once(s,
    "        blueProjEpa: projEpa(m.blueTeamNumbers),",
    `        blueProjEpa: projEpa(m.blueTeamNumbers),
        redProjXp: projXp(m.redTeamNumbers),
        blueProjXp: projXp(m.blueTeamNumbers),`, w);
  return s;
});

edit("convex/crons.ts", "refresh statbotics, match13 and tba", (s) =>
  once(s, `"refresh statbotics and tba",`, `"refresh statbotics, match13 and tba",`, "crons.ts"));

edit("convex/stats.ts", "tbaMatchKey: match.tbaMatchKey", (s) =>
  once(s,
    `      matchNumber: match.matchNumber,
      scheduledTime: match.scheduledTime,`,
    `      matchNumber: match.matchNumber,
      // For the TBA, Statbotics and match13 links beside the title.
      eventKey: event.tbaEventKey,
      tbaMatchKey: match.tbaMatchKey,
      scheduledTime: match.scheduledTime,`,
    "stats.ts forMatch"));

// `convex dev` regenerates this file. Adding the two modules here means
// the frontend typechecks before you next run it; the result is the same.
{
  const path = "convex/_generated/api.d.ts";
  let s = load(path);
  let changed = false;
  for (const [mod, beforeImport, beforeEntry] of [
    ["match13", `import type * as matchReports from "../matchReports.js";`, "  matchReports: typeof matchReports;"],
    ["statSite", `import type * as statbotics from "../statbotics.js";`, "  statbotics: typeof statbotics;"],
  ]) {
    if (!s.includes(`import type * as ${mod} from "../${mod}.js";`)) {
      s = once(s, beforeImport, `import type * as ${mod} from "../${mod}.js";\n${beforeImport}`, `api.d.ts import ${mod}`);
      changed = true;
    }
    if (!s.includes(`  ${mod}: typeof ${mod};`)) {
      s = once(s, beforeEntry, `  ${mod}: typeof ${mod};\n${beforeEntry}`, `api.d.ts entry ${mod}`);
      changed = true;
    }
  }
  if (changed) { staged.set(path, s); report.push(`edit   ${path}`); }
  else report.push(`skip   ${path} (already lists both modules)`);
}

// ─── Frontend ──────────────────────────────────────────────────────────────

create("src/lib/stat-site.ts", "stat-site.ts");
create("src/components/stat-links.tsx", "stat-links.tsx");
create("src/routes/admin/stat-sources-card.tsx", "stat-sources-card.tsx");

edit("src/routes/admin/index.tsx", "StatSourcesCard", (s) => {
  s = once(s,
    `import { UsageByTeamCard } from "./usage-card";`,
    `import { UsageByTeamCard } from "./usage-card";\nimport { StatSourcesCard } from "./stat-sources-card";`,
    "admin imports");
  s = once(s,
    `  const refreshBoth = useAction(api.refresh.now);
  const epa = useQuery(api.statbotics.forEvent);
  const [refreshing, setRefreshing] = useState(false);
`, "", "admin refresh state");
  s = between(s,
    `      <Card>
        <CardHeader>
          <CardTitle>Statbotics &amp; TBA</CardTitle>`,
    "      <RolesTable />",
    "      <StatSourcesCard isFullAdmin={isFullAdmin} />\n\n",
    "admin Statbotics & TBA card", "Refresh Statbotics/TBA");
  return s;
});

edit("src/routes/dashboard.tsx", "StatLinks", (s) => {
  s = once(s,
    `import { useState } from "react";\nimport { ExternalLink } from "lucide-react";\n`, "",
    "dashboard imports");
  s = once(s,
    `import { EventExport } from "@/components/event-export";`,
    `import { EventExport } from "@/components/event-export";\nimport { StatLinks } from "@/components/stat-links";`,
    "dashboard imports");
  s = between(s, "/**\n * The mark is hotlinked from TBA", "function Metric({", "",
    "dashboard TbaLink", "function TbaLink");
  s = once(s,
    `<TbaLink eventKey={event.tbaEventKey} />`,
    `<StatLinks kind="event" eventKey={event.tbaEventKey} />`,
    "dashboard title");
  return s;
});

edit("src/routes/matches/preview.tsx", "useRatings", (s) => {
  const w = "matches/preview.tsx";
  s = once(s,
    `import { CompareTable } from "@/components/compare-table";`,
    `import { CompareTable } from "@/components/compare-table";
import { StatLinks } from "@/components/stat-links";
import { useRatings } from "@/lib/stat-site";`, w);
  s = once(s, "  const epaData = useQuery(api.statbotics.forEvent);\n",
    "  const ratings = useRatings();\n", w);
  s = once(s,
    `  const epaByTeam = new Map((epaData?.rows ?? []).map((r) => [r.teamNumber, r.epa]));
  const epaSum = (side: Robot[]) =>
    side.reduce((sum, r) => sum + (epaByTeam.get(r.teamNumber) ?? 0), 0);
  const epaCovered = (side: Robot[]) =>
    side.filter((r) => epaByTeam.has(r.teamNumber)).length;`,
    `  // EPA or xP, whichever site this team has chosen.
  const ratingSum = (side: Robot[]) =>
    side.reduce((sum, r) => sum + (ratings.byTeam.get(r.teamNumber)?.total ?? 0), 0);
  const ratingCovered = (side: Robot[]) =>
    side.filter((r) => ratings.byTeam.has(r.teamNumber)).length;`, w);
  s = once(s, "      title={`Qual ${data.matchNumber}`}",
    `      title={
        <>
          Qual {data.matchNumber}
          <StatLinks kind="match" eventKey={data.eventKey} matchKey={data.tbaMatchKey} />
        </>
      }`, w);
  s = once(s, "<CardTitle>Projected · EPA</CardTitle>",
    "<CardTitle>Projected · {ratings.metric}</CardTitle>", w);
  s = once(s, "              Statbotics EPA summed per alliance.",
    "              {ratings.siteName} {ratings.metric} summed per alliance.", w);
  s = once(s, "{epaData === undefined ? (", "{ratings.loading ? (", w);
  s = once(s, ") : epaByTeam.size === 0 ? (", ") : ratings.byTeam.size === 0 ? (", w);
  s = once(s, "No EPA yet — an admin", "No {ratings.metric} yet — an admin", w);
  s = once(s, "{epaSum(data.red).toFixed(0)}", "{ratingSum(data.red).toFixed(0)}", w);
  s = once(s, "{epaSum(data.blue).toFixed(0)}", "{ratingSum(data.blue).toFixed(0)}", w);
  s = once(s, "{epaCovered(data.red) + epaCovered(data.blue) < 6 ? (",
    "{ratingCovered(data.red) + ratingCovered(data.blue) < 6 ? (", w);
  s = once(s, "Only {epaCovered(data.red) + epaCovered(data.blue)} of 6 have EPA",
    "Only {ratingCovered(data.red) + ratingCovered(data.blue)} of 6 have {ratings.metric}", w);
  if (/\bepa(Data|ByTeam|Sum|Covered)\b/.test(s)) fail(`${w}: an EPA reference was left behind.`);
  return s;
});

edit("src/routes/teams/team-detail.tsx", "useRatings", (s) => {
  const w = "teams/team-detail.tsx";
  s = once(s,
    `import { TIER_LABELS, type Tier } from "@/lib/types";`,
    `import { TIER_LABELS, type Tier } from "@/lib/types";
import { StatLinks } from "@/components/stat-links";
import { useRatings } from "@/lib/stat-site";`, w);
  s = once(s,
    `function useEpa(teamNumber: number | null) {
  const data = useQuery(api.statbotics.forEvent);
  if (teamNumber === null) return null;
  return data?.rows.find((r) => r.teamNumber === teamNumber) ?? null;
}

`, "", w);
  s = once(s, "  const epa = useEpa(teamNumber);\n",
    `  // EPA or xP, whichever site this team has chosen.
  const ratings = useRatings();
  const rating = teamNumber === null ? null : (ratings.byTeam.get(teamNumber) ?? null);
  const event = useQuery(api.events.active);
`, w);
  s = once(s, "{epa ? (", "{rating ? (", w);
  s = once(s, `<p className="text-muted-foreground text-xs">EPA</p>`,
    `<p className="text-muted-foreground text-xs">{ratings.metric}</p>`, w);
  s = once(s, "{epa.epa.toFixed(1)}", "{rating.total.toFixed(1)}", w);
  s = once(s, "Statbotics, not your scouting", "{ratings.siteName}, not your scouting", w);
  s = once(s,
    `                ) : null}
              </DialogTitle>`,
    `                ) : null}
                {event ? (
                  <StatLinks kind="team" eventKey={event.tbaEventKey}
                    teamNumber={data.team.number} />
                ) : null}
              </DialogTitle>`, w);
  if (/\bepa\b/.test(s)) fail(`${w}: an EPA reference was left behind.`);
  return s;
});

edit("src/routes/teams/plot.tsx", "xpData", (s) => {
  const w = "teams/plot.tsx";
  s = once(s, `type Source = "scouting" | "epa";`, `type Source = "scouting" | "epa" | "xp";`, w);
  s = once(s,
    `  epa: { epa: number; autoEpa: number | null; teleopEpa: number | null; endgameEpa: number | null } | null;\n};`,
    `  epa: { epa: number; autoEpa: number | null; teleopEpa: number | null; endgameEpa: number | null } | null;
  xp: { xp: number; autoXp: number | null; teleopXp: number | null; endgameXp: number | null } | null;\n};`, w);
  s = once(s,
    `  { key: "epaEndgame", label: "EPA endgame", source: "epa", get: (r) => r.epa?.endgameEpa ?? null },`,
    `  { key: "epaEndgame", label: "EPA endgame", source: "epa", get: (r) => r.epa?.endgameEpa ?? null },
  // Always offered, whichever stat site the team has chosen, so the two
  // ratings can be plotted against each other.
  { key: "xp", label: "xP total", source: "xp", get: (r) => r.xp?.xp ?? null },
  { key: "xpAuto", label: "xP auto", source: "xp", get: (r) => r.xp?.autoXp ?? null },
  { key: "xpTeleop", label: "xP teleop", source: "xp", get: (r) => r.xp?.teleopXp ?? null },
  { key: "xpEndgame", label: "xP endgame", source: "xp", get: (r) => r.xp?.endgameXp ?? null },`, w);
  s = once(s, "/** Fraction of values at or below v.",
    `/**
 * Dead-hub fuel is plotted negative so more of it reads as worse; it is shown
 * unsigned. Every other metric keeps its sign: xP endgame can genuinely be
 * below zero, and printing it as positive would be wrong.
 */
function display(metric: Metric, v: number): number {
  return metric.key === "avgUncountedFuel" ? Math.abs(v) : v;
}

function tickLabel(metric: Metric, v: number): string {
  const shown = display(metric, v);
  return Math.abs(shown) >= 100 ? shown.toFixed(0) : shown.toFixed(1);
}

/** Fraction of values at or below v.`, w);
  const tick = "{Math.abs(v) >= 100 ? Math.abs(v).toFixed(0) : Math.abs(v).toFixed(1)}";
  s = after(s, `<text x={px(v)} y={VIEW.h - PAD.b + 15} textAnchor="middle">`, tick,
    "{tickLabel(xMetric, v)}", `${w} x ticks`);
  s = after(s, `<text x={PAD.l - 7} y={py(v) + 3} textAnchor="end">`, tick,
    "{tickLabel(yMetric, v)}", `${w} y ticks`);
  s = once(s, "{Math.abs(hovered.x).toFixed(1)}", "{display(xMetric, hovered.x).toFixed(1)}", w);
  s = once(s, "{Math.abs(hovered.y).toFixed(1)}", "{display(yMetric, hovered.y).toFixed(1)}", w);
  s = once(s, "  const epaData = useQuery(api.statbotics.forEvent);\n",
    "  const epaData = useQuery(api.statbotics.forEvent);\n  const xpData = useQuery(api.match13.forEvent);\n", w);
  s = once(s,
    "    const epaByTeam = new Map((epaData?.rows ?? []).map((r) => [r.teamNumber, r]));",
    "    const epaByTeam = new Map((epaData?.rows ?? []).map((r) => [r.teamNumber, r]));\n    const xpByTeam = new Map((xpData?.rows ?? []).map((r) => [r.teamNumber, r]));", w);
  s = once(s, "      epa: epaByTeam.get(t.number) ?? null,\n",
    "      epa: epaByTeam.get(t.number) ?? null,\n      xp: xpByTeam.get(t.number) ?? null,\n", w);
  s = once(s, "  }, [teams, stats, epaData]);", "  }, [teams, stats, epaData, xpData]);", w);
  s = once(s, "Pick EPA on both axes and these plot too.",
    "Pick EPA or xP on both axes and these plot too.", w);
  return s;
});

// ─── Favicon ───────────────────────────────────────────────────────────────
// Not a hard failure: your local index.html may already differ from GitHub.
{
  const path = "index.html";
  const s = load(path);
  const svgIcon = `<link rel="icon" type="image/svg+xml" href="/favicon.svg" />`;
  if (/<link[^>]*rel="icon"[^>]*href="\/logo\.png"/.test(s)) {
    report.push(`skip   ${path} (favicon already logo.png)`);
  } else if (count(s, svgIcon) === 1) {
    staged.set(path, s.replace(svgIcon, `<link rel="icon" type="image/png" href="/logo.png" />`));
    report.push(`edit   ${path}`);
  } else {
    report.push(`WARN   ${path}: no favicon.svg link found; change the icon line by hand`);
  }
  if (s.includes("<title>my-app</title>")) {
    report.push(`NOTE   ${path}: <title> is still "my-app"`);
  }
  if (!s.includes("apple-touch-icon")) {
    report.push(`NOTE   ${path}: no apple-touch-icon link`);
  }
}

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
  1. If you haven't yet:  bunx convex env set MATCH13_API_KEY m13_live_...
                          bunx convex env set MATCH13_API_KEY m13_live_... --prod
  2. Drop statbotics.png and match13.png into public/. Until then the links
     show a generic external-link icon.
  3. bunx convex dev  (pushes the schema, regenerates convex/_generated)
  4. Admin page -> Refresh Statbotics/match13/TBA. A missing or bad key shows
     as a "Refreshed, with problems" warning instead of failing everything.
  5. Optional cleanup, by hand: public/favicon.svg, public/icons.svg, my-app/
NEXT
