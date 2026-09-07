# CircuitScout — Implementation Plan

Mobile-first scouting app for **REBUILT**, the 2026 FRC game.
Stack and coding rules live in `AGENTS.md`. Read that first; it is binding.

Every **DECISION** raised during planning is now **RESOLVED**. Phase 0 is fully
specified and unblocked.

**Settled:** climb points 10/20/30 endgame and 15 for any auto climb · single
active event · report edits allowed with a mandatory reason · one submittable
pick list per scout · three auto start zones (trench / bump / hub) · connection
indicator now, PWA later.

---

## 1. Architecture

Convex is the whole backend. No API routes, no server layer, no second database.
The SPA subscribes to Convex queries, so a match report submitted on one phone
updates the pick list board on another with no refresh — which is the entire
reason this stack fits an app where fifteen people write to one dataset at once.

Three rules that keep it clean:

- **Convex owns everything persisted.** Teams, matches, reports, pick lists,
  users. Read with `useQuery`, write with `useMutation`.
- **Zustand owns only what dies with the tab.** Drag state, hamburger open,
  which sort is applied to a column, transient form scratch state.
- **The TBA key never reaches the browser.** It lives in the Convex environment
  and is read inside an action. Anything in a `VITE_`-prefixed variable ships to
  the client, so it must not go there.

```
Phone / Desktop (React SPA)
  |-- useQuery    --> live subscriptions
  |-- useMutation --> transactional writes (claims, reports, tiers)
  '-- action      --> TBA fetch --> internalMutation --> tables
```

---

## 2. Route map

§7 is emphatic that landing areas come before forms — "not just jumping into the
forms of the action." That shapes the entire route tree:

```
/                                 Dashboard - event status, my counts, links
/teams                            Team list  (?team=1002 opens detail modal)
/teams/compare                    Side-by-side, 2-4 teams  (?teams=1002,254)
/matches                          Schedule browser
/matches/:matchNumber             Match preview - six robots, drive-team view
/pit                              Pit landing - grid, scouted / not scouted
/pit/:teamNumber                  Pit form
/scout                            Match landing - upcoming, my claims, my reports
/scout/:matchNumber/:teamNumber   Match form
/picklists                        Landing - primary + my lists, create new
/picklists/:listId                Kanban board
/admin                            Event setup, roles, merge tool  (admin only)
/admin/data                       Coverage, flagged reports, CSV export
/sign-in
```

The team detail modal keys off a **URL search param**, not Zustand. That makes a
team shareable and the back button correct — a good example of state that looks
ephemeral but belongs in the URL, which is neither Convex nor Zustand.

---

## 3. Data model

Frozen at the end of Phase 0. **`convex/schema.ts` is the one file every track
touches, so changes after the freeze go through you, not through an agent.**

```ts
{
  ...authTables,

  profiles: { userId, displayName, role: "admin" | "scout",
              weightTier: "lead" | "trusted" | "normal", createdAt }
    // by_user

  events: { tbaEventKey, name, isActive, importedAt, importedBy }
    // by_key

  teams: { eventId, tbaTeamKey, number, nickname, city, stateProv, country }
    // by_event, by_event_number

  matches: { eventId, tbaMatchKey, matchNumber,
             redTeamNumbers: number[], blueTeamNumbers: number[],
             scheduledTime: number | null }
    // by_event, by_event_number

  matchClaims: { eventId, matchId, teamId, scoutId, claimedAt, expiresAt }
    // by_match_team  <- uniqueness lives here
    // by_scout

  pitReports: {
    eventId, teamId, scoutId, updatedAt,
    scoring: { turret, drumNonFullWidth, drumFullWidth, fixed, kitbot,
               other: boolean, otherText: string | null },
    climb: { low, mid, high, duringAuto: boolean },
    drivetrain: string,
    underTrench: boolean, overBump: boolean,
    robotNotes: string, otherNotes: string,
    photoId: Id<"_storage"> | null
  } // by_event_team

  matchReports: {
    eventId, matchId, teamId, scoutId, submittedAt, updatedAt,
    auto: { path: AutoPath, climbL1: boolean, fuel: number,
            fouls: number, notes: string },
    teleop: { byShift: { transition, s1, s2, s3, s4 },   // raw, reclassifiable
              passedNeutral, passedFullField, stoleFuel: number,
              defended: boolean, notes: string },
    matchStartedAt: number | null,
    autoWinner: "red" | "blue" | null,      // scout-entered
    autoWinnerFlagged: boolean,             // reconciliation disagreed
    hubStateSource: "timed" | "estimated" | "none",
    endgame: { climb: "none"|"low"|"mid"|"high",
               fuel, passedNeutral, passedFullField: number, notes: string },
    ratings: { driver, defense, accuracy: number,       // 1-10
               shootsOnMove: boolean,
               broke: boolean, brokeNotes: string,
               inconsistent: boolean, inconsistentNotes: string }
  } // by_event_team, by_match, by_scout

  reportEdits: { reportId, editedBy, editedAt, reason: string }
    // by_report

  pickLists: { eventId, ownerId: Id<"users">|null,   // null = team primary
               name, isPrimary: boolean,
               isSubmitted: boolean,   // at most one per scout per event
               createdAt }
    // by_event_owner, by_event_submitted

  pickListEntries: { pickListId, teamId,
                     tier: "t1"|"t2"|"t3"|"dnp"|"uncategorized",
                     order: number }
    // by_list, by_list_tier
}
```

