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
