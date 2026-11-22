import { v } from "convex/values";
import { query } from "./_generated/server";
import { currentTeamNumber, requireUser } from "./lib/guards";
import {
  liveCounts, liveTable, seasonOf, snapshotFor, type ArchiveRow,
} from "./lib/archiveData";

/**
 * Read-only by construction. Every function here takes an explicit event key
 * and none of them can write, so nothing in this file can put scouting data
 * into the wrong competition.
 *
 * Deleted events stay listed. Their numbers come from the snapshot saved
 * right before deletion (or, inside the 24-hour recovery window for an event
 * deleted before snapshots existed, from the data still present). An event
 * that is not deleted always shows live data, so a recovered event updates
 * again.
 */

export const events = query({
  args: {},
  handler: async (ctx) => {
    await requireUser(ctx);
    const myTeam = await currentTeamNumber(ctx);

    const [all, settings, snapshots] = await Promise.all([
      ctx.db.query("events").collect(),
      ctx.db.query("teamSettings").collect(),
      ctx.db.query("archiveSnapshots").collect(),
    ]);
    const snapshotByKey = new Map(snapshots.map((s) => [s.eventKey, s]));

    const rows = [];
    const listed = new Set<string>();
    for (const event of all) {
      const key = event.tbaEventKey;
      const snapshot = event.deletedAt ? snapshotByKey.get(key) : undefined;
      const counts = snapshot ?? await liveCounts(ctx, event._id);

      const activeForTeams = event.deletedAt
        ? []
        : settings.filter((t) => t.activeEventId === event._id).map((t) => t.teamNumber);

      listed.add(key);
      rows.push({
        eventKey: key,
        name: event.name,
        season: seasonOf(key),
        teamCount: counts.teamCount,
        matchCount: counts.matchCount,
        reportCount: counts.reportCount,
        activeForTeams,
        isMine: myTeam !== undefined && activeForTeams.includes(myTeam),
        deleted: Boolean(event.deletedAt),
        snapshotAt: snapshot?.takenAt ?? null,
      });
    }

    // Purged for good: only the snapshot is left.
    for (const snapshot of snapshots) {
      if (listed.has(snapshot.eventKey)) continue;
      rows.push({
        eventKey: snapshot.eventKey,
        name: snapshot.name,
        season: snapshot.season,
        teamCount: snapshot.teamCount,
        matchCount: snapshot.matchCount,
        reportCount: snapshot.reportCount,
        activeForTeams: [] as number[],
        isMine: false,
        deleted: true,
        snapshotAt: snapshot.takenAt as number | null,
      });
    }

    return rows.sort((a, b) =>
      b.season - a.season || a.name.localeCompare(b.name));
  },
});

export const teamTable = query({
  args: { eventKey: v.string() },
  handler: async (ctx, args) => {
    await requireUser(ctx);

    const event = await ctx.db
      .query("events")
      .withIndex("by_key", (q) => q.eq("tbaEventKey", args.eventKey))
      .unique();

    if (event && !event.deletedAt) {
      const table = await liveTable(ctx, event);
      return {
        eventKey: event.tbaEventKey,
        name: event.name,
        matchCount: table.matchCount,
        rows: table.rows,
        deleted: false,
        snapshotAt: null as number | null,
      };
    }

    const snapshot = await snapshotFor(ctx, args.eventKey);
    if (snapshot) {
      return {
        eventKey: snapshot.eventKey,
        name: snapshot.name,
        matchCount: snapshot.matchCount,
        rows: JSON.parse(snapshot.rows) as ArchiveRow[],
        deleted: true,
        snapshotAt: snapshot.takenAt as number | null,
      };
    }

    // Deleted before snapshots existed and not yet purged: the data is still here.
    if (event) {
      const table = await liveTable(ctx, event);
      return {
        eventKey: event.tbaEventKey,
        name: event.name,
        matchCount: table.matchCount,
        rows: table.rows,
        deleted: true,
        snapshotAt: null as number | null,
      };
    }
    return null;
  },
});