Two shape notes. `order` is a float so a drag inserts between neighbours by
halving the gap — no renumbering a column on every drop; renormalise only when
the gap gets too small to represent. And **averages are not stored.** At event
scale (~50 teams x ~12 matches = ~600 reports) computing them per query is free,
and denormalised aggregates are the classic source of "the board says 43 but the
team page says 41" during alliance selection.

> **RESOLVED 1 — Climb points.** Endgame L1 = 10, L2 = 20, L3 = 30. Any auto
> climb scores 15 (the rules permit L1 only in auto, so in practice auto climb is
> a flat 15). Maximum climb contribution per match is 45.
>
> ```ts
> // src/lib/scoring.ts — single source of truth
> export const CLIMB_POINTS = {
>   auto: 15,
>   endgame: { none: 0, low: 10, mid: 20, high: 30 },
> } as const;
> ```
>
> Total climb points for a report = `(auto.climbL1 ? 15 : 0) + endgame[climb]`.
> Nothing anywhere else may hardcode these numbers.

> **RESOLVED 2 — Report editing.** Edits allowed, but every edit requires a
> typed reason, appended to the `reportEdits` table — never overwritten, so the
> full history survives. `matchReports.update` takes `reason` as a required
> argument and rejects an empty string; the team detail view shows an "edited"
> badge with the reason on hover. Author may edit their own report; admin may
> edit any.

> **RESOLVED 3 — Single active event.** One `isActive` event at a time; every
> query resolves it server-side rather than taking an `eventId` argument. Tables
> still carry `eventId`, so a switcher is additive later with no migration.

---

## 4. Function surface

The contract between tracks. These exist as typed stubs by end of Phase 0.

| Area | Functions |
|---|---|
| Auth | `profiles.me`, `profiles.list`, `profiles.setRole` *(admin)* |
| Events | `events.importFromTBA` *(action)*, `events.active`, `events.setActive` |
| Teams | `teams.listWithStatus`, `teams.detail` |
| Stats | `stats.forEvent` -> `Record<teamId, TeamStats>`, `stats.forTeam`, `stats.compare`, `stats.coverage` |
| Export | `exports.csv` |
| Pit | `pit.get`, `pit.upsert`, `pit.generateUploadUrl` |
| Match | `matches.listForEvent`, `matches.teamsInMatch` |
| Claims | `claims.claim`, `claims.release`, `claims.mine` |
| Reports | `matchReports.submit`, `matchReports.update` *(requires `reason`)*, `matchReports.listForTeam`, `matchReports.editHistory` |
| Hub | `hub.deriveAutoWinner`, `hub.reconcile` *(cross-scout check)* |
| Lists | `pickLists.listMine`, `pickLists.primary`, `pickLists.create`, `pickLists.rename`, `pickLists.remove`, `pickLists.setSubmitted` |
| Entries | `entries.forList`, `entries.move` |
| Merge | `merge.preview` *(admin, pure)*, `merge.apply` *(admin)* |

`TeamStats` = avg auto fuel, avg teleop fuel, avg endgame fuel, avg total fuel,
avg climb points, avg driver rating, avg defense rating, avg accuracy, report
count. Built in **Phase 0** because four tracks consume it.

**TBA import** hits `/event/{key}/teams/simple` and `/event/{key}/matches/simple`
with the `X-TBA-Auth-Key` header, filters matches to `comp_level === "qm"`, and
upserts by `tbaTeamKey` / `tbaMatchKey` so re-import updates rather than
duplicates. Schedules change mid-event, so re-import must be safe at any time.

---

## 5. The three hard parts

### 5.1 Auto pathing map — BUILT (Track D)

A scout records what the robot did in autonomous, on a phone, during a
20-second period. Two input skins over one shared shape; the buttons were built
first so the map could never become a critical path, and both are kept.

