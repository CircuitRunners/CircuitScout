/// <reference types="node" />

import { v } from "convex/values";
import { action } from "./_generated/server";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";

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

type ImportResult = {
  eventId: Id<"events">;
  name: string;
  teamsAdded: number;
  teamsUpdated: number;
  teamsRemoved: number;
  teamsKept: number;
  matchesAdded: number;
  matchesUpdated: number;
  matchesRemoved: number;
};

/**
 * Imports teams and the qualification schedule for one event.
 *
 * Idempotent by tbaTeamKey / tbaMatchKey, so it is safe to re-run whenever the
 * schedule is revised mid-event — which happens routinely.
 */
export const importEvent = action({
  args: { tbaEventKey: v.string() },
  handler: async (ctx, args): Promise<ImportResult> => {
    const key = args.tbaEventKey.trim().toLowerCase();
    if (!/^\d{4}[a-z0-9]+$/.test(key)) {
      throw new Error(`"${args.tbaEventKey}" does not look like an event key (e.g. 2026gadal).`);
    }

    const userId: Id<"users"> = await ctx.runQuery(
      internal.profiles.adminUserId,
      {},
    );

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

type TbaTeamLookup = { key: string; team_number: number; nickname: string | null };

/**
 * Confirms the team exists on The Blue Alliance, then writes the profile.
 * An action rather than a mutation because a mutation cannot reach the
 * network, and a client-side check would be a suggestion rather than a rule.
 */
export const claimProfile = action({
  args: {
    firstName: v.string(),
    lastInitial: v.string(),
    teamNumber: v.number(),
  },
  handler: async (ctx, args): Promise<{ nickname: string }> => {
    if (!Number.isInteger(args.teamNumber) || args.teamNumber <= 0) {
      throw new Error("Team number must be a whole number.");
    }

    const apiKey = process.env.TBA_API_KEY;
    if (!apiKey) {
      throw new Error(
        "TBA_API_KEY is not set on this deployment, so team numbers cannot be checked. An admin needs to set it.",
      );
    }

    const response = await fetch(`${TBA_BASE}/team/frc${args.teamNumber}`, {
      headers: { "X-TBA-Auth-Key": apiKey, Accept: "application/json" },
    });
    if (response.status === 404) {
      throw new Error(`Team ${args.teamNumber} does not exist on The Blue Alliance.`);
    }
    if (!response.ok) {
      throw new Error(`Could not check that team number (${response.status}). Try again.`);
    }
    const team = (await response.json()) as TbaTeamLookup;

    const userId = await ctx.runQuery(internal.profiles.myUserId, {});
    await ctx.runMutation(internal.profiles.ensureInternal, {
      userId,
      firstName: args.firstName,
      lastInitial: args.lastInitial,
      teamNumber: args.teamNumber,
    });

    return { nickname: team.nickname ?? `Team ${args.teamNumber}` };
  },
});
