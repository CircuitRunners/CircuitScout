# 2026 FRC Scouting App — Implementation Plan

Built on the framework baseline in `AGENTS.md`. Read that first; it is binding.

---

## 0. Architecture in one paragraph

Convex is the entire backend. No API routes, no server layer, no separate
database. The React SPA subscribes to Convex queries and everything is live by
default — a match report submitted on one phone appears on the pick list board
on another without a refresh. The only outbound network call is to The Blue
Alliance, which happens inside a Convex **action** (actions can `fetch`;
queries and mutations cannot), with the API key in the Convex environment and
never in the client bundle. Zustand holds only what dies with the tab: which
team card is selected, which tab is open, whether the hamburger is out, drag
state mid-drag.

```
 Phone / Desktop (React SPA)
   ├── Convex queries  ──►  live subscriptions (teams, matches, reports, lists)
   ├── Convex mutations ──► transactional writes (claims, reports, tiers)
   └── Convex actions   ──► TBA fetch ──► internalMutation ──► tables
```

---

## 1. Decisions that need your input

These block Phase 0. Everything else I can decide.

**1.1 Climb point values.** The spec asks for "average total climb points" but
never says what a climb is worth. I need L1 / L2 / L3 values, and whether an
auto L1 climb is worth the same as an endgame L1. Until you give numbers I'll
put placeholders in `src/lib/scoring.ts` as the single source of truth so
changing them is a one-line edit, not a hunt.

**1.2 Offline behaviour.** This is the biggest real risk in the whole project
and the spec doesn't address it. Competition venue wifi is famously bad, and
Convex is a websocket-backed live-query system — it degrades gracefully while a
tab stays open (mutations queue, optimistic updates apply), but a cold page
load with no connectivity gets you nothing. Three options:

- **Accept it.** Scouts load the app in the pits on good wifi and keep the tab
  alive all day. Cheapest, and genuinely how a lot of teams operate.
- **PWA shell.** Service worker caches the app shell so a reload works offline;
  data still needs the connection. Moderate effort, big reliability win.
- **Local-first buffer.** Queue match reports in IndexedDB and flush on
  reconnect. Most work, most robust, and it partially violates the
  "Convex is the source of truth" rule — the buffer becomes a second store.

My recommendation is the PWA shell in Phase 2, with a visible connection-status
indicator in the nav from Phase 0 so a scout can *see* when they're offline
before they've keyed in six minutes of match data. Decide before Phase 2.

**1.3 Admin bootstrap.** How does the first admin become an admin? Options:
first registered user is auto-promoted; or a `ADMIN_EMAILS` Convex env var
checked at signup. I'd take the env var — it survives a database wipe and
doesn't create a land-grab race at the start of an event.

**1.4 One event or many?** The spec reads as one event at a time. I'm building
event-scoped tables anyway (every row carries `eventId`) because retrofitting
that later is painful, but I need to know whether the UI has an event switcher
or just an "active event" pointer. Assuming active-event pointer unless told
otherwise.

**1.5 Sorting inconsistency.** §6 says sort Uncategorized by "average climb
result"; §3 says "average total climb points". Assuming they're the same metric
and using climb points.

---

## 2. Data model

Frozen in Phase 0. **Any change after that goes through the coordinator, not a
sub-agent** — this file is the one place where parallel agents can collide.

