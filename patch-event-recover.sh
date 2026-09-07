#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-event-recover.sh — 24-hour recovery window on event deletion.
#
# Deleting marks the event rather than destroying it. Nothing else is touched:
# every table is scoped by eventId, so hiding the event hides its data, and
# recovery is one flag away. A cron purges anything past the window.
#
# SCHEMA CHANGE: events.deletedAt / deletedBy (optional).
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/events.ts ]] || { echo "ERROR: run patch-event-purge.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Schema"
cat > /tmp/r1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/schema.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
// deletionLog already has a deletedAt field, so check for something unique
// to the events table instead.
if (s.includes("deletedBy: v.optional(")) { console.log("already patched"); process.exit(0); }
const anchor = `    importedBy: v.union(v.id("users"), v.null()),`;
if (!s.includes(anchor)) fail("could not find events.importedBy");
s = s.replace(anchor, `${anchor}
    /** Set when deleted. The event and its data survive until a cron purges
     *  them, so a mistake is recoverable for 24 hours. */
    deletedAt: v.optional(v.union(v.number(), v.null())),
    deletedBy: v.optional(v.union(v.id("users"), v.null())),`);
writeFileSync(p, s);
console.log("convex/schema.ts patched");
MJS
bun /tmp/r1.mjs

say "Guards: a deleted event is not active"
cat > /tmp/r2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/lib/guards.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("deletedAt")) { console.log("already patched"); process.exit(0); }
const anchor = `  if (!settings || settings.activeEventId === null) return null;
  return await ctx.db.get(settings.activeEventId);`;
if (!s.includes(anchor)) fail("could not find activeEventForTeam");
s = s.replace(anchor, `  if (!settings || settings.activeEventId === null) return null;
  const event = await ctx.db.get(settings.activeEventId);
  // A deleted event reads as no event. The pointer is left alone so recovery
  // puts the team straight back where they were.
  if (!event || event.deletedAt) return null;
  return event;`);
writeFileSync(p, s);
console.log("convex/lib/guards.ts patched");
MJS
bun /tmp/r2.mjs

say "Events: soft delete, recover, scheduled purge"
cat > /tmp/r3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/events.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("RECOVERY_WINDOW_MS")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { internalMutation, mutation, query } from "./_generated/server";',
              'import { internalMutation, mutation, query } from "./_generated/server";');
if (!s.includes("internalMutation")) {
  s = s.replace('import { mutation, query } from "./_generated/server";',
                'import { internalMutation, mutation, query } from "./_generated/server";');
}

// list carries the deletion state
s = s.replace("      withCounts.push({\n        ...event,",
              "      withCounts.push({\n        ...event,\n        deletedAt: event.deletedAt ?? null,");

// turn the existing hard purge into a reusable helper
const purgeStart = s.indexOf("export const purge = mutation({");
if (purgeStart === -1) fail("could not find events.purge");
const body = s.slice(purgeStart);
const inner = body.slice(body.indexOf("const counts = {"), body.lastIndexOf("await ctx.db.delete(args.eventId);"));

s = s.slice(0, purgeStart) + `export const RECOVERY_WINDOW_MS = 24 * 60 * 60 * 1000;

/** Shared by the immediate purge and the scheduled one. */
async function purgeEventData(ctx: MutationCtx, eventId: Id<"events">) {
  const args = { eventId };
  ${inner.replace(/args\.eventId/g, "args.eventId")}
  await ctx.db.delete(args.eventId);
  return counts;
}

/**
 * Marks the event deleted. Nothing is destroyed yet — every table is scoped by
 * eventId, so hiding the event hides its data, and the teamSettings pointer is
 * deliberately left alone so recovery restores the team's event too.
 */
export const softDelete = mutation({
  args: { eventId: v.id("events"), confirmKey: v.string() },
  handler: async (ctx, args) => {
    const me = await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) throw new Error("That event no longer exists.");
    if (args.confirmKey.trim() !== event.tbaEventKey) {
      throw new Error("The event key does not match.");
    }
    await ctx.db.patch(args.eventId, {
      deletedAt: Date.now(),
      deletedBy: me.userId,
    });
  },
});

export const recover = mutation({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) throw new Error("That event is gone for good.");
    await ctx.db.patch(args.eventId, { deletedAt: null, deletedBy: null });
    return { name: event.name };
  },
});

/** Runs hourly. Anything past the window goes for real. */
export const purgeExpired = internalMutation({
  args: {},
  handler: async (ctx) => {
    const cutoff = Date.now() - RECOVERY_WINDOW_MS;
    const events = await ctx.db.query("events").collect();
    let purged = 0;
    for (const event of events) {
      if (!event.deletedAt || event.deletedAt > cutoff) continue;
      await purgeEventData(ctx, event._id);
      purged += 1;
    }
    return { purged };
  },
});

/** Skips the wait. Same confirmation, no recovery. */
export const purgeNow = mutation({
  args: { eventId: v.id("events"), confirmKey: v.string() },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) throw new Error("That event no longer exists.");
    if (args.confirmKey.trim() !== event.tbaEventKey) {
      throw new Error("The event key does not match.");
    }
    return await purgeEventData(ctx, args.eventId);
  },
});
`;

