#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# track-a.sh — Track A: TBA import, event setup, role management.
# Run from the REPO ROOT in Git Bash. Safe to re-run.
# Owns: convex/tba.ts, convex/events.ts, convex/profiles.ts, src/routes/admin/*
# Does NOT touch convex/schema.ts (frozen).
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f package.json ]] || { echo "ERROR: run from the folder with package.json" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "TBA import action"
cat > convex/tba.ts <<'EOF'
/// <reference types="node" />

import { v } from "convex/values";
import { action } from "./_generated/server";
import { internal } from "./_generated/api";

const TBA_BASE = "https://www.thebluealliance.com/api/v3";

type TbaEvent = { key: string; name: string };

type TbaTeam = {
  key: string;
  team_number: number;
  nickname: string | null;
  city: string | null;
  state_prov: string | null;
  country: string | null;
};

type TbaMatch = {
  key: string;
  comp_level: string;
  match_number: number;
  alliances: {
    red: { team_keys: string[] };
    blue: { team_keys: string[] };
  };
  time: number | null;
  predicted_time?: number | null;
};

async function tbaFetch<T>(path: string): Promise<T> {
  const apiKey = process.env.TBA_API_KEY;
  if (!apiKey) {
    throw new Error(
      "TBA_API_KEY is not set on this deployment. Run: bunx convex env set TBA_API_KEY <key>",
    );
  }

  const response = await fetch(`${TBA_BASE}${path}`, {
    headers: { "X-TBA-Auth-Key": apiKey, Accept: "application/json" },
  });

  if (response.status === 401) {
    throw new Error("The Blue Alliance rejected the API key (401).");
  }
  if (response.status === 404) {
    throw new Error(`Not found on The Blue Alliance: ${path}`);
  }
  if (!response.ok) {
    throw new Error(`TBA request failed: ${response.status} ${response.statusText}`);
  }

  return (await response.json()) as T;
}

/** "frc1002" -> 1002 */
function teamNumberFromKey(key: string): number {
  return Number.parseInt(key.replace(/^frc/, ""), 10);
}

/**
 * Imports teams and the qualification schedule for one event.
 *
 * Idempotent by tbaTeamKey / tbaMatchKey, so it is safe to re-run whenever the
 * schedule is revised mid-event — which happens routinely.
 */
export const importEvent = action({
  args: { tbaEventKey: v.string() },
  handler: async (ctx, args) => {
    const key = args.tbaEventKey.trim().toLowerCase();
    if (!/^\d{4}[a-z0-9]+$/.test(key)) {
      throw new Error(`"${args.tbaEventKey}" does not look like an event key (e.g. 2026gadal).`);
    }

    const userId = await ctx.runQuery(internal.profiles.adminUserId, {});

    const [event, teams, matches] = await Promise.all([
      tbaFetch<TbaEvent>(`/event/${key}/simple`),
      tbaFetch<TbaTeam[]>(`/event/${key}/teams/simple`),
      tbaFetch<TbaMatch[]>(`/event/${key}/matches/simple`),
    ]);

    const quals = matches
      .filter((m) => m.comp_level === "qm")
      .sort((a, b) => a.match_number - b.match_number);

    return await ctx.runMutation(internal.events.applyImport, {
      tbaEventKey: key,
      name: event.name,
      importedBy: userId,
      teams: teams.map((t) => ({
        tbaTeamKey: t.key,
        number: t.team_number,
        nickname: t.nickname ?? `Team ${t.team_number}`,
        city: t.city ?? "",
        stateProv: t.state_prov ?? "",
        country: t.country ?? "",
      })),
      matches: quals.map((m) => ({
        tbaMatchKey: m.key,
        matchNumber: m.match_number,
        redTeamNumbers: m.alliances.red.team_keys.map(teamNumberFromKey),
        blueTeamNumbers: m.alliances.blue.team_keys.map(teamNumberFromKey),
        // TBA reports epoch seconds; the app works in milliseconds throughout.
        scheduledTime: m.time !== null && m.time !== undefined ? m.time * 1000 : null,
      })),
    });
  },
});
EOF

say "Events: upsert and activation"
cat > convex/events.ts <<'EOF'
import { v } from "convex/values";
import { internalMutation, mutation, query } from "./_generated/server";
import { activeEvent, requireAdmin } from "./lib/guards";
import type { Id } from "./_generated/dataModel";

export const active = query({
  args: {},
  handler: async (ctx) => await activeEvent(ctx),
});

export const list = query({
  args: {},
  handler: async (ctx) => {
    const events = await ctx.db.query("events").collect();
    const withCounts = [];
    for (const event of events) {
      const teams = await ctx.db
        .query("teams")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const matches = await ctx.db
        .query("matches")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      withCounts.push({ ...event, teamCount: teams.length, matchCount: matches.length });
    }
    return withCounts.sort((a, b) => b._creationTime - a._creationTime);
  },
});

export const setActive = mutation({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    for (const e of await ctx.db.query("events").collect()) {
      if (e.isActive !== (e._id === args.eventId)) {
        await ctx.db.patch(e._id, { isActive: e._id === args.eventId });
      }
    }
  },
});

