import type { FunctionReturnType } from "convex/server";

import type { api } from "../../../convex/_generated/api";

/**
 * Rebuilds, from the saved lists, what a per-match or per-team query would
 * have returned (offline plan, section 7). Pure functions, mirrored on the
 * Convex handlers named in each comment: if one of those handlers changes
 * what it returns, change its twin here in the same patch.
 *
 * Each returns:
 *   the data      the form can open
 *   null          the match or team is not at the active event (as the server says)
 *   "blocked"     it exists, but opening a blank form would overwrite saved
 *                 answers that are not on this device
 */

type Matches = FunctionReturnType<typeof api.matches.listForEvent>;
type Teams = FunctionReturnType<typeof api.teams.listWithStatus>;
type MyReports = FunctionReturnType<typeof api.matchReports.mine>;
type NoteTeams = NonNullable<FunctionReturnType<typeof api.notes.teams>>;
type MyNotes = FunctionReturnType<typeof api.notes.mine>;

export type MatchForm = NonNullable<FunctionReturnType<typeof api.matchReports.forMatchAndTeam>>;
export type PitForm = NonNullable<FunctionReturnType<typeof api.pit.forTeamNumber>>;
export type NoteMatchForm = NonNullable<FunctionReturnType<typeof api.notes.matchNote>>;
export type NotePitForm = NonNullable<FunctionReturnType<typeof api.notes.pitNote>>;

/** The part of a team the robot picker needs. */
export type Robot = { _id: string; number: number; nickname: string };
export type MatchRobots = { red: Array<Robot | null>; blue: Array<Robot | null> };

/**
 * matches.teamsInMatch. With a team list, a number missing from it is an
 * unknown team, as on the server. With no team list at all the numbers on
 * the schedule are still enough to open a form, so they are used as they are.
 */
export function deriveRobots(
  matches: Matches,
  teams: ReadonlyArray<Robot> | undefined,
  matchNumber: number,
): MatchRobots | null {
  const match = matches.find((m) => m.matchNumber === matchNumber);
  if (!match) return null;
  const robot = (number: number): Robot | null =>
    teams === undefined
      ? { _id: `team-${number}`, number, nickname: "" }
      : (teams.find((t) => t.number === number) ?? null);
  return { red: match.redTeamNumbers.map(robot), blue: match.blueTeamNumbers.map(robot) };
}

/**
 * matchReports.forMatchAndTeam.
 * - othersCount cannot be known offline; 0 makes the form leave the
 *   "other reports already submitted" line out.
 * - hopper comes from this scouting team's pit report, which the lists do not
 *   carry; pass the one from the last time this form was open, or null.
 */
export function deriveMatchForm(input: {
  matches: Matches;
  teams: Teams;
  myReports: MyReports | undefined;
  practicing: boolean;
  hopper: MatchForm["hopper"];
  matchNumber: number;
  teamNumber: number;
}): MatchForm | null {
  const match = input.matches.find((m) => m.matchNumber === input.matchNumber);
  const team = input.teams.find((t) => t.number === input.teamNumber);
  if (!match || !team) return null;
  return {
    match,
    team,
    myReport: findMyReport(input.myReports, input.practicing, match._id, team._id),
    othersCount: 0,
    alliance: match.redTeamNumbers.includes(team.number) ? "red" : "blue",
    hopper: input.hopper,
  };
}

/** In practice mode a robot can be practised again, so no report counts as mine. */
export function findMyReport(
  myReports: MyReports | undefined,
  practicing: boolean,
  matchId: string,
  teamId: string,
): MatchForm["myReport"] {
  if (practicing || !myReports) return null;
  return myReports.find((r) => r.matchId === matchId && r.teamId === teamId) ?? null;
}

/**
 * pit.forTeamNumber, for a team with no pit report. pit.upsert patches the
 * team's existing report, so a blank form for a team that already has one
 * would overwrite real answers when it syncs: that is "blocked". Practice
 * mode always starts blank and never touches the real report.
 */
export function derivePitForm(
  teams: Teams,
  teamNumber: number,
  practicing: boolean,
): PitForm | null | "blocked" {
  const team = teams.find((t) => t.number === teamNumber);
  if (!team) return null;
  if (!practicing && team.pitStatus !== "none") return "blocked";
  return { team, report: null, photoUrl: null };
}

/**
 * notes.matchNote. notes.saveMatchReport replaces the scout's earlier report
 * on the same robot, so a robot already in "my notes" is "blocked" unless the
 * earlier report is on this device.
 */
export function deriveNoteMatchForm(input: {
  matches: Matches;
  teams: NoteTeams | undefined;
  myNotes: MyNotes | undefined;
  practicing: boolean;
  matchNumber: number;
  teamNumber: number;
}): NoteMatchForm | null | "blocked" {
  const match = input.matches.find((m) => m.matchNumber === input.matchNumber);
  if (!match) return null;
  const alliance = match.redTeamNumbers.includes(input.teamNumber)
    ? ("red" as const)
    : match.blueTeamNumbers.includes(input.teamNumber)
      ? ("blue" as const)
      : null;
  if (alliance === null) return null;
  const team = input.teams?.find((t) => t.number === input.teamNumber);
  if (input.teams !== undefined && !team) return null;
  const already = input.myNotes?.some(
    (n) => n.matchNumber === input.matchNumber && n.teamNumber === input.teamNumber,
  );
  if (!input.practicing && already) return "blocked";
  return {
    matchNumber: match.matchNumber,
    teamNumber: input.teamNumber,
    nickname: team?.nickname ?? "",
    alliance,
    notes: null,
    report: null,
  };
}

/** notes.pitNote, for a team with no pit report. Same guard as derivePitForm. */
export function deriveNotePitForm(
  teams: NoteTeams,
  teamNumber: number,
  practicing: boolean,
): NotePitForm | null | "blocked" {
  const team = teams.find((t) => t.number === teamNumber);
  if (!team) return null;
  if (!practicing && team.pitStatus !== "none") return "blocked";
  return { teamNumber: team.number, nickname: team.nickname, photoUrl: null, note: null };
}
