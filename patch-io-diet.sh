#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-io-diet.sh — stop the hot queries reading every match report.
#
# One competition day spent the free plan's 1 GB of database I/O. The top five
# functions all collected every report at the event, and because they are
# live subscriptions, every submission re-ran them on every open phone. Cost
# grew with reports x devices x reports-so-far.
#
#   assignments.mine     walks down the schedule to find the current match
#                        instead of reading every report; my-reports scoped
#                        to the event; one team row instead of the roster
#   attention.forEvent   reads only flagged reports, off two new indexes;
#                        no more whole-table profiles / flagDismissals scans
#   admin.reports        profiles cached per scout; dismissals fetched only
#                        for reports that actually carry a flag
#   teams.listWithStatus pit reports filtered by index, not in JavaScript
#   events.list          teamSettings read once, not once per event; pick
#                        list entries checked for existence, not collected
#
# Schema: new INDEXES only, on fields that already exist. Convex backfills them
# on push. No data migration. Report counts in teams.listWithStatus and
# events.list still read every report — patch-io-counters.sh fixes those.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/attention.ts ]] || { echo "ERROR: run patch-attention-teams.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# Shared by every step: replace an anchor that must appear exactly once, or a
# span from one anchor up to (not including) the next. A missing anchor stops
# the script rather than half-applying an edit to code that has moved on.
cat > /tmp/io-lib.mjs <<'MJS'
export function swap(s, from, to, label) {
  const i = s.indexOf(from);
  if (i < 0 || s.indexOf(from, i + 1) >= 0) {
    console.error(`ERROR: anchor ${i < 0 ? "missing" : "not unique"}: ${label}`);
    process.exit(1);
  }
  return s.slice(0, i) + to + s.slice(i + from.length);
}
export function span(s, start, end, to, label, after = 0) {
  const i = s.indexOf(start, after);
  const j = i < 0 ? -1 : s.indexOf(end, i + start.length);
  if (i < 0 || j < 0) {
    console.error(`ERROR: span anchor missing: ${label}`);
    process.exit(1);
  }
  return s.slice(0, i) + to + s.slice(j);
}
MJS

say "Schema: indexes for scoped reads"
cat > /tmp/io1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./io-lib.mjs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
if (s.includes("by_event_broke")) { console.log("schema already patched"); process.exit(0); }

s = swap(s,
`    .index("by_match", ["matchId"])
    .index("by_scout", ["scoutId"]),`,
`    .index("by_match", ["matchId"])
    .index("by_scout", ["scoutId"])
    // One scout's reports at one event. by_scout alone spans every event
    // the scout has ever worked.
    .index("by_scout_event", ["scoutId", "eventId"])
    // Attention items read only flagged reports, not the whole event.
    .index("by_event_broke", ["eventId", "ratings.broke"])
    .index("by_event_inconsistent", ["eventId", "ratings.inconsistent"]),`,
"matchReports indexes");

s = swap(s,
`    photoId: v.union(v.id("_storage"), v.null()),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"]),`,
`    photoId: v.union(v.id("_storage"), v.null()),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"])
    // Each scouting team's own pit reports.
    .index("by_event_scouting_team", ["eventId", "scoutingTeamNumber"]),`,
"pitReports index");

writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/io1.mjs

say "assignments.mine: find the current match without reading every report"
cat > /tmp/io2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap, span } from "./io-lib.mjs";
const p = "convex/assignments.ts";
let s = readFileSync(p, "utf8");
if (s.includes("newestFirst")) { console.log("assignments already patched"); process.exit(0); }

const mine = s.indexOf("export const mine = query({");
if (mine < 0) { console.error("ERROR: assignments.mine not found"); process.exit(1); }