const teamInput = v.object({
  tbaTeamKey: v.string(),
  number: v.number(),
  nickname: v.string(),
  city: v.string(),
  stateProv: v.string(),
  country: v.string(),
});

const matchInput = v.object({
  tbaMatchKey: v.string(),
  matchNumber: v.number(),
  redTeamNumbers: v.array(v.number()),
  blueTeamNumbers: v.array(v.number()),
  scheduledTime: v.union(v.number(), v.null()),
});

/**
 * Upserts an event's teams and qualification schedule.
 *
 * Removal is deliberately conservative: a team or match that has disappeared
 * from TBA is only deleted when nothing references it. Withdrawn teams with
 * scouting data stay, because silently deleting a report a scout spent a match
 * writing is worse than a stale row on the pick list.
 */
export const applyImport = internalMutation({
  args: {
    tbaEventKey: v.string(),
    name: v.string(),
    importedBy: v.id("users"),
    teams: v.array(teamInput),
    matches: v.array(matchInput),
  },
  handler: async (ctx, args) => {
    let event = await ctx.db
      .query("events")
      .withIndex("by_key", (q) => q.eq("tbaEventKey", args.tbaEventKey))
      .unique();

    let eventId: Id<"events">;
    if (event) {
      eventId = event._id;
      await ctx.db.patch(eventId, {
        name: args.name,
        importedAt: Date.now(),
        importedBy: args.importedBy,
      });
    } else {
      eventId = await ctx.db.insert("events", {
        tbaEventKey: args.tbaEventKey,
        name: args.name,
        isActive: false,
        importedAt: Date.now(),
        importedBy: args.importedBy,
      });
    }

    // ---- teams ----
    const existingTeams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", eventId))
      .collect();
    const teamByKey = new Map(existingTeams.map((t) => [t.tbaTeamKey, t]));
    const incomingTeamKeys = new Set(args.teams.map((t) => t.tbaTeamKey));

    let teamsAdded = 0;
    let teamsUpdated = 0;
    for (const t of args.teams) {
      const existing = teamByKey.get(t.tbaTeamKey);
      if (existing) {
        await ctx.db.patch(existing._id, {
          number: t.number,
          nickname: t.nickname,
          city: t.city,
          stateProv: t.stateProv,
          country: t.country,
        });
        teamsUpdated++;
      } else {
        await ctx.db.insert("teams", { eventId, ...t });
        teamsAdded++;
      }
    }

    let teamsRemoved = 0;
    let teamsKept = 0;
    for (const existing of existingTeams) {
      if (incomingTeamKeys.has(existing.tbaTeamKey)) continue;
      const pit = await ctx.db
        .query("pitReports")
        .withIndex("by_event_team", (q) =>
          q.eq("eventId", eventId).eq("teamId", existing._id))
        .first();
      const report = await ctx.db
        .query("matchReports")
        .withIndex("by_event_team", (q) =>
          q.eq("eventId", eventId).eq("teamId", existing._id))
        .first();
      if (pit === null && report === null) {
        await ctx.db.delete(existing._id);
        teamsRemoved++;
      } else {
        teamsKept++;
      }
    }

    // ---- matches ----
    const existingMatches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", eventId))
      .collect();
    const matchByKey = new Map(existingMatches.map((m) => [m.tbaMatchKey, m]));
    const incomingMatchKeys = new Set(args.matches.map((m) => m.tbaMatchKey));

    let matchesAdded = 0;
    let matchesUpdated = 0;
    for (const m of args.matches) {
      const existing = matchByKey.get(m.tbaMatchKey);
      if (existing) {
        await ctx.db.patch(existing._id, {
          matchNumber: m.matchNumber,
          redTeamNumbers: m.redTeamNumbers,
          blueTeamNumbers: m.blueTeamNumbers,
          scheduledTime: m.scheduledTime,
        });
        matchesUpdated++;
      } else {
        await ctx.db.insert("matches", { eventId, ...m });
        matchesAdded++;
      }
    }

    let matchesRemoved = 0;
    for (const existing of existingMatches) {
      if (incomingMatchKeys.has(existing.tbaMatchKey)) continue;
      const report = await ctx.db
        .query("matchReports")
        .withIndex("by_match", (q) => q.eq("matchId", existing._id))
        .first();
      if (report === null) {
        await ctx.db.delete(existing._id);
        matchesRemoved++;
      }
    }

    return {
      eventId,
      name: args.name,
      teamsAdded, teamsUpdated, teamsRemoved, teamsKept,
      matchesAdded, matchesUpdated, matchesRemoved,
    };
  },
});
EOF