**Field vocabulary (from the REBUILT manual, §5).** Per alliance: one HUB, one
TOWER, one OUTPOST, one DEPOT. The ALLIANCE ZONE is separated from the NEUTRAL
ZONE by a wall containing, from one side to the other: TRENCH, BUMP, HUB, BUMP,
TRENCH — trenches outboard, bumps flanking the hub. Trenches are driven *under*
(22in clearance), bumps are driven *over* (6.5in tall). The DEPOT holds 24 FUEL
and sits inside the alliance zone; the OUTPOST is the human-player corner
station. Use these words verbatim in the UI — a scout under pressure should see
the same nouns the drive team uses.

```ts
// Left/right are ALWAYS from that alliance's drivers looking out at the field.
type Lane = "trench-left" | "bump-left" | "bump-right" | "trench-right";
type StartPosition = Lane | "hub";

// inbound is null when auto ended with the robot still out there.
type AutoCycle = { outbound: Lane; inbound: Lane | null };

type AutoStep =
  | ({ kind: "neutral" } & AutoCycle)
  | { kind: "depot" }
  | { kind: "outpost" };

type AutoPath = { start: StartPosition | null; steps: AutoStep[] };
```

**Driver perspective is enforced by the UI, not by memory.** Scouts sit opposite
or beside the drive team, so on-screen "left" and eyeline "left" can be
opposites, and a mirrored entry is silently wrong rather than obviously wrong.
Two mechanisms: the map renders already flipped to the scouted robot's alliance,
taken from the imported schedule; and every lane control in button mode carries
a permanent label rather than a dismissible tooltip.

**Rules enforced in the mutation, not only the client.** A client-side limit is
a hint — an edited request or a second entry surface built later would sail past
it.

- At most **3 neutral-zone cycles**. Depot and outpost pickups are uncapped;
  they involve no field crossing.
- Only the **final step** may be exit-only. Nothing follows a robot that never
  came back.

> **RESOLVED 8 — Steps are ordered, superseding the counter model.** Depot and
> outpost pickups were originally plain counters alongside a cycle list. They
> are now steps in one ordered sequence, because order carries information a
> count does not: whether a robot preloaded from the depot before leaving, or
> topped up between trips, is a different robot.
>
> Reports written under the counter model still read. `cycles`,
> `depotPickups` and `outpostPickups` remain in the schema as optional fields
> that nothing writes, and `readSteps()` in `convex/lib/types.ts` returns either
> shape as steps.

> **RESOLVED 4 — Start positions.** Anywhere on the ROBOT STARTING LINE, always
> lining up with a trench, a bump, or the hub. Five snap targets per alliance,
> stored as an enum rather than a coordinate so "teams starting in front of the
> hub average X auto fuel" stays a one-line query. Editable at any point except
> mid-cycle.

### 5.2 Pick list merge / consensus

"Merged into a best-fit state" needs a defined algorithm. Proposal:

Each contributing list votes per team. Tier gives a base score
(T1 = 100, T2 = 70, T3 = 40, DNP = -100). Position within a column adjusts inside
a band that can never cross a tier boundary, roughly
`base + 25 * (size - index) / size`. **Uncategorized is an abstention, not a
zero** — excluded from that team's average, because "I didn't get to them" is not
"they're mediocre."

Consensus score is the mean over lists that voted. Report alongside it:

- **voter count** — T1 from one scout is not T1 from six
- **spread** (standard deviation) — high spread means the room disagrees and a
  human should look before alliance selection
- **dnpCount** as a separate veto flag — one scout who watched a robot tip over
  twice is signal that a mean will bury

`merge.preview` computes and writes nothing. An admin reviews the ranked table,
then `merge.apply` writes to the primary list. **The merge never silently
overwrites the primary list.** An unexplained reshuffle mid-selection is worse
than having no tool at all.

> **RESOLVED 5 — Which lists get merged.** A scout may keep as many personal
> lists as they like, but exactly one may be flagged `isSubmitted`. The merge
> reads every submitted list for the active event. `pickLists.setSubmitted`
> clears the flag on that scout's other lists in the same mutation, so the
> one-per-scout rule is enforced transactionally rather than by convention. The
> merge preview names which scouts submitted and which did not — a missing
> strategy lead is worth seeing before you trust the output.

> **RESOLVED 6 — Weighting.** Three admin-assigned tiers on `profiles`:
>
> ```ts
> export const SCOUT_WEIGHTS = { lead: 5, trusted: 3, normal: 1 } as const;
> ```
>
> Consensus score becomes a weighted mean. Two consequences worth stating in the
> merge UI: a single strategy lead outvotes four normal scouts, and the "spread"
> figure must stay **unweighted** — it measures whether the room disagrees, and
> weighting it would hide exactly the disagreement it exists to surface.

### 5.3 Offline behaviour