s = span(s,
`    const teams = await ctx.db
      .query("teams")`,
`    const shifts = rows`,
`    // Match numbers this scout has reported here. Scoped to the event by the
    // index; by_scout alone pulled in every event the scout ever worked.
    const matchById = new Map(matches.map((m) => [m._id, m]));
    const myReports = await ctx.db
      .query("matchReports")
      .withIndex("by_scout_event", (q) =>
        q.eq("scoutId", userId).eq("eventId", event._id))
      .collect();
    const reportedMatchNumbers = new Set(
      myReports.flatMap((r) => {
        const match = matchById.get(r.matchId);
        return match ? [match.matchNumber] : [];
      }),
    );

    // "Current" is the furthest match anyone has reported. Pooled across
    // scouts — scout 1 finishing qual 12 moves everyone on to 13 — and your
    // own submission always advances your own card. TBA results deliberately
    // do not count: a refresh landing mid-shift would jump the card past
    // matches still waiting to be scouted. Distance stays in matches rather
    // than minutes, because scheduled times drift during an event.
    //
    // Walk down from the last match and stop at the first one with a report.
    // An unplayed match costs an empty index read. This used to collect every
    // report at the event, so each submission re-read all of them on every
    // phone with the dashboard open — the single largest I/O cost.
    let current = 0;
    const newestFirst = [...matches].sort((a, b) => b.matchNumber - a.matchNumber);
    for (const match of newestFirst) {
      const hit = await ctx.db
        .query("matchReports")
        .withIndex("by_match", (q) => q.eq("matchId", match._id))
        .first();
      if (hit) {
        current = match.matchNumber;
        break;
      }
    }

`,
"mine: reports block", mine);

s = swap(s,
`    const upNext: {
      matchNumber: number;`,
`    // One team row for the card, rather than the whole roster.
    const nextTeamNumber = next?.teamNumber ?? null;
    const nextNickname = nextTeamNumber === null
      ? null
      : ((await ctx.db
          .query("teams")
          .withIndex("by_event_number", (q) =>
            q.eq("eventId", event._id).eq("number", nextTeamNumber))
          .first())?.nickname ?? null);

    const upNext: {
      matchNumber: number;`,
"mine: upNext declaration");

s = swap(s,
`          nickname: next.teamNumber
            ? (teamByNumber.get(next.teamNumber)?.nickname ?? null)
            : null,`,
`          nickname: nextNickname,`,
"mine: nickname");

writeFileSync(p, s);
console.log("convex/assignments.ts patched");
MJS
bun /tmp/io2.mjs

say "attention.forEvent: flagged reports only"
cat > /tmp/io3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap, span } from "./io-lib.mjs";
const p = "convex/attention.ts";
let s = readFileSync(p, "utf8");
if (s.includes("by_event_broke")) { console.log("attention already patched"); process.exit(0); }

s = swap(s,
`import type { Doc } from "./_generated/dataModel";`,
`import type { Doc, Id } from "./_generated/dataModel";`,
"attention: imports");

s = span(s,
`export const forEvent = query({`,
`export const settle = mutation({`,
`export const forEvent = query({
  args: {},
  handler: async (ctx) => {
    await requireUser(ctx);
    const event = await activeEvent(ctx);
    if (!event) return [];

    // Only reports that carry a flag, straight off the index. Reading every
    // report to find the few with one re-ran on each submission, on every
    // phone with the teams tab open.
    const [broke, inconsistent] = await Promise.all([
      ctx.db
        .query("matchReports")
        .withIndex("by_event_broke", (q) =>
          q.eq("eventId", event._id).eq("ratings.broke", true))
        .collect(),
      ctx.db
        .query("matchReports")
        .withIndex("by_event_inconsistent", (q) =>
          q.eq("eventId", event._id).eq("ratings.inconsistent", true))
        .collect(),
    ]);
    // A report flagged both ways comes back from both indexes.
    const reports = new Map<Id<"matchReports">, Doc<"matchReports">>();
    for (const r of [...broke, ...inconsistent]) reports.set(r._id, r);

    // A handful of scouts, looked up once each, rather than the whole
    // profiles table.
    const names = new Map<Id<"users">, string>();
    const scoutName = async (userId: Id<"users">): Promise<string> => {
      const known = names.get(userId);
      if (known !== undefined) return known;
      const profile = await ctx.db
        .query("profiles")
        .withIndex("by_user", (q) => q.eq("userId", userId))
        .first();
      const name = profile?.displayName ?? "Unknown scout";
      names.set(userId, name);
      return name;
    };

    const rows = [];
    for (const report of reports.values()) {
      const team = await ctx.db.get(report.teamId);
      if (!team) continue;
      const match = await ctx.db.get(report.matchId);
      const dismissals = await ctx.db
        .query("flagDismissals")
        .withIndex("by_report", (q) => q.eq("reportId", report._id))
        .collect();

      for (const kind of ["broke", "inconsistent"] as const) {
        if (!report.ratings[kind]) continue;
        // A decision made before the report changed is stale.
        const settled = dismissals.some(
          (d) => d.reason === kind && d.dismissedAt >= report.updatedAt,
        );
        if (settled) continue;

        rows.push({
          reportId: report._id,
          kind,
          teamId: report.teamId,
          teamNumber: team.number,
          nickname: team.nickname,
          matchNumber: match?.matchNumber ?? 0,
          scoutName: await scoutName(report.scoutId),
          detail: kind === "broke"
            ? report.ratings.brokeNotes
            : report.ratings.inconsistentNotes,
          submittedAt: report.submittedAt,
        });
      }
    }
    return rows.sort((a, b) => b.submittedAt - a.submittedAt);
  },
});

`,
"attention: forEvent");