say "Profiles: internal admin lookup"
cat > /tmp/profiles-patch.mjs <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
const path = "convex/profiles.ts";
let src = readFileSync(path, "utf8");

if (!src.includes("adminUserId")) {
  src = src.replace(
    'import { mutation, query } from "./_generated/server";',
    'import { internalQuery, mutation, query } from "./_generated/server";',
  );
  src += `
/**
 * Resolves the calling admin's user id. Actions cannot touch the database, so
 * the TBA import calls through here to authorise before fetching.
 */
export const adminUserId = internalQuery({
  args: {},
  handler: async (ctx) => {
    const profile = await requireAdmin(ctx);
    return profile.userId;
  },
});
`;
  writeFileSync(path, src);
  console.log("profiles.ts patched");
} else {
  console.log("profiles.ts already patched");
}
EOF
bun /tmp/profiles-patch.mjs

say "Admin UI"
cat > src/routes/admin/index.tsx <<'EOF'
import { useAction, useMutation, useQuery } from "convex/react";
import { CheckCircle2, Download, LoaderCircle } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import { PageShell } from "@/routes/page-shell";
import { RolesTable } from "./roles-table";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";

export default function AdminPage() {
  const events = useQuery(api.events.list);
  const importEvent = useAction(api.tba.importEvent);
  const setActive = useMutation(api.events.setActive);

  const [eventKey, setEventKey] = useState("");
  const [importing, setImporting] = useState(false);

  const runImport = async () => {
    setImporting(true);
    try {
      const result = await importEvent({ tbaEventKey: eventKey.trim() });
      toast.success(`Imported ${result.name}`, {
        description:
          `${result.teamsAdded} teams added, ${result.teamsUpdated} updated. ` +
          `${result.matchesAdded} matches added, ${result.matchesUpdated} updated.`,
      });
      if (result.teamsKept > 0) {
        toast.warning(`${result.teamsKept} withdrawn team(s) kept`, {
          description: "They have scouting data, so their reports were preserved.",
        });
      }
      setEventKey("");
    } catch (error) {
      toast.error("Import failed", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setImporting(false);
    }
  };

  return (
    <PageShell
      title="Admin"
      description="Event setup, scout roles and weighting."
    >
      <Card>
        <CardHeader>
          <CardTitle>Import an event</CardTitle>
          <CardDescription>
            Pulls teams and the qualification schedule from The Blue Alliance.
            Safe to re-run whenever the schedule is revised.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="event-key">TBA event key</Label>
            <div className="flex gap-2">
              <Input
                id="event-key"
                placeholder="2026gadal"
                value={eventKey}
                autoCapitalize="none"
                autoCorrect="off"
                spellCheck={false}
                onChange={(e) => setEventKey(e.target.value)}
              />
              <Button
                disabled={importing || eventKey.trim() === ""}
                onClick={() => void runImport()}
              >
                {importing ? (
                  <LoaderCircle className="size-4 animate-spin" />
                ) : (
                  <Download className="size-4" />
                )}
                Import
              </Button>
            </div>
            <p className="text-muted-foreground text-xs">
              The API key lives on the Convex deployment, never in the browser.
              Set it with <code>bunx convex env set TBA_API_KEY &lt;key&gt;</code>.
            </p>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Events</CardTitle>
          <CardDescription>
            One event is active at a time. Everything in the app reads from it.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-2">
          {events === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : events.length === 0 ? (
            <p className="text-muted-foreground text-sm">
              No events yet. Import one above.
            </p>
          ) : (
            events.map((event) => (
              <div
                key={event._id}
                className="flex flex-wrap items-center gap-3 rounded-lg border p-3"
              >
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <span className="truncate font-medium">{event.name}</span>
                    {event.isActive ? (
                      <Badge>
                        <CheckCircle2 className="size-3" />
                        Active
                      </Badge>
                    ) : null}
                  </div>
                  <p className="text-muted-foreground text-xs">
                    {event.tbaEventKey} · {event.teamCount} teams ·{" "}
                    {event.matchCount} qualification matches
                  </p>
                </div>
                {!event.isActive ? (
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => void setActive({ eventId: event._id })}
                  >
                    Set active
                  </Button>
                ) : null}
              </div>
            ))
          )}
        </CardContent>
      </Card>

      <RolesTable />
    </PageShell>
  );
}
EOF