Not in the spec, and the biggest real-world risk in the project. Venue wifi is
famously bad, and Convex is websocket-backed: it degrades gracefully while a tab
stays open — mutations queue, optimistic updates apply — but a cold page load
with no connectivity gets you nothing.

- **Accept it.** Load in the pits on good wifi, keep the tab alive all day.
  Cheapest, and how a lot of teams actually operate.
- **PWA shell.** Service worker caches the app shell so a reload works offline;
  data still needs the connection. Moderate effort, large reliability win.
- **Local-first buffer.** Queue reports in IndexedDB, flush on reconnect. Most
  work, and it partly breaks "Convex is the source of truth" since the buffer
  becomes a second store.

> **RESOLVED 7 — Indicator now, PWA later.** `<ConnectionIndicator>` ships in
> Phase 0 so a scout can see they are offline *before* keying in six minutes of
> match data. PWA shell deferred; revisit before the first competition you
> actually depend on this at.

---

### 5.4 Uncounted fuel and hub activity

Fuel scored into an inactive hub is worth **zero match points**. A robot that
puts 40 fuel through a dead hub and one that puts 40 through a live hub look
identical on a raw count and are worth very different amounts in a pick.
Tracking this is the highest-value analytical addition in the app.

The shift schedule is fully deterministic (WPILib 2026 game data):

| Time remaining | Phase | Hub state |
|---|---|---|
| Auto (20s) | Auto | both active |
| 2:20 – 2:10 | Transition | both active |
| 2:10 – 1:45 | Shift 1 | auto **loser** active |
| 1:45 – 1:20 | Shift 2 | auto **winner** active |
| 1:20 – 0:55 | Shift 3 | auto loser active |
| 0:55 – 0:30 | Shift 4 | auto winner active |
| 0:30 – 0:00 | Endgame | both active |

The alliance scoring **more** auto fuel goes inactive first, so it is active in
shifts 2 and 4. Auto and endgame are always active, so only **teleop** splits.

#### Two inputs, not one

Knowing the auto winner tells you *which shifts* were inactive. It does not tell
you *how much fuel went in during them* — a single teleop total cannot be split
after the fact. Retroactive classification needs a time anchor as well.

So the form banks fuel **per shift window** rather than as one number:

```ts
teleop: {
  byShift: { transition, s1, s2, s3, s4 },   // fuel counted into each window
  passedNeutral, passedFullField, stoleFuel, defended, notes
}
```

The scout never sees this. They tap the same stepper; the app decides which
bucket the increment lands in from its own clock. At the end of the match the
scout picks the auto winner, and counted / uncounted falls out:

- `counted   = transition + endgame + the two shifts their hub was active`
- `uncounted = the two shifts their hub was inactive`

Because the raw per-shift numbers are stored, a wrong auto winner is **fully
reversible** — flip the flag and the split recomputes. Nothing is lost.

#### The time anchor

One tap: a large **Match Start** button at the top of the form, pressed when the
match begins. The scout is already holding the phone watching the field, so this
costs nothing extra and needs no dedicated timekeeper role. Everything after it
is automatic.

If the start tap is missed, the form falls back to anchoring on the moment the
scout first opens the teleop panel. Shifts are 25 seconds long, so a few seconds
of drift only misclassifies fuel scored near a boundary — degraded but useful.
`hubStateSource: "timed" | "estimated" | "none"` records which applied, so you
can tell later which numbers to trust.

#### Deriving the auto winner instead of asking

The auto winner is decided by total alliance auto fuel — which is exactly what
six scouts are already recording. When all six robots in a match have reports,
Convex can compute the winner directly and the scout's answer becomes a
cross-check rather than the source of truth. When coverage is partial, the
scout's input stands.

This gives three reconciliation signals, all free with live queries:

1. **Derived vs entered.** If the sum of scouted auto fuel disagrees with what
   the scout picked, flag it.
2. **Scout vs scout.** If two scouts on the same match pick different auto
   winners, at least one is wrong. Majority wins; flag the dissenter.
3. **Sanity check.** More uncounted fuel than counted fuel usually means the
   auto winner is inverted. Prompt for confirmation before submitting — a plain
   "you have logged more dead-hub fuel than live-hub fuel, is that right?" with
   the two totals shown.

All three are **prompts, not blocks.** A robot really can dump into a dead hub
all match, and a scout who saw it must be able to record it. The report keeps
`autoWinnerFlagged: boolean` so the merge and averages can be recomputed later
if the flag turns out to have been right.

## 6. Viewing the data

Collection is well specified; consumption is not. Four distinct audiences read
this data, and they want different things:

| Audience | Question | Surface |
|---|---|---|
| Scout | "did my report save?" | `/scout` landing, my reports |
| Drive team | "who are we playing with in Q34?" | Match preview |
| Strategy lead | "who do we pick?" | Team list, compare, pick list |
| Data lead | "is any of this trustworthy?" | Coverage + QA |

### 6.1 Team detail (already in the spec, extended)

The modal from the team list carries the averages §3 of the requirements asks
for, plus three things the requirements omit that materially change a pick:

- **Report count next to every average.** An average over two matches and one
  over eleven are not comparable, and a bare number invites treating them as if
  they were. Show `n` inline, always.
- **Spread, not just the mean.** A team averaging 30 fuel could be 30/30/30 or
  5/85/0. Show min–max and per-match values; consistency is often what decides
  a second-round pick.
- **Counted vs uncounted fuel** side by side (§5.4).

Also list each report with its scout, and any edit reasons from `reportEdits`.
Knowing a number was revised, and why, is part of judging whether to trust it.

The "no dense tables" rule in the requirements applies to **scouting forms**.
This is a review surface, read on a laptop during alliance selection, and a
compact table is the right call here.

### 6.2 Compare view — `/teams/compare?teams=1002,254,1678`

Two to four teams side by side on the same metric rows. This is the surface
alliance selection actually runs on: you rarely need a team's stats in
isolation, you need to know which of three is better. Driven by a URL param so
a strategy lead can send a link to the drive team.

### 6.3 Match preview — `/matches/:matchNumber`

For an upcoming qualification match, all six robots with their key averages,
split red and blue. This is a **drive-team** surface, not a scouting one — it
answers "what can our partners do, and what are we up against" in the queue
line. It reuses the compare layout with the teams pre-filled from the schedule.

### 6.4 Coverage and quality — `/admin/data`

The view that decides whether anything above is trustworthy. It should show:

- Matches with fewer than six reports, and which robots are missing
- Teams with zero pit reports as the event goes on
- Reports flagged by the §5.4 reconciliation checks
- Reports with `hubStateSource: "none"` — no shift split, so their fuel totals
  are not comparable to the rest
- Reports per scout, and how many of theirs got flagged

This is the highest-value view in the app for whoever has to defend a pick, and
it is the one most likely to get cut for time. It should not be.

### 6.5 Export

CSV export of teams, match reports and pit reports. Two reasons, both real:
strategy leads inevitably want the data in a spreadsheet, and an export is your
escape hatch if the app is unavailable at the moment you need it — which is
exactly when venue wifi fails (§5.3).

### 6.6 Stats functions this requires

`stats.forEvent` (already Phase 0) gains siblings:

- `stats.forTeam(teamId)` — per-match series, not just aggregates
- `stats.compare(teamIds[])` — aligned metric rows for 2–4 teams
- `stats.coverage()` — missing reports, flagged reports, per-scout counts
- `exports.csv(kind)` — teams | matchReports | pitReports

---

## 7. Shared UI primitives — built in Phase 0

If eight agents each invent these you get seven subtly different ones. Build them
once, up front, in `src/components/scouting/`:

- **`<Stepper>`** — ±10 / ±5 / ±1 with a large readout. All three match periods.
- **`<RatingScale>`** — 1-10 selector for driver / defense / accuracy.
- **`<SegmentedChoice>`** — 2-4 large exclusive buttons (trench/bump,
  depot/outpost, climb level).
- **`<CapabilityCheck>`** — labelled checkbox row for pit scouting.
- **`<TeamCard>`** — number, nickname, pit status, report count, tier badge.
  Reused on team list, pit grid, and pick list board.
- **`<ConnectionIndicator>`** — Convex socket state in the nav.

Minimum 44px tap targets throughout. No dense tables on any scouting form.

---

## 8. Phases and sub-agent tracks

Parallelism rule: agents own **disjoint file sets**, and the shared contract
(`convex/schema.ts`, `src/lib/scoring.ts`, `src/lib/types.ts`, the primitives
in §7) is frozen before anyone starts. Run each track in its own git worktree.

### Phase 0 — Foundation. One agent, nothing parallel.

Schema · auth + `profiles` roles · `scoring.ts` weights · `stats.forEvent` ·
typed stubs for every function in §4 · nav shell with hamburger and all landing
routes · shared primitives from §7 · connection indicator · fixture seed script ·
dnd-kit installed.

Exit criteria: `bun run typecheck` clean, every stub callable, schema pushed,
fixture data loads. **Nothing starts until this merges.**

### Phase 1 — Eight parallel tracks