writeFileSync(p, s);
console.log("convex/attention.ts patched");
MJS
bun /tmp/io3.mjs

say "admin.reports: cached profiles, dismissals only where flagged"
cat > /tmp/io4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./io-lib.mjs";
const p = "convex/admin.ts";
let s = readFileSync(p, "utf8");
if (s.includes("profileFor")) { console.log("admin already patched"); process.exit(0); }

s = swap(s,
`} from "./lib/scoring";
export type FlagReason =`,
`} from "./lib/scoring";
import type { Doc, Id } from "./_generated/dataModel";
export type FlagReason =`,
"admin: imports");

s = swap(s,
`    const profiles = await ctx.db.query("profiles").collect();
    const nameByUser = new Map(profiles.map((p) => [p.userId, p.displayName]));
    const profileByUser = new Map(profiles.map((p) => [p.userId, p]));

    const allDismissals = await ctx.db.query("flagDismissals").collect();
    const dismissalsByReport = new Map<string, typeof allDismissals>();
    for (const d of allDismissals) {
      const list = dismissalsByReport.get(d.reportId) ?? [];
      list.push(d);
      dismissalsByReport.set(d.reportId, list);
    }
`,
`    // Scouts and dismissers, looked up once each. A few dozen people, against
    // a profiles table that only grows.
    const profiles = new Map<Id<"users">, Doc<"profiles"> | null>();
    const profileFor = async (userId: Id<"users">) => {
      if (!profiles.has(userId)) {
        profiles.set(userId, await ctx.db
          .query("profiles")
          .withIndex("by_user", (q) => q.eq("userId", userId))
          .first());
      }
      return profiles.get(userId) ?? null;
    };
`,
"admin.reports: profiles and dismissals");

s = swap(s,
`      if (!managesTeam(me, profileByUser.get(report.scoutId)?.teamNumber)) continue;`,
`      const scout = await profileFor(report.scoutId);
      if (!managesTeam(me, scout?.teamNumber)) continue;`,
"admin.reports: managesTeam");

s = swap(s,
`      const dismissalsFor = dismissalsByReport.get(report._id) ?? [];`,
`      // Only a flagged report can have a dismissal worth reading, and the
      // flagDismissals table spans every event.
      const dismissalsFor = reasons.length === 0
        ? []
        : await ctx.db
            .query("flagDismissals")
            .withIndex("by_report", (q) => q.eq("reportId", report._id))
            .collect();`,
"admin.reports: dismissalsFor");

