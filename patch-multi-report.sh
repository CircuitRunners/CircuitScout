#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-multi-report.sh
#   Allows several scouts to report the same robot in the same match.
#   Replaces the claim lock with a per-robot report count.
#
# REVERSES a rule from the original requirements ("only lets 1 scout select 1
# robot per match"). Claims no longer block; the claims table is left in the
# schema but is no longer used.
#
# Still blocked: the SAME scout submitting twice for the same robot in the same
# match. That is an accident, not redundancy.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/scout/form.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Convex: allow duplicates, add counts"
cat > /tmp/m1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "convex/matchReports.ts";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };

// forMatchAndTeam: distinguish MY report from everyone else's.
const oldFind = `    const existing = await ctx.db
      .query("matchReports")
      .withIndex("by_match", (q) => q.eq("matchId", match._id))
      .collect();
    const report = existing.find((r) => r.teamId === team._id) ?? null;

    const onRed = match.redTeamNumbers.includes(team.number);
    return { match, team, report, alliance: onRed ? "red" : "blue" };`;
if (!s.includes(oldFind)) fail("could not find forMatchAndTeam body");
s = s.replace(oldFind, `    const userId = await requireUser(ctx);
    const existing = (
      await ctx.db
        .query("matchReports")
        .withIndex("by_match", (q) => q.eq("matchId", match._id))
        .collect()
    ).filter((r) => r.teamId === team._id);

    const myReport = existing.find((r) => r.scoutId === userId) ?? null;
    const onRed = match.redTeamNumbers.includes(team.number);
    return {
      match,
      team,
      myReport,
      othersCount: existing.length - (myReport ? 1 : 0),
      alliance: onRed ? "red" : "blue",
    };`);

// Per-robot report counts for the match selector.
s = s.replace("export const editHistory = query({",
`/**
 * How many reports each robot in a match already has, and whether one of them
 * is mine. Redundant coverage is deliberate — two scouts on one robot is a
 * cross-check, not a mistake — so this reports depth rather than locking.
 */
export const countsForMatch = query({
  args: { matchNumber: v.number() },
  handler: async (ctx, args) => {
    const event = await activeEvent(ctx);
    if (!event) return [];
    const userId = await requireUser(ctx);

    const match = await ctx.db
      .query("matches")
      .withIndex("by_event_number", (q) =>
        q.eq("eventId", event._id).eq("matchNumber", args.matchNumber))
      .unique();
    if (!match) return [];

    const reports = await ctx.db
      .query("matchReports")
      .withIndex("by_match", (q) => q.eq("matchId", match._id))
      .collect();

    const byTeam = new Map<string, { count: number; mine: boolean }>();
    for (const r of reports) {
      const row = byTeam.get(r.teamId) ?? { count: 0, mine: false };
      row.count += 1;
      if (r.scoutId === userId) row.mine = true;
      byTeam.set(r.teamId, row);
    }

    return [...byTeam.entries()].map(([teamId, row]) => ({ teamId, ...row }));
  },
});

export const editHistory = query({`);

// submit: only block a repeat from the SAME scout.
const oldDup = `    const duplicate = (
      await ctx.db
        .query("matchReports")
        .withIndex("by_match", (q) => q.eq("matchId", matchId))
        .collect()
    ).find((r) => r.teamId === teamId);
    if (duplicate) {
      throw new Error("A report for that robot in that match already exists.");
    }`;
if (!s.includes(oldDup)) fail("could not find the duplicate guard");
s = s.replace(oldDup, `    const mineAlready = (
      await ctx.db
        .query("matchReports")
        .withIndex("by_match", (q) => q.eq("matchId", matchId))
        .collect()
    ).find((r) => r.teamId === teamId && r.scoutId === scoutId);
    if (mineAlready) {
      throw new Error("You have already reported that robot in this match.");
    }`);

// The claim is no longer taken, so there is nothing to release on submit.
s = s.replace(`    // The robot is covered; free the claim for whoever scouts it next match.
    const claim = await ctx.db
      .query("matchClaims")
      .withIndex("by_match_team", (q) =>
        q.eq("matchId", matchId).eq("teamId", teamId))
      .unique();
    if (claim) await ctx.db.delete(claim._id);

`, "");

writeFileSync(p, s);
console.log("convex/matchReports.ts patched");
MJS
bun /tmp/m1.mjs

say "Selector: counts instead of locks"
cat > /tmp/m2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/scout/index.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };

s = s.replace('import { CheckCircle2, ChevronRight, Lock } from "lucide-react";',
              'import { ChevronRight } from "lucide-react";');

s = s.replace(`  const claims = useQuery(api.claims.forMatchNumber, { matchNumber });
  const me = useQuery(api.profiles.me);
  const navigate = useNavigate();`,
`  const counts = useQuery(api.matchReports.countsForMatch, { matchNumber });
  const navigate = useNavigate();`);

const oldStatus = `  const statusFor = (teamId: string) =>
    claims?.find((c) => c.teamId === teamId) ?? null;`;
if (!s.includes(oldStatus)) fail("could not find statusFor");
s = s.replace(oldStatus, `  const countFor = (teamId: string) =>
    counts?.find((c) => c.teamId === teamId) ?? { count: 0, mine: false };`);