| Track | Scope | Owns |
|---|---|---|
| **A** | TBA import, event setup, role management | `convex/tba.ts`, `convex/events.ts`, `convex/profiles.ts`, `src/routes/admin/*` |
| **B** | Pit scouting: grid landing, form, photo upload | `convex/pit.ts`, `src/routes/pit/*` |
| **C** | Match scouting: landing, selector, claim, form | `convex/claims.ts`, `convex/matchReports.ts`, `src/routes/scout/*` |
| **D** | Field map pathing component (isolated) — **built** | `src/components/field-map/*` |
| **E** | Team list, detail modal, dashboard | `convex/teams.ts`, `src/routes/teams/*`, `src/routes/dashboard.tsx` |
| **F** | Pick list landing + Kanban board + dnd + sorting | `convex/pickLists.ts`, `src/routes/picklists/*` |
| **G** | Consensus merge algorithm + admin merge UI | `convex/merge.ts`, `src/lib/consensus.ts`, `src/routes/admin/merge.tsx` |
| **H** | Compare view, match preview, coverage/QA, CSV export | `convex/stats.ts` *(extensions)*, `convex/exports.ts`, `src/routes/matches/*`, `src/routes/teams/compare.tsx`, `src/routes/admin/data.tsx` |
| **I** | Inactive events — browse archived event data (§11) | Built. Isolated read-only version; see §11.2 |
| **J** | Match assignments — shifts, batch assign, scout-facing views (§12) | Specced |

Dependencies, and how each is defused:

- **C needs D's type, not D's code.** D ships a stub renderer in hour one; C
  never blocks.
- **E, F and G all consume `stats.forEvent`** — which is why it's Phase 0 work.
- **Everyone needs data before A lands.** A's *first* deliverable is the fixture
  seed script, not the TBA action, so five tracks develop against fixtures from
  day one.
- **G is pure logic.** `consensus.ts` is a pure function from lists to a ranked
  table — unit-testable with no UI and no database. Best-isolated track in the
  build.
- **H reads only.** It writes no tables, so it cannot corrupt anything, but it
  extends `convex/stats.ts` which Phase 0 created — H owns that file after the
  freeze and nobody else edits it.

### Phase 2 — Integration. Sequential again.

Mobile QA on real phones · merge tuning against real scout lists · the §5.3
offline decision · load a real event end to end · a practice run with actual
scouts before you depend on it at a competition.

---

## 9. Things that will bite

**dnd-kit on touch.** Use `@dnd-kit/core` 6.x + `@dnd-kit/sortable` 10.x, not
`@dnd-kit/react` (still pre-1.0). Configure `TouchSensor` with an activation
constraint — without a delay, every attempt to scroll the board starts a drag.
Most common reason kanban boards feel broken on phones.

**Sorting Uncategorized must not destroy manual order.** §6 wants sort by fuel,
climb, defense, driver. Treat sort as a *view* (Zustand: `sortKey` +
`direction`), not a rewrite of `order`. Otherwise one tap on "sort by fuel"
silently discards someone's afternoon of manual ranking.

**shadcn is on Base UI.** `render`, not `asChild`. Every track will get this
wrong at least once.

**Claims need a TTL.** A scout who opens the form and wanders off must not lock
that robot forever. 20-minute expiry, released on submit, expired claims are free
to take. Convex mutations are serializable, so the `by_match_team` check is
genuinely race-free — no extra locking needed.

**Compress photos client-side.** Pit photos from a modern phone camera will
otherwise eat the venue's bandwidth for everyone.

**Spec inconsistency:** §6 says sort by "average climb result", §3 says "average
total climb points". Assuming the same metric; using climb points.

**Trench clearance is 22in**, not the 40.25in that appears in some manual
excerpts — that figure is the structure's overall height, not the opening a
robot drives through.

**Averages must exclude uncounted fuel by default.** "Average total fuel" is a
pick-list sort key, and a robot padded by dead-hub scoring will rank above a
better one if uncounted fuel is silently included. Surface both numbers on the
team detail view, sort on the counted one.

---

## 10. Skills to write

- **`scouting-domain`** — schema (§3), contract (§4), naming conventions. Stops
  eight agents inventing eight shapes for a match report.
- **`convex-patterns`** — query vs mutation vs action, argument validators,
  indexes over filters, `internalMutation`. Convex has real footguns for agents
  trained on REST backends.
- **`shadcn-baseui`** — the `render` prop rule. It's in `AGENTS.md`, but a
  loadable skill survives being summarised out of a long context.

---

## 11. Track I — Inactive events

A tab for reading data from events that are no longer active. Deferred until
after F and G, for reasons below.

### 11.1 Why this is not "just add an eventId argument"