s = swap(s,
`      const dismissed = reasons
        .filter((r) => live.has(r))
        .map((r) => {
          const d = live.get(r);
          return {
            reason: r,
            label: REASON_LABELS[r],
            note: d?.note ?? "",
            byName: d ? (nameByUser.get(d.dismissedBy) ?? "Unknown") : "Unknown",
            at: d?.dismissedAt ?? 0,
          };
        });`,
`      const dismissed: Row["dismissed"] = [];
      for (const r of reasons) {
        const d = live.get(r);
        if (!d) continue;
        dismissed.push({
          reason: r,
          label: REASON_LABELS[r],
          note: d.note,
          byName: (await profileFor(d.dismissedBy))?.displayName ?? "Unknown",
          at: d.dismissedAt,
        });
      }`,
"admin.reports: dismissed");

s = swap(s,
`        scoutName: nameByUser.get(report.scoutId) ?? "Unknown scout",
        alliance,`,
`        scoutName: scout?.displayName ?? "Unknown scout",
        alliance,`,
"admin.reports: scoutName");

writeFileSync(p, s);
console.log("convex/admin.ts patched");
MJS
bun /tmp/io4.mjs

say "teams.listWithStatus: pit reports by index"
cat > /tmp/io5.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./io-lib.mjs";
const p = "convex/teams.ts";
let s = readFileSync(p, "utf8");
if (s.includes("by_event_scouting_team")) { console.log("teams already patched"); process.exit(0); }

s = swap(s,
`    const myTeam = await currentTeamNumber(ctx);
    const pit = (
      await ctx.db
        .query("pitReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect()
    ).filter((p) => p.scoutingTeamNumber === myTeam);
    const scouted = new Set(pit.map((p) => p.teamId));`,
`    // activeEvent returned an event, so the caller has a team number.
    const myTeam = await currentTeamNumber(ctx);
    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event_scouting_team", (q) =>
        q.eq("eventId", event._id).eq("scoutingTeamNumber", myTeam))
      .collect();
    const scouted = new Set(pit.map((p) => p.teamId));`,
"teams.listWithStatus: pit");

writeFileSync(p, s);
console.log("convex/teams.ts patched");
MJS
bun /tmp/io5.mjs

say "events.list: one teamSettings read, existence checks for entries"
cat > /tmp/io6.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
import { swap } from "./io-lib.mjs";
const p = "convex/events.ts";
let s = readFileSync(p, "utf8");
if (s.includes("allSettings")) { console.log("events already patched"); process.exit(0); }

s = swap(s,
`    const events = await ctx.db.query("events").collect();
    const withCounts = [];`,
`    const events = await ctx.db.query("events").collect();
    // Read once. This used to be re-read inside the loop, once per event.
    const allSettings = await ctx.db.query("teamSettings").collect();
    const withCounts = [];`,
"events.list: settings hoist");

s = swap(s,
`      let entryCount = 0;
      for (const list of lists) {
        const entries = await ctx.db
          .query("pickListEntries")
          .withIndex("by_list", (q) => q.eq("pickListId", list._id))
          .collect();
        entryCount += entries.length;
      }

      const settings = (await ctx.db.query("teamSettings").collect())
        .filter((t) => t.activeEventId === event._id)`,
`      // Only "is there any" matters here, so stop at the first entry found.
      let hasEntries = false;
      for (const list of lists) {
        const entry = await ctx.db
          .query("pickListEntries")
          .withIndex("by_list", (q) => q.eq("pickListId", list._id))
          .first();
        if (entry) { hasEntries = true; break; }
      }

      const settings = allSettings
        .filter((t) => t.activeEventId === event._id)`,
"events.list: entries");

s = swap(s,
`        entryCount,
`,
``,
"events.list: entryCount field");

s = swap(s,
`        removable: reports.length === 0 && pit.length === 0 && entryCount === 0,`,
`        removable: reports.length === 0 && pit.length === 0 && !hasEntries,`,
"events.list: removable");

writeFileSync(p, s);
console.log("convex/events.ts patched");
MJS
bun /tmp/io6.mjs
rm -f /tmp/io-lib.mjs /tmp/io1.mjs /tmp/io2.mjs /tmp/io3.mjs /tmp/io4.mjs /tmp/io5.mjs /tmp/io6.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