```ts
// convex/schema.ts
{
  ...authTables,

  profiles: {           // extends the auth user
    userId, displayName, role: "admin" | "scout", createdAt
  } // .index("by_user", ["userId"])

  events: {
    tbaEventKey,        // "2026gadal"
    name, isActive, importedAt, importedBy
  } // .index("by_key", ["tbaEventKey"])

  teams: {
    eventId, tbaTeamKey,   // "frc1002"
    number, nickname, city, stateProv, country
  } // .index("by_event", ["eventId"])
    // .index("by_event_number", ["eventId", "number"])

  matches: {
    eventId, tbaMatchKey,  // "2026gadal_qm1"
    matchNumber,
    redTeamNumbers: number[], blueTeamNumbers: number[],
    scheduledTime: number | null
  } // .index("by_event", ["eventId"])
    // .index("by_event_number", ["eventId", "matchNumber"])

  matchClaims: {         // enforces one scout per robot per match
    eventId, matchId, teamId, scoutId, claimedAt, expiresAt
  } // .index("by_match_team", ["matchId", "teamId"])
    // .index("by_scout", ["scoutId"])

  pitReports: {
    eventId, teamId, scoutId, updatedAt,
    scoring: { turret, drumNonFullWidth, drumFullWidth, fixed,
               kitbot, other: boolean, otherText: string | null },
    climb:   { low, mid, high, duringAuto: boolean },
    drivetrain: string,
    underTrench: boolean, overBump: boolean,
    robotNotes: string, otherNotes: string,
    photoId: Id<"_storage"> | null
  } // .index("by_event_team", ["eventId", "teamId"])

  matchReports: {
    eventId, matchId, teamId, scoutId, submittedAt,
    auto: {
      cycles: AutoCycle[],   // see §4
      climbL1: boolean, fuel: number, fouls: number, notes: string
    },
    teleop: {
      fuel, passedNeutral, passedFullField, stoleFuel: number,
      defended: boolean, notes: string
    },
    endgame: {
      climb: "none" | "low" | "mid" | "high",
      fuel, passedNeutral, passedFullField: number, notes: string
    },
    ratings: {
      driver, defense, accuracy: number,   // 1-10
      shootsOnMove: boolean,
      broke: boolean, brokeNotes: string,
      inconsistent: boolean, inconsistentNotes: string
    }
  } // .index("by_event_team", ["eventId", "teamId"])
    // .index("by_match", ["matchId"])
    // .index("by_scout", ["scoutId"])

  pickLists: {
    eventId, ownerId: Id<"users"> | null,  // null = team primary
    name, isPrimary: boolean, createdAt
  } // .index("by_event_owner", ["eventId", "ownerId"])

  pickListEntries: {
    pickListId, teamId,
    tier: "t1" | "t2" | "t3" | "dnp" | "uncategorized",
    order: number
  } // .index("by_list", ["pickListId"])
    // .index("by_list_tier", ["pickListId", "tier"])
}
```

Two notes on shape. `pickListEntries` uses a float `order` so a drag inserts
between two neighbours without renumbering the column — halve the gap, and
renormalise the column only when the gap gets too small to represent. And
averages are **not** stored. At event scale (~50 teams × ~12 matches = ~600
reports) computing them in a query is free, and denormalised aggregates are the
classic source of "the pick list says 43 but the team page says 41" bugs during
alliance selection. Revisit only if a query actually gets slow.

---

## 3. Function surface

This is the contract between tracks. Agents build against these signatures;
they exist as typed stubs by the end of Phase 0.

**Auth / roles** — `profiles.me`, `profiles.list`, `profiles.setRole` (admin).

**Event setup (admin)** — `events.importFromTBA` (action: fetch
`/event/{key}/teams/simple` and `/event/{key}/matches/simple` with the
`X-TBA-Auth-Key` header, filter matches to `comp_level === "qm"`, then call an
internal mutation to upsert). Idempotent by `tbaTeamKey` / `tbaMatchKey` so a
re-import after a schedule change updates rather than duplicates.
Also `events.active`, `events.setActive`.

