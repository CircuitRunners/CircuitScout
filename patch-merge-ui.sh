#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-merge-ui.sh
#   - The "not submitted" list was nested inside the branch that only renders
#     when somebody HAS submitted, so it was invisible in exactly the case you
#     most want it: nobody has submitted yet.
#   - The apply card now always renders and says why it is unavailable, rather
#     than appearing to be missing.
#   - Checkbox swapped for a plain toggle button to remove one primitive-API
#     dependency from this screen.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/admin/merge.tsx ]] || { echo "ERROR: run track-g.sh first" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

cat > /tmp/m.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/admin/merge.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("Nobody has submitted")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { Checkbox } from "@/components/ui/checkbox";\n', "");

const oldCard = s.slice(
  s.indexOf("        <CardContent className=\"space-y-2\">\n          {data === undefined ? ("),
  s.indexOf("      </Card>\n\n      <Card>\n        <CardHeader>\n          <CardTitle>Proposed ranking"),
);
if (!oldCard) fail("could not find the submitters card body");

s = s.replace(oldCard, `        <CardContent className="space-y-3">
          {data === undefined ? (
            <p className="text-muted-foreground text-sm">Loading…</p>
          ) : (
            <>
              {data.submitters.length === 0 ? (
                <p className="text-sm">
                  Nobody has submitted a list yet. A scout submits from the pick
                  list page by marking one of their lists.
                </p>
              ) : (
                <div className="flex flex-wrap gap-2">
                  {data.submitters.map((sub) => (
                    <Badge key={sub.name} variant="secondary">
                      <Users className="size-3" />
                      {sub.name} · {sub.ranked} ranked ·{" "}
                      {SCOUT_WEIGHTS[sub.weightTier as keyof typeof SCOUT_WEIGHTS]}×
                    </Badge>
                  ))}
                </div>
              )}

              {/* Shown whether or not anyone has submitted — when nobody has,
                  this is the whole answer to "why is there nothing here". */}
              {data.missing.length > 0 ? (
                <div className="space-y-1">
                  <p className="text-muted-foreground text-xs">
                    Not submitted ({data.missing.length}) — a missing strategy
                    lead is worth chasing before you trust this ranking.
                  </p>
                  <div className="flex flex-wrap gap-1">
                    {data.missing.map((name) => (
                      <Badge key={name} variant="outline" className="text-xs">
                        {name}
                      </Badge>
                    ))}
                  </div>
                </div>
              ) : data.submitters.length > 0 ? (
                <p className="text-muted-foreground text-xs">
                  Everyone with an account has submitted.
                </p>
              ) : null}

              {data.targets && data.submitters.length > 0 ? (
                <p className="text-muted-foreground text-xs">
                  Tier sizes come from what the contributing lists averaged:{" "}
                  {data.targets.t1} first, {data.targets.t2} second,{" "}
                  {data.targets.t3} third.
                </p>
              ) : null}
            </>
          )}
        </CardContent>
`);

const oldApply = s.slice(s.indexOf(`        <CardContent className="space-y-3">
          <label htmlFor="notes"`), s.lastIndexOf("        </CardContent>"));
if (!oldApply) fail("could not find the apply card body");

s = s.replace(oldApply, `        <CardContent className="space-y-3">
          <Button variant={includeNotes ? "default" : "outline"} size="sm"
            onClick={() => setIncludeNotes(!includeNotes)}>
            {includeNotes ? "Carrying pick notes across" : "Not carrying pick notes"}
          </Button>
          <p className="text-muted-foreground text-xs">
            Notes are attributed to whoever wrote them.
          </p>

          {rows.length === 0 ? (
            <p className="text-muted-foreground rounded-lg border border-dashed p-4 text-sm">
              Nothing to apply yet. At least one scout has to mark a list for
              submission, with teams ranked on it.
            </p>
          ) : (
            <>
              <div className="space-y-2">
                <Label htmlFor="confirm">Type MERGE to confirm</Label>
                <Input id="confirm" className="max-w-40" value={confirm}
                  autoCapitalize="characters"
                  onChange={(e) => setConfirm(e.target.value)} />
              </div>
              <Button variant="destructive"
                disabled={busy || confirm.trim().toUpperCase() !== "MERGE"}
                onClick={() => void run()}>
                Rebuild the primary list
              </Button>
            </>
          )}
`);

writeFileSync(p, s);
console.log("src/routes/admin/merge.tsx patched");
MJS
bun /tmp/m.mjs
rm -f /tmp/m.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
