#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-event-admin.sh
#   1. Admins can set the active event inactive without losing anything.
#   2. Admins can remove imported events that hold no scouting data.
#
# An event is removable only when it has no match reports, no pit reports and
# no pick list entries. Teams and the schedule are re-downloadable from TBA;
# a scout's afternoon is not.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/events.ts ]] || { echo "ERROR: run track-a.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Convex: event counts, deactivate, remove"
cat > /tmp/ev.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/events.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("setInactive")) { console.log("already patched"); process.exit(0); }

// list gains the counts that decide whether an event is removable
const oldList = `      withCounts.push({ ...event, teamCount: teams.length, matchCount: matches.length });`;
if (!s.includes(oldList)) fail("could not find events.list");
s = s.replace(oldList, `      const reports = await ctx.db
        .query("matchReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const pit = await ctx.db
        .query("pitReports")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      const lists = await ctx.db
        .query("pickLists")
        .withIndex("by_event", (q) => q.eq("eventId", event._id))
        .collect();
      let entryCount = 0;
      for (const list of lists) {
        const entries = await ctx.db
          .query("pickListEntries")
          .withIndex("by_list", (q) => q.eq("pickListId", list._id))
          .collect();
        entryCount += entries.length;
      }

      withCounts.push({
        ...event,
        teamCount: teams.length,
        matchCount: matches.length,
        reportCount: reports.length,
        pitCount: pit.length,
        entryCount,
        // Teams and the schedule come back from TBA in one click. Scouting
        // data does not, so anything holding it is not removable.
        removable: reports.length === 0 && pit.length === 0 && entryCount === 0,
      });`);

s += `
/**
 * Stands the event down without touching a row. Everything is preserved and
 * setActive brings it straight back — this is for "we are done for today",
 * not for cleanup.
 */
export const setInactive = mutation({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) throw new Error("That event no longer exists.");
    await ctx.db.patch(args.eventId, { isActive: false });
  },
});

/**
 * Removes an imported event and the TBA data that came with it. Refuses while
 * any scouting data exists, rather than offering a force flag — a destructive
 * override on a shared tool at a competition is a trap.
 */
export const remove = mutation({
  args: { eventId: v.id("events") },
  handler: async (ctx, args) => {
    await requireAdmin(ctx);
    const event = await ctx.db.get(args.eventId);
    if (!event) throw new Error("That event no longer exists.");

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    const pit = await ctx.db
      .query("pitReports")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    if (reports.length > 0 || pit.length > 0) {
      throw new Error(
        \`\${event.name} holds \${reports.length} match and \${pit.length} pit reports. Nothing with scouting data can be removed.\`,
      );
    }

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const list of lists) {
      const entries = await ctx.db
        .query("pickListEntries")
        .withIndex("by_list", (q) => q.eq("pickListId", list._id))
        .collect();
      if (entries.length > 0) {
        throw new Error("A pick list for that event has teams on it.");
      }
    }

    const matches = await ctx.db
      .query("matches")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const match of matches) {
      const claims = await ctx.db
        .query("matchClaims")
        .withIndex("by_match_team", (q) => q.eq("matchId", match._id))
        .collect();
      for (const claim of claims) await ctx.db.delete(claim._id);
      await ctx.db.delete(match._id);
    }

    const teams = await ctx.db
      .query("teams")
      .withIndex("by_event", (q) => q.eq("eventId", args.eventId))
      .collect();
    for (const team of teams) await ctx.db.delete(team._id);

    for (const list of lists) await ctx.db.delete(list._id);

    await ctx.db.delete(args.eventId);
    return { teams: teams.length, matches: matches.length };
  },
});
`;
writeFileSync(p, s);
console.log("convex/events.ts patched");
MJS
bun /tmp/ev.mjs

say "Admin UI: event controls"
cat > /tmp/ev2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/index.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("setInactive")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { CheckCircle2, Download, LoaderCircle } from "lucide-react";',
              'import { CheckCircle2, Download, LoaderCircle, Trash2 } from "lucide-react";');