**Teams** — `teams.listWithStatus` (team + pit-scouted flag + report count +
tier in the caller's active list), `teams.detail`.

**Stats** — `stats.forEvent` returns `Record<teamId, TeamStats>` in one query.
Written in Phase 0 because two tracks consume it. `TeamStats` = avg auto fuel,
avg teleop fuel, avg endgame fuel, avg total fuel, avg climb points, avg driver
rating, avg defense rating, avg accuracy, report count.

**Pit scouting** — `pit.get`, `pit.upsert`, `pit.generateUploadUrl`.

**Match scouting** — `matches.listForEvent`, `matches.teamsInMatch`,
`claims.claim` (throws if held by another live claim), `claims.release`,
`claims.mine`, `matchReports.submit`, `matchReports.listForTeam`.

**Pick lists** — `pickLists.listMine`, `pickLists.primary`, `pickLists.create`,
`entries.forList`, `entries.move` (tier + order), `merge.preview` (admin, pure
computation, writes nothing), `merge.apply` (admin).

---

## 4. Two components that need design, not just implementation

**4.1 The auto pathing map.** This is the highest-risk item in the build. The
spec wants an interactive 2026 field where a scout taps a start position, then
for each scoring cycle records trench-or-bump out, depot-or-outpost intake,
trench-or-bump back. On a phone, mid-match, in about fifteen seconds.

I'd model the data as a flat, boring array and keep the map purely a *input
skin* over it:

```ts
type AutoCycle = {
  outbound: "trench" | "bump";
  intake: "depot" | "outpost";
  return: "trench" | "bump";
};
type AutoPath = { startPosition: string; cycles: AutoCycle[] };
```

Because the data shape is trivial, **build the non-map version first**: a
stack of repeatable rows with four big segmented buttons each. It's ugly, it
works on day one, and it's what actually gets used if the map isn't ready. The
map then becomes a second renderer over identical state, and if it slips, you
ship anyway. Track D owns the map; Track C consumes `AutoPath` and doesn't care
which renderer produced it.

**4.2 The pick list merge.** "Consensus score" needs a defined algorithm.
Proposal:

Each personal list votes on each team. Tier gives a base score
(T1 = 100, T2 = 70, T3 = 40, DNP = −100). Position within a column adjusts
within a band that can never cross a tier boundary — roughly
`base + 25 × (size − index) / size`. Uncategorized is *not* a zero; it's an
abstention and is excluded from that team's average.

Consensus score is the mean over lists that expressed an opinion. Report
alongside it: **voter count** (a team ranked T1 by one person is not the same as
T1 by six) and **spread** (standard deviation — high spread means the room
disagrees and a human should look). Treat DNP as a veto flag rather than
averaging it away: surface `dnpCount` separately, because one scout who watched
a robot tip over twice is signal that a mean will bury.

`merge.preview` returns the ranked table and writes nothing. An admin reviews
and then `merge.apply` writes into the primary list. **The merge never
silently overwrites the primary list** — during alliance selection an
unexplained reshuffle is worse than no tool at all.

---

## 5. Phases and sub-agent tracks

The parallelism rule: agents own disjoint file sets, and the shared contract
(`convex/schema.ts`, `src/lib/scoring.ts`, `src/lib/types.ts`) is frozen before
anyone starts. Run each track in its own git worktree or branch.

### Phase 0 — Foundation. One agent. Nothing runs in parallel here.

Schema, auth wiring, `profiles` + role checks, `stats.forEvent`,
`scoring.ts` weights, typed stubs for every function in §3, nav shell with
hamburger + landing routes, connection-status indicator, dnd-kit installed.

Exit criteria: `bun run typecheck` clean, every stub callable, schema pushed.
**Do not start Phase 1 until this is merged.**

### Phase 1 — Six parallel tracks.

| Track | Scope | Owns |
|---|---|---|
| **A** | TBA import + event setup screen (admin) | `convex/tba.ts`, `convex/events.ts`, `src/routes/admin/*` |
| **B** | Pit scouting: team grid landing, form, photo upload | `convex/pit.ts`, `src/routes/pit/*` |
| **C** | Match scouting: landing, match/team selector, claim, form | `convex/claims.ts`, `convex/matchReports.ts`, `src/routes/match/*` |
| **D** | Field map pathing component (isolated, prop contract only) | `src/components/field-map/*` |
| **E** | Team list page + team detail modal | `convex/teams.ts`, `src/routes/teams/*` |
| **F** | Pick list board, dnd, sorting, merge | `convex/pickLists.ts`, `convex/merge.ts`, `src/routes/picklist/*` |

Dependencies: C needs D's *type* (`AutoPath`), not D's implementation — D ships
a stub renderer in the first hour and C never blocks. E and F both consume
`stats.forEvent` from Phase 0. A must land before B/C/E/F have real data, so
give A a seed script for fixture data on day one and let the others develop
against fixtures.

### Phase 2 — Integration. Sequential again.

Mobile QA on real phones, merge-algorithm tuning against real scout lists,
offline decision from §1.2, admin polish, load a real event end to end.

---

## 6. Specific things that will bite

**dnd-kit on touch.** Use `@dnd-kit/core` 6.x + `@dnd-kit/sortable` 10.x, not
`@dnd-kit/react` (still pre-1.0). On mobile you must configure `TouchSensor`
with an activation constraint — without a delay, every attempt to scroll the
board starts a drag instead. This is the number one reason kanban boards feel
broken on phones.

**shadcn is on Base UI.** `render`, not `asChild`. It's in `AGENTS.md` and
every track will get it wrong at least once.

**Stepper buttons, not number inputs.** The spec is explicit about ±10 / ±5 /
±1 for fuel. Make one `<Stepper>` component in Phase 0 and have all three
periods use it, or you'll get three subtly different ones.

**Claims need a TTL.** A scout who opens the form and walks away must not lock
that robot forever. 20-minute expiry, released on submit, and a claim that has
expired is claimable by anyone. Convex mutations are serializable, so the unique
`by_match_team` check is genuinely race-free — no extra locking needed.

**Photos are large.** Compress client-side before upload or a pit scouting
session on a phone camera will eat the venue's bandwidth.

---

## 7. Skills to write

Since you're running sub-agents, three skills pay for themselves:

- **`scouting-domain`** — the schema in §2, the function contract in §3, and
  the naming conventions. Prevents six agents inventing six shapes for a match
  report.
- **`convex-patterns`** — query vs mutation vs action, argument validators,
  indexes over filters, when to use `internalMutation`. Convex has real
  footguns for agents trained on REST backends.
- **`shadcn-baseui`** — the `render` prop rule. `AGENTS.md` covers it, but a
  loadable skill survives being summarised out of a long context.