if (!s.includes('import type { MutationCtx }')) {
  s = s.replace('import type { Id } from "./_generated/dataModel";',
    'import type { Id } from "./_generated/dataModel";\nimport type { MutationCtx } from "./_generated/server";');
}
if (!s.includes('import type { Id }')) {
  s = s.replace('import { v } from "convex/values";',
    'import { v } from "convex/values";\nimport type { Id } from "./_generated/dataModel";\nimport type { MutationCtx } from "./_generated/server";');
}

writeFileSync(p, s);
console.log("convex/events.ts patched");
MJS
bun /tmp/r3.mjs

say "Cron"
cat > convex/crons.ts <<'EOF'
import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

// Hourly rather than daily: an event deleted at 23:59 should not linger for
// most of a second day before the window is honoured.
crons.interval(
  "purge deleted events",
  { hours: 1 },
  internal.events.purgeExpired,
  {},
);

export default crons;
EOF
echo "convex/crons.ts written"

say "Admin UI: deleted events at the bottom"
cat > /tmp/r4.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/index.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("recoverEvent")) { console.log("already patched"); process.exit(0); }

s = s.replace(/import \{ ([^}]*) \} from "lucide-react";/,
              'import { $1, RotateCcw } from "lucide-react";');
s = s.replace("  const purgeEvent = useMutation(api.events.purge);",
`  const softDelete = useMutation(api.events.softDelete);
  const recoverEvent = useMutation(api.events.recover);`);

// the delete button now soft-deletes
s = s.replace(`                    void purgeEvent({ eventId: event._id, confirmKey: purgeKey })
                      .then((c) => {
                        toast.success(\`\${event.name} deleted\`, {
                          description:
                            \`\${c.matchReports} match reports, \${c.pitReports} pit reports, \` +
                            \`\${c.lists} pick lists, \${c.matches} matches, \${c.teams} teams.\`,
                        });`,
`                    void softDelete({ eventId: event._id, confirmKey: purgeKey })
                      .then(() => {
                        toast.success(\`\${event.name} deleted\`, {
                          description: "Recoverable for 24 hours.",
                        });`);

// split live from deleted
const listAnchor = `            events.map((event) => (`;
if (!s.includes(listAnchor)) fail("could not find the events map");
s = s.replace(listAnchor, `            events.filter((e) => !e.deletedAt).map((event) => (`);

// deleted section, appended inside the same CardContent
const closeAnchor = `            ))
          )}
        </CardContent>
      </Card>`;
if (!s.includes(closeAnchor)) fail("could not find the events card close");
s = s.replace(closeAnchor, `            ))
          )}

          {(events ?? []).some((e) => e.deletedAt) ? (
            <div className="space-y-2 pt-2">
              <p className="text-muted-foreground text-xs">
                Deleted — recoverable for 24 hours, then purged for good.
              </p>
              {(events ?? [])
                .filter((e) => e.deletedAt)
                .map((event) => {
                  const hoursLeft = Math.max(
                    0,
                    Math.ceil((event.deletedAt! + 24 * 60 * 60 * 1000 - Date.now()) / 3600000),
                  );
                  return (
                    <div key={event._id}
                      className="flex flex-wrap items-center gap-3 rounded-lg border p-3 opacity-60">
                      <div className="min-w-0 flex-1">
                        <span className="truncate font-medium line-through">
                          {event.name}
                        </span>
                        <p className="text-muted-foreground text-xs">
                          {event.tbaEventKey} · {event.teamCount} teams ·{" "}
                          {event.reportCount} match reports · purged in{" "}
                          {hoursLeft}h
                        </p>
                      </div>
                      {isFullAdmin ? (
                        <Button variant="secondary" size="sm"
                          onClick={() => {
                            void recoverEvent({ eventId: event._id })
                              .then((r) => toast.success(\`\${r.name} recovered\`))
                              .catch((error: unknown) =>
                                toast.error("Could not recover", {
                                  description:
                                    error instanceof Error ? error.message : String(error),
                                }));
                          }}>
                          <RotateCcw className="size-3" /> Recover
                        </Button>
                      ) : null}
                    </div>
                  );
                })}
            </div>
          ) : null}
        </CardContent>
      </Card>`);

// the confirmation wording changes: this is now reversible
s = s.replace(`        This permanently deletes {preview.name} and everything attached to it.`,
              `        Deleting {preview.name} hides it and everything attached to it.`);
s = s.replace(`          Export from Coverage and Quality first if you want to keep any of it —
          there is no undo and no snapshot.`,
`          Recoverable for 24 hours from the bottom of this list, then purged
          for good. Export from Coverage and Quality if you want a copy that
          outlives that.`);

writeFileSync(p, s);
console.log("src/routes/admin/index.tsx patched");
MJS
bun /tmp/r4.mjs
rm -f /tmp/r1.mjs /tmp/r2.mjs /tmp/r3.mjs /tmp/r4.mjs

say "Archive: hide deleted events"
cat > /tmp/r5.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/archive.ts";
let s = readFileSync(p, "utf8");
if (!s.includes("deletedAt")) {
  s = s.replace("    for (const event of all) {", "    for (const event of all) {\n      if (event.deletedAt) continue;");
  writeFileSync(p, s);
  console.log("convex/archive.ts patched");
} else { console.log("archive already patched"); }
MJS
bun /tmp/r5.mjs 2>/dev/null || echo "  (no archive.ts — skipped)"
rm -f /tmp/r5.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
