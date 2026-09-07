#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-claim-primary.sh — adopt a primary pick list created before lists were
# owned by a team.
#
# The merge looks for a primary list matching the caller's team. Lists made
# before that change have no teamNumber, so they belong to nobody and the
# merge has nowhere to write.
#
# No schema change — teamNumber is already optional on pickLists.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f convex/pickLists.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Convex: claim and detect"
cat > /tmp/c1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/pickLists.ts";
let s = readFileSync(p, "utf8");
if (s.includes("orphanPrimary")) { console.log("already patched"); process.exit(0); }
s += `
/**
 * A primary list on the active event that belongs to no team. Only ever one or
 * two of these exist — they predate lists being owned by a team.
 */
export const orphanPrimary = query({
  args: {},
  handler: async (ctx) => {
    const event = await activeEvent(ctx);
    if (!event) return null;

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", null))
      .collect();
    const orphan = lists.find((l) => l.teamNumber === undefined);
    if (!orphan) return null;

    const entries = await ctx.db
      .query("pickListEntries")
      .withIndex("by_list", (q) => q.eq("pickListId", orphan._id))
      .collect();

    return {
      listId: orphan._id,
      name: orphan.name,
      total: entries.length,
      ranked: entries.filter((e) => e.tier !== "uncategorized").length,
    };
  },
});

/**
 * Adopts that list for the caller's team, keeping every entry and note on it.
 * Refuses if the team already has a primary, because two would leave the merge
 * writing to whichever it happened to find first.
 */
export const claimOrphanPrimary = mutation({
  args: { listId: v.id("pickLists") },
  handler: async (ctx, args) => {
    const me = await requireTeamAdmin(ctx);
    const event = await activeEvent(ctx);
    if (!event) throw new Error("No active event.");
    if (me.teamNumber === undefined) {
      throw new Error("Set your team number on your profile first.");
    }

    const list = await ctx.db.get(args.listId);
    if (!list) throw new Error("That list no longer exists.");
    if (list.ownerId !== null) throw new Error("That is not a primary list.");
    if (list.teamNumber !== undefined) {
      throw new Error(\`That list already belongs to team \${list.teamNumber}.\`);
    }

    const lists = await ctx.db
      .query("pickLists")
      .withIndex("by_event_owner", (q) =>
        q.eq("eventId", event._id).eq("ownerId", null))
      .collect();
    if (lists.some((l) => l.teamNumber === me.teamNumber)) {
      throw new Error("Your team already has a primary list for this event.");
    }

    await ctx.db.patch(args.listId, {
      teamNumber: me.teamNumber,
      name: \`Team \${me.teamNumber} primary list\`,
    });
    return { teamNumber: me.teamNumber };
  },
});
`;
writeFileSync(p, s);
console.log("convex/pickLists.ts patched");
MJS
bun /tmp/c1.mjs

say "Client: offer it when there is no primary"
cat > /tmp/c2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/picklists/index.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("orphanPrimary")) { console.log("already patched"); process.exit(0); }

s = s.replace("  const primary = useQuery(api.pickLists.primary);",
`  const primary = useQuery(api.pickLists.primary);
  const orphan = useQuery(api.pickLists.orphanPrimary);
  const claimOrphan = useMutation(api.pickLists.claimOrphanPrimary);`);

// The gate is either `isAnyAdmin` or the pre-team-admin form; match both.
const anchor = /(\s*)(isAnyAdmin|profile\?\.role === "admin") \? \(\n(\s*)<Button variant="outline" onClick=\{\(\) => void ensurePrimary\(\{\}\)\}>\n\s*Create the primary list\n\s*<\/Button>\n\s*\) : \(/;
const m = s.match(anchor);
if (!m) fail("could not find the create-primary button");
const gate = m[2];
s = s.replace(anchor, `            ${gate} ? (
              <div className="space-y-3">
                {orphan ? (
                  <div className="space-y-2 rounded-lg border border-dashed p-3">
                    <p className="text-sm">
                      There is a primary list here — <strong>{orphan.name}</strong>,
                      with {orphan.ranked} of {orphan.total} teams ranked — from
                      before lists belonged to a team.
                    </p>
                    <p className="text-muted-foreground text-xs">
                      Adopting it keeps every card and note exactly where it is.
                    </p>
                    <Button size="sm"
                      onClick={() => {
                        void claimOrphan({ listId: orphan.listId })
                          .then((r) => toast.success(\`Adopted for team \${r.teamNumber}\`))
                          .catch((error: unknown) =>
                            toast.error("Could not adopt it", {
                              description:
                                error instanceof Error ? error.message : String(error),
                            }));
                      }}>
                      Adopt this list
                    </Button>
                  </div>
                ) : null}
                <Button variant="outline" onClick={() => void ensurePrimary({})}>
                  {orphan ? "Or start a fresh one" : "Create the primary list"}
                </Button>
              </div>
            ) : (`);

writeFileSync(p, s);
console.log("src/routes/picklists/index.tsx patched");
MJS
bun /tmp/c2.mjs
rm -f /tmp/c1.mjs /tmp/c2.mjs

say "Push and typecheck"
bunx convex dev --once || echo "Convex push failed — see above."
bun run typecheck || echo "Typecheck reported issues — see above."