RESOLVED 3 made every read query resolve the active event **server-side**, with
no `eventId` argument. That was the right call — it removed an argument from
every call site and made it impossible to read the wrong event by accident. It
is also exactly what makes this track awkward: the naive implementation is to
thread `eventId` through `teams.listWithStatus`, `teams.detail`,
`matches.listForEvent`, `stats.forEvent`, `stats.compare`, `stats.forMatch`,
`stats.coverage` and `exports.csv` — files owned by three different tracks.

**This track therefore cannot own a disjoint file set**, which is the property
that made the other seven safe to run in parallel. It needs a coordinated pass
over shared read queries. Schedule it alone, not alongside another track.

### 11.2 Design: global viewing mode, gated on entry, dropped on exit

Viewing mode retargets the **whole app** at one inactive event, so every screen
already built — teams, detail, matches, preview, compare — works on archived
data with no new UI. The risk that carries is someone forgetting which event
they are looking at. Three mechanics contain it:

**Entry is an explicit choice.** Opening the tab shows a dialog naming the event
and stating that the app will show archived data. Confirm, or be redirected back
where they came from. There is no way into the mode by wandering.

**Exit is automatic.** Leaving the tab clears it. The natural way to leave is
clicking another nav item, which is exactly the moment the mode must drop — so
this is a cleanup effect on unmount of the archive route, not a button someone
has to remember to press.

**It is always visible while on.** A persistent banner across the top of every
page — not a badge, not a subtle tint — naming the event and offering one tap to
exit. Reload while in the mode resets it, since the state is ephemeral, and the
entry gate appears again.

```ts
// src/stores/ui-store.ts — ephemeral by design: it must not survive a reload
viewingEventKey: string | null;
setViewingEventKey: (key: string | null) => void;
```

**Write surfaces disappear while the mode is on.** Pit and match scouting are
removed from the nav and their routes redirect to the archive. Somebody would
otherwise open a scouting form showing archived context and file a report into
the live event.

**The backend guarantee stands regardless.** Every mutation continues to resolve
`activeEvent` server-side and never accepts an event argument. Viewing mode is a
client-side read scope and nothing else. This is the layer that has to hold: a
UI that hides the forms is not the same as a backend that cannot write to an
archive, and the failure mode is data that looks fine and is silently worthless.

Read queries gain an **optional** `eventKey`. Omitting it behaves exactly as
today, so the change lands incrementally, one query at a time:

```ts
// convex/lib/guards.ts
export async function scopedEvent(ctx: QueryCtx, eventKey?: string) {
  if (!eventKey) return await activeEvent(ctx);          // unchanged behaviour
  return await ctx.db.query("events")
    .withIndex("by_key", (q) => q.eq("tbaEventKey", eventKey)).unique();
}
```

### 11.3 Surfaces

In scope: team list, team detail, matches, match preview, compare, coverage,
CSV export. Each is already read-only, so each needs the scope argument and
nothing else.

Out of scope for a first version: pick lists and the merge. They are live
working tools rather than records, and an archived pick list raises questions
(can it be copied forward? does the merge see it?) that are not worth answering
before F and G exist.

### 11.4 Resolved

> **RESOLVED I-1 — Per-event browsing, not season history.** The archive shows
> one inactive event at a time using the existing screens. A team's record does
> not span events. This keeps the track to a scope argument on read queries; the
> cross-event version would have been a data model change, since the same team
> at two events is two unrelated rows joined only by team number.

> **RESOLVED I-2 — Everyone can read archives.** No role gate.

> **RESOLVED I-4 — Reload re-shows the gate.** The scope lives only in the
> Zustand store, never in the URL. A refresh drops it and the entry dialog
> appears again. This costs the reader their place and buys two things: no
> shareable link can drop someone into viewing mode without seeing the gate, and
> a stale tab left open overnight cannot come back still pointed at an archive.

> **RESOLVED I-3 — Purge the previous season at kickoff.** Event keys are
> year-prefixed (`2026gadal`), so "last season" is derivable from the key with
> no date arithmetic and no calendar to keep updated.

### 11.4.1 Season purge — the part that needs care

This is the one operation in the app that destroys scouting data, and it
deliberately contradicts a guard built earlier: `events.remove` refuses to
delete any event holding reports, with no force flag, because a destructive
override on a shared tool during competition is a trap. A season purge is
exactly that operation, so it needs its own path rather than a bypass on the
existing one.

Three properties it should have:

**Admin-initiated, never automatic.** A cron that deletes a season's data on a
date is a cron that will one day run against an event somebody was still using.
The app should *notice* kickoff and prompt — a banner on `/admin` saying "12
events from 2026 are eligible to remove" — and a human should press the button.

**Export before delete, enforced.** The purge flow should require a CSV download
of every affected event first, not merely suggest one. A season of scouting is
several hundred reports of volunteer effort, and once it is gone it is gone.
Requiring the export makes losing it take two deliberate acts instead of one.