cat > src/routes/admin/roles-table.tsx <<'EOF'
import { useMutation, useQuery } from "convex/react";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import type { Id } from "../../../convex/_generated/dataModel";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { SCOUT_WEIGHTS } from "@/lib/scoring";
import type { Role, WeightTier } from "@/lib/types";

const ROLES: ReadonlyArray<{ value: Role; label: string }> = [
  { value: "scout", label: "Scout" },
  { value: "admin", label: "Admin" },
];

const TIERS: ReadonlyArray<{ value: WeightTier; label: string }> = [
  { value: "normal", label: "Normal" },
  { value: "trusted", label: "Trusted" },
  { value: "lead", label: "Strat lead" },
];

export function RolesTable() {
  const profiles = useQuery(api.profiles.list);
  const me = useQuery(api.profiles.me);
  const setRole = useMutation(api.profiles.setRole);
  const setWeightTier = useMutation(api.profiles.setWeightTier);

  const adminCount = profiles?.filter((p) => p.role === "admin").length ?? 0;

  const changeRole = async (
    profileId: Id<"profiles">,
    role: Role,
    isSelf: boolean,
  ) => {
    // Nothing stops an admin removing the last admin, and recovering from that
    // needs the CLI. Guard it here rather than discovering it at a competition.
    if (role === "scout" && adminCount <= 1) {
      toast.error("That is the only admin", {
        description: "Promote someone else before stepping down.",
      });
      return;
    }
    await setRole({ profileId, role });
    if (isSelf && role === "scout") {
      toast.warning("You are no longer an admin.");
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>Scouts</CardTitle>
        <CardDescription>
          Weighting applies to the pick list merge: strat lead counts{" "}
          {SCOUT_WEIGHTS.lead}×, trusted {SCOUT_WEIGHTS.trusted}×, normal{" "}
          {SCOUT_WEIGHTS.normal}×. One strat lead outvotes{" "}
          {Math.ceil(SCOUT_WEIGHTS.lead / SCOUT_WEIGHTS.normal)} normal scouts.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-2">
        {profiles === undefined ? (
          <p className="text-muted-foreground text-sm">Loading…</p>
        ) : (
          profiles.map((profile) => {
            const isSelf = me?._id === profile._id;
            return (
              <div
                key={profile._id}
                className="flex flex-wrap items-center gap-3 rounded-lg border p-3"
              >
                <span className="min-w-0 flex-1 truncate text-sm font-medium">
                  {profile.displayName}
                  {isSelf ? (
                    <span className="text-muted-foreground font-normal"> (you)</span>
                  ) : null}
                </span>

                <div className="flex gap-1">
                  {ROLES.map((r) => (
                    <Button
                      key={r.value}
                      size="sm"
                      variant={profile.role === r.value ? "default" : "outline"}
                      onClick={() => void changeRole(profile._id, r.value, isSelf)}
                    >
                      {r.label}
                    </Button>
                  ))}
                </div>

                <div className="flex gap-1">
                  {TIERS.map((t) => (
                    <Button
                      key={t.value}
                      size="sm"
                      variant={profile.weightTier === t.value ? "secondary" : "ghost"}
                      onClick={() =>
                        void setWeightTier({
                          profileId: profile._id,
                          weightTier: t.value,
                        })
                      }
                    >
                      {t.label}
                    </Button>
                  ))}
                </div>
              </div>
            );
          })
        )}
      </CardContent>
    </Card>
  );
}
EOF

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Track A written.

    bunx convex env set TBA_API_KEY <your-key>   # if not already set
    bunx convex dev --once
    # then open /admin and import an event key, e.g. 2026gadal

DONE