s = s.replace("  const setActive = useMutation(api.events.setActive);",
`  const setActive = useMutation(api.events.setActive);
  const setInactive = useMutation(api.events.setInactive);
  const removeEvent = useMutation(api.events.remove);
  const [removing, setRemoving] = useState<string | null>(null);
  const [confirmKey, setConfirmKey] = useState("");`);

const oldRow = `                {!event.isActive ? (
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => void setActive({ eventId: event._id })}
                  >
                    Set active
                  </Button>
                ) : null}
              </div>`;
if (!s.includes(oldRow)) fail("could not find the event row");
s = s.replace(oldRow, `                {event.isActive ? (
                  <Button variant="outline" size="sm"
                    onClick={() => void setInactive({ eventId: event._id })}>
                    Set inactive
                  </Button>
                ) : (
                  <Button variant="outline" size="sm"
                    onClick={() => void setActive({ eventId: event._id })}>
                    Set active
                  </Button>
                )}
                {event.removable ? (
                  <Button variant="outline" size="sm"
                    onClick={() => {
                      setRemoving(removing === event._id ? null : event._id);
                      setConfirmKey("");
                    }}>
                    <Trash2 className="size-3" /> Remove
                  </Button>
                ) : (
                  <Badge variant="secondary" title="Events holding scouting data cannot be removed">
                    {event.reportCount + event.pitCount} report
                    {event.reportCount + event.pitCount === 1 ? "" : "s"}
                  </Badge>
                )}

              {removing === event._id ? (
                <div className="mt-1 w-full space-y-2 rounded-md border border-dashed p-3">
                  <p className="text-muted-foreground text-xs">
                    Removes {event.teamCount} teams and {event.matchCount}{" "}
                    matches. Nothing scouted is lost because there is nothing
                    scouted — re-import from TBA to get it back.
                  </p>
                  <Input
                    placeholder={\`Type \${event.tbaEventKey} to confirm\`}
                    value={confirmKey}
                    autoCapitalize="none"
                    onChange={(e) => setConfirmKey(e.target.value)}
                  />
                  <Button size="sm" variant="destructive"
                    disabled={confirmKey.trim() !== event.tbaEventKey}
                    onClick={() => {
                      void removeEvent({ eventId: event._id })
                        .then(() => {
                          toast.success(\`\${event.name} removed\`);
                          setRemoving(null);
                          setConfirmKey("");
                        })
                        .catch((error: unknown) =>
                          toast.error("Could not remove", {
                            description:
                              error instanceof Error ? error.message : String(error),
                          }));
                    }}>
                    Remove permanently
                  </Button>
                </div>
              ) : null}
              </div>`);

// the row wrapper needs to allow the confirm panel to sit underneath
s = s.replace(`                className="flex flex-wrap items-center gap-3 rounded-lg border p-3"`,
              `                className="flex flex-wrap items-center gap-3 rounded-lg border p-3"`);

s = s.replace(`                  <p className="text-muted-foreground text-xs">
                    {event.tbaEventKey} · {event.teamCount} teams ·{" "}
                    {event.matchCount} qualification matches
                  </p>`,
`                  <p className="text-muted-foreground text-xs">
                    {event.tbaEventKey} · {event.teamCount} teams ·{" "}
                    {event.matchCount} qualification matches
                    {event.reportCount + event.pitCount > 0
                      ? \` · \${event.reportCount} match / \${event.pitCount} pit reports\`
                      : ""}
                  </p>`);

s = s.replace(`            One event is active at a time. Everything in the app reads from it.`,
`            One event is active at a time and everything reads from it. Setting
            an event inactive changes nothing about its data — it just stops the
            app pointing at it.`);

writeFileSync(p, s);
console.log("src/routes/admin/index.tsx patched");
MJS
bun /tmp/ev2.mjs
rm -f /tmp/ev.mjs /tmp/ev2.mjs

say "Regenerating Convex types"
bunx convex dev --once || echo "Convex push skipped — run it yourself before typechecking."

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