const oldButton = `          (() => {
            const status = statusFor(team._id);
            const takenByOther =
              status !== null && status.scoutId !== me?.userId;
            return (
              <button
                key={team._id}
                disabled={takenByOther}
                onClick={() => void navigate(\`/scout/\${matchNumber}/\${team.number}\`)}
                className="hover:bg-accent/50 flex min-h-14 w-full items-center gap-2 rounded-md border p-3 text-left transition-colors disabled:cursor-not-allowed disabled:opacity-50"
              >
                <span className="font-semibold tabular-nums">{team.number}</span>
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {team.nickname}
                </span>
                {status?.state === "submitted" ? (
                  <CheckCircle2 className="size-4 shrink-0" />
                ) : status?.state === "claimed" ? (
                  <Lock className="size-4 shrink-0" />
                ) : null}
              </button>
            );
          })()`;
if (!s.includes(oldButton)) fail("could not find the robot button");
s = s.replace(oldButton, `          (() => {
            const { count, mine } = countFor(team._id);
            return (
              <button
                key={team._id}
                onClick={() => void navigate(\`/scout/\${matchNumber}/\${team.number}\`)}
                className="hover:bg-accent/50 flex min-h-14 w-full items-center gap-2 rounded-md border p-3 text-left transition-colors"
              >
                <span className="font-semibold tabular-nums">{team.number}</span>
                <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
                  {team.nickname}
                </span>
                <Badge
                  variant={count === 0 ? "outline" : mine ? "secondary" : "default"}
                  className="shrink-0 tabular-nums"
                  title={
                    mine
                      ? "You have already reported this robot"
                      : "Reports submitted for this robot"
                  }
                >
                  {count}
                  {mine ? " ✓" : ""}
                </Badge>
              </button>
            );
          })()`);

const oldGrid = `  return (
    <div className="grid grid-cols-2 gap-4 p-3">
      {column(data.red, "Red", "text-red-600 dark:text-red-400")}
      {column(data.blue, "Blue", "text-blue-600 dark:text-blue-400")}
    </div>
  );`;
if (!s.includes(oldGrid)) fail("could not find the alliance grid");
s = s.replace(oldGrid, `  return (
    <div className="space-y-3 p-3">
      <div className="grid grid-cols-2 gap-4">
        {column(data.red, "Red", "text-red-600 dark:text-red-400")}
        {column(data.blue, "Blue", "text-blue-600 dark:text-blue-400")}
      </div>
      <p className="text-muted-foreground text-xs">
        The number is how many scouts have reported that robot. A tick means one
        of them is you. More than one report is fine — a second look is a
        cross-check, not a duplicate.
      </p>
    </div>
  );`);

s = s.replace('      description="Pick a match, then pick a robot. Greyed-out robots are already covered."',
              '      description="Pick a match, then pick a robot. The badge shows how many reports that robot already has."');

writeFileSync(p, s);
console.log("src/routes/scout/index.tsx patched");
MJS
bun /tmp/m2.mjs

say "Form: drop the claim lock"
cat > /tmp/m3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/scout/form.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };

s = s.replace(`  const claim = useMutation(api.claims.claim);
  const release = useMutation(api.claims.release);
  const submit = useMutation(api.matchReports.submit);`,
`  const submit = useMutation(api.matchReports.submit);`);

s = s.replace(`  const [claimError, setClaimError] = useState<string | null>(null);

  useEffect(() => {
    if (!data?.match || !data.team) return;
    claim({ matchId: data.match._id, teamId: data.team._id }).catch(
      (error: unknown) =>
        setClaimError(error instanceof Error ? error.message : String(error)),
    );
  }, [data?.match, data?.team, claim]);

`, "");

s = s.replace(`      await release({ matchId: data.match._id, teamId: data.team._id });
`, "");

const oldExisting = `  if (data.report) {
    return (
      <PageShell
        title={\`Qual \${matchNumber} · \${data.team.number}\`}
        description="This robot already has a report for this match."
      >`;
if (!s.includes(oldExisting)) fail("could not find the existing-report guard");
s = s.replace(oldExisting, `  if (data.myReport) {
    return (
      <PageShell
        title={\`Qual \${matchNumber} · \${data.team.number}\`}
        description="You have already reported this robot in this match."
      >`);

const oldClaimErr = `  if (claimError) {
    return (
      <PageShell title={\`Qual \${matchNumber} · \${data.team.number}\`} description={claimError}>
        <Button variant="outline" onClick={() => void navigate("/scout")}>
          <ArrowLeft className="size-4" /> Pick another robot
        </Button>
      </PageShell>
    );
  }
`;
if (!s.includes(oldClaimErr)) fail("could not find the claim error block");
s = s.replace(oldClaimErr, "");

// Tell the scout when someone else has already covered this robot.
s = s.replace('      description={`${data.team.nickname} · ${data.alliance} alliance`}',
`      description={
        data.othersCount > 0
          ? \`\${data.team.nickname} · \${data.alliance} alliance · \${data.othersCount} other report\${data.othersCount === 1 ? "" : "s"} already submitted\`
          : \`\${data.team.nickname} · \${data.alliance} alliance\`
      }`);

writeFileSync(p, s);
console.log("src/routes/scout/form.tsx patched");
MJS
bun /tmp/m3.mjs
rm -f /tmp/m1.mjs /tmp/m2.mjs /tmp/m3.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Patched. Several scouts can now cover the same robot in one match.
  convex/claims.ts is no longer called by the UI; the table stays in the
  schema so existing rows are not orphaned.

DONE