**Named confirmation.** Same pattern as event removal: type the season year to
confirm, with the counts shown — teams, matches, reports, pit reports.

> **RESOLVED I-5 — Eligibility by key prefix.** Once any event with a `2027`
> key exists, `2026` events become eligible for purge. No date logic, no
> calendar to maintain, and it fails safe: nothing is eligible until the next
> season has actually started in this deployment.
>
> ```ts
> const season = (key: string) => Number.parseInt(key.slice(0, 4), 10);
> const newest = Math.max(...events.map((e) => season(e.tbaEventKey)));
> const eligible = events.filter((e) => season(e.tbaEventKey) < newest);
> ```
>
> Note this makes eligibility relative to the newest event *present*, not to the
> real-world year — so a deployment that never imports a 2027 event never purges
> anything, which is the correct failure direction.

### 11.5 Prerequisites

- F and G complete, so the pick list question in §11.3 can be answered.
- `events.setInactive` and `events.remove` already exist, so an event can be
  stood down without loss — that groundwork is done.
- The season purge in §11.4.1 needs a new mutation. It must not be a force flag
  on `events.remove`; that guard is worth keeping absolute.

---

## 12. Track J — Match assignments

Shifts telling a scout which driver station to watch over which range of
matches, and surfacing that where they will actually see it.

### 12.1 Data model

```ts
matchAssignments: defineTable({
  eventId: v.id("events"),
  profileId: v.id("profiles"),
  teamNumber: v.number(),        // the scouting team, for scoping
  fromMatch: v.number(),         // inclusive
  toMatch: v.number(),           // inclusive
  station: v.union(
    v.literal("red1"), v.literal("red2"), v.literal("red3"),
    v.literal("blue1"), v.literal("blue2"), v.literal("blue3"),
  ),
  createdAt: v.number(),
  createdBy: v.id("users"),
})
  .index("by_event_profile", ["eventId", "profileId"])
  .index("by_event_team", ["eventId", "teamNumber"]),
```

Ranges store match **numbers**, not match ids. A schedule revision that
renumbers matches will shift everyone's shifts, which is accepted: a range is a
statement about positions in the schedule, and re-importing a revised schedule
is meant to move things.

`matchClaims` is now unused — it was the one-scout-per-robot lock, superseded
when several reports per robot became the point. Assignments are planned
coverage, not exclusivity, so they do not revive it.

### 12.2 Permissions

Same shape as everything else: a full admin assigns anyone for their team's
active event; a team admin assigns only profiles on their own team. Scoping is
enforced in the mutation via `managesTeam`, not in the UI.

### 12.3 Admin surfaces

**Per scout.** An "Assign matches" button in each row of the Scouts list, left
of the role controls. Opens a dialog with a two-handle range slider bounded by
the event's match count, six driver-station buttons in alliance colours, an
"Add shift" button, and below it that scout's existing shifts — each tinted by
alliance with a trash icon to remove it.

**Batch.** A "Batch assign shifts" button beside "Manage scouts" opens a
searchable multi-select list of scouts. Choosing some and pressing the green
Assign button opens the same shift dialog; "Add shift" writes one shift per
selected scout and closes both windows.

### 12.4 Scout surfaces

**Dashboard.** An "Up next" card showing the next assigned match, its station,
and the resolved team — the shift stores a station, the schedule stores who is
in it, so the scout sees the robot number rather than a code to look up.
Distance is expressed in **matches away**, not minutes: scheduled times drift
badly during an event and only refresh on re-import, so a confident countdown
would be confidently wrong. Below it, their shifts with per-shift progress
counted from their submitted reports in range.

**Match scouting.** Assigned matches carry a green border and a station badge
reading "Blue 2 · yours". Expanding one outlines the assigned robot in green.

### 12.5 Resolved

> **RESOLVED J-1 — Overlaps are blocked.** One scout cannot hold two shifts
> covering the same match, whatever the stations. Switching station mid-event
> means ending one shift and starting another, which is what actually happens
> in the stands. The error must name the conflicting shift or fixing it is
> guesswork.

> **RESOLVED J-2 — Two scouts on one station is allowed.** That is either a
> deliberate cross-check or a mistake the admin can see; either way it is not
> the app's call.

> **RESOLVED J-3 — Highlight, never filter.** Unassigned matches stay open and
> every robot in an assigned match stays tappable. A scout who finishes early
> covering a gap is the behaviour worth having, and filtering would prevent it.

> **RESOLVED J-4 — Match numbers, not ids.** See §12.1.

### 12.6 Risk

The two-handle range slider needs Base UI's Slider to accept an array value.
If it misbehaves, two number inputs are the fallback — the same data, less
polish, and not worth blocking the track over.
