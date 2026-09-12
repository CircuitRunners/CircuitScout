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
import type * as lib_consensus from "../lib/consensus.js";
import type * as lib_guards from "../lib/guards.js";
import type * as lib_scoring from "../lib/scoring.js";
import type * as lib_summarise from "../lib/summarise.js";
import type * as lib_types from "../lib/types.js";
import type * as matchReports from "../matchReports.js";
import type * as matches from "../matches.js";
import type * as merge from "../merge.js";
import type * as pickLists from "../pickLists.js";
import type * as picked from "../picked.js";
import type * as pit from "../pit.js";
import type * as profiles from "../profiles.js";
import type * as refresh from "../refresh.js";
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
  "lib/consensus": typeof lib_consensus;
  "lib/guards": typeof lib_guards;
  "lib/scoring": typeof lib_scoring;
  "lib/summarise": typeof lib_summarise;
  "lib/types": typeof lib_types;
  matchReports: typeof matchReports;
  matches: typeof matches;
  merge: typeof merge;
  pickLists: typeof pickLists;
  picked: typeof picked;
  pit: typeof pit;
  profiles: typeof profiles;
  refresh: typeof refresh;
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
