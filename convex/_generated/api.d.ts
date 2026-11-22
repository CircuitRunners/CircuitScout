/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as account from "../account.js";
import type * as admin from "../admin.js";
import type * as archive from "../archive.js";
import type * as assignments from "../assignments.js";
import type * as attention from "../attention.js";
import type * as auth from "../auth.js";
import type * as crons from "../crons.js";
import type * as entries from "../entries.js";
import type * as events from "../events.js";
import type * as exports from "../exports.js";
import type * as http from "../http.js";
import type * as hub from "../hub.js";
import type * as lib_archiveData from "../lib/archiveData.js";
import type * as lib_archiveSnapshot from "../lib/archiveSnapshot.js";
import type * as lib_consensus from "../lib/consensus.js";
import type * as lib_coverage from "../lib/coverage.js";
import type * as lib_genericMatch from "../lib/genericMatch.js";
import type * as lib_genericPit from "../lib/genericPit.js";
import type * as lib_guards from "../lib/guards.js";
import type * as lib_pitStatus from "../lib/pitStatus.js";
import type * as lib_practice from "../lib/practice.js";
import type * as lib_reportCounts from "../lib/reportCounts.js";
import type * as lib_scoring from "../lib/scoring.js";
import type * as lib_spares from "../lib/spares.js";
import type * as lib_summarise from "../lib/summarise.js";
import type * as lib_teamSummaries from "../lib/teamSummaries.js";
import type * as lib_types from "../lib/types.js";
import type * as mailer from "../mailer.js";
import type * as match13 from "../match13.js";
import type * as matchReports from "../matchReports.js";
import type * as matches from "../matches.js";
import type * as merge from "../merge.js";
import type * as notes from "../notes.js";
import type * as passwordResetEmail from "../passwordResetEmail.js";
import type * as pickLists from "../pickLists.js";
import type * as picked from "../picked.js";
import type * as pit from "../pit.js";
import type * as practice from "../practice.js";
import type * as predictions from "../predictions.js";
import type * as profiles from "../profiles.js";
import type * as ranks from "../ranks.js";
import type * as refresh from "../refresh.js";
import type * as statSite from "../statSite.js";
import type * as statbotics from "../statbotics.js";
import type * as stats from "../stats.js";
import type * as tba from "../tba.js";
import type * as teams from "../teams.js";
import type * as workbook from "../workbook.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  account: typeof account;
  admin: typeof admin;
  archive: typeof archive;
  assignments: typeof assignments;
  attention: typeof attention;
  auth: typeof auth;
  crons: typeof crons;
  entries: typeof entries;
  events: typeof events;
  exports: typeof exports;
  http: typeof http;
  hub: typeof hub;
  "lib/archiveData": typeof lib_archiveData;
  "lib/archiveSnapshot": typeof lib_archiveSnapshot;
  "lib/consensus": typeof lib_consensus;
  "lib/coverage": typeof lib_coverage;
  "lib/genericMatch": typeof lib_genericMatch;
  "lib/genericPit": typeof lib_genericPit;
  "lib/guards": typeof lib_guards;
  "lib/pitStatus": typeof lib_pitStatus;
  "lib/practice": typeof lib_practice;
  "lib/reportCounts": typeof lib_reportCounts;
  "lib/scoring": typeof lib_scoring;
  "lib/spares": typeof lib_spares;
  "lib/summarise": typeof lib_summarise;
  "lib/teamSummaries": typeof lib_teamSummaries;
  "lib/types": typeof lib_types;
  mailer: typeof mailer;
  match13: typeof match13;
  matchReports: typeof matchReports;
  matches: typeof matches;
  merge: typeof merge;
  notes: typeof notes;
  passwordResetEmail: typeof passwordResetEmail;
  pickLists: typeof pickLists;
  picked: typeof picked;
  pit: typeof pit;
  practice: typeof practice;
  predictions: typeof predictions;
  profiles: typeof profiles;
  ranks: typeof ranks;
  refresh: typeof refresh;
  statSite: typeof statSite;
  statbotics: typeof statbotics;
  stats: typeof stats;
  tba: typeof tba;
  teams: typeof teams;
  workbook: typeof workbook;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {};
