import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";
import { authTables } from "@convex-dev/auth/server";

const lane = v.union(
  v.literal("trench-left"), v.literal("bump-left"),
  v.literal("bump-right"), v.literal("trench-right"),
);

const startPosition = v.union(lane, v.literal("hub"));

const autoPath = v.object({
  start: v.union(startPosition, v.null()),
  steps: v.optional(v.array(v.union(
    v.object({ kind: v.literal("neutral"), outbound: lane, inbound: v.union(lane, v.null()) }),
    v.object({ kind: v.literal("depot") }),
    v.object({ kind: v.literal("outpost") }),
    v.object({ kind: v.literal("climb") }),
  ))),
  // Written before ordering existed. Kept optional so old reports validate.
  cycles: v.optional(v.array(v.object({ outbound: lane, inbound: v.union(lane, v.null()) }))),
  depotPickups: v.optional(v.number()),
  outpostPickups: v.optional(v.number()),
});

const byShift = v.object({
  transition: v.number(),
  s1: v.number(), s2: v.number(), s3: v.number(), s4: v.number(),
});

const tier = v.union(
  v.literal("t1"), v.literal("t2"), v.literal("t3"),
  v.literal("dnp"), v.literal("uncategorized"),
);

export default defineSchema({
  ...authTables,

  profiles: defineTable({
    userId: v.id("users"),
    displayName: v.string(),   // derived: "Sandy A. (1002)"
    firstName: v.optional(v.string()),
    lastInitial: v.optional(v.string()),
    teamNumber: v.optional(v.number()),
    role: v.union(v.literal("admin"), v.literal("teamAdmin"), v.literal("scout")),
    weightTier: v.union(v.literal("lead"), v.literal("trusted"), v.literal("normal")),
    createdAt: v.number(),
  }).index("by_user", ["userId"]),

  /**
   * Someone claiming a team number. Recorded rather than applied silently:
   * a scout typing 1002 is asserting membership, and the team gets to decide.
   */
  teamJoins: defineTable({
    profileId: v.id("profiles"),
    userId: v.id("users"),
    displayName: v.string(),
    teamNumber: v.number(),
    previousTeamNumber: v.union(v.number(), v.null()),
    at: v.number(),
    status: v.union(v.literal("pending"), v.literal("accepted"), v.literal("rejected")),
  })
    .index("by_profile", ["profileId"])
    .index("by_team_status", ["teamNumber", "status"]),

  /** Someone leaving a team, for the team they left. */
  teamDepartures: defineTable({
    profileId: v.id("profiles"),
    displayName: v.string(),
    fromTeamNumber: v.number(),
    toTeamNumber: v.number(),
    at: v.number(),
    dismissed: v.boolean(),
  }).index("by_team_dismissed", ["fromTeamNumber", "dismissed"]),

  events: defineTable({
    tbaEventKey: v.string(),
    name: v.string(),
    isActive: v.boolean(),
    importedAt: v.union(v.number(), v.null()),
    importedBy: v.union(v.id("users"), v.null()),
    /** Set when deleted. The event and its data survive until a cron purges
     *  them, so a mistake is recoverable for 24 hours. */
    deletedAt: v.optional(v.union(v.number(), v.null())),
    deletedBy: v.optional(v.union(v.id("users"), v.null())),
  })
    .index("by_key", ["tbaEventKey"])
    .index("by_active", ["isActive"]),

  /**
   * Which event each FRC team is currently scouting. Teams share the pool of
   * imported events but choose independently — two teams at different
   * competitions use one deployment without stepping on each other.
   */
  teamSettings: defineTable({
    teamNumber: v.number(),
    activeEventId: v.union(v.id("events"), v.null()),
    updatedAt: v.number(),
    updatedBy: v.id("users"),
  }).index("by_team", ["teamNumber"]),

  /**
   * Statbotics EPA for one team at one event. Kept in its own table rather
   * than on teams, so a refresh never touches imported TBA data and a failed
   * fetch leaves the roster intact.
   */
  teamEpa: defineTable({
    eventId: v.id("events"),
    teamNumber: v.number(),
    epa: v.number(),
    autoEpa: v.union(v.number(), v.null()),
    teleopEpa: v.union(v.number(), v.null()),
    endgameEpa: v.union(v.number(), v.null()),
    fetchedAt: v.number(),
    /** Raw JSON for one team, so a wrong field path is diagnosable. */
    sample: v.optional(v.string()),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamNumber"]),

  teams: defineTable({
    eventId: v.id("events"),
    tbaTeamKey: v.string(),
    number: v.number(),
    nickname: v.string(),
    city: v.string(),
    stateProv: v.string(),
    country: v.string(),
  })
    .index("by_event", ["eventId"])
    .index("by_event_number", ["eventId", "number"]),

  matches: defineTable({
    eventId: v.id("events"),
    tbaMatchKey: v.string(),
    matchNumber: v.number(),
    redTeamNumbers: v.array(v.number()),
    blueTeamNumbers: v.array(v.number()),
    scheduledTime: v.union(v.number(), v.null()),
    // From TBA. Optional because rows imported before this existed have none.
    predictedTime: v.optional(v.union(v.number(), v.null())),
    actualTime: v.optional(v.union(v.number(), v.null())),
    redScore: v.optional(v.union(v.number(), v.null())),
    blueScore: v.optional(v.union(v.number(), v.null())),
    winningAlliance: v.optional(v.string()),
  })
    .index("by_event", ["eventId"])
    .index("by_event_number", ["eventId", "matchNumber"]),

  /**
   * A shift: watch this driver station for this run of matches. Ranges store
   * match NUMBERS, so re-importing a revised schedule moves shifts with it.
   */
  matchAssignments: defineTable({
    eventId: v.id("events"),
    profileId: v.id("profiles"),
    teamNumber: v.number(),
    fromMatch: v.number(),
    toMatch: v.number(),
    station: v.union(
      v.literal("red1"), v.literal("red2"), v.literal("red3"),
      v.literal("blue1"), v.literal("blue2"), v.literal("blue3"),
    ),
    createdAt: v.number(),
    createdBy: v.id("users"),
  })
    .index("by_event_profile", ["eventId", "profileId"])
    .index("by_event_team", ["eventId", "teamNumber"]),

  pitReports: defineTable({
    eventId: v.id("events"),
    teamId: v.id("teams"),
    scoutId: v.id("users"),
    /** Which FRC team scouted this pit. Optional for rows written before
     *  pit reports were scoped per team. */
    scoutingTeamNumber: v.optional(v.number()),
    updatedAt: v.number(),
    scoring: v.object({
      turret: v.boolean(),
      drumNonFullWidth: v.boolean(),
      drumFullWidth: v.boolean(),
      fixed: v.boolean(),
      kitbot: v.boolean(),
      other: v.boolean(),
      otherText: v.string(),
    }),
    climb: v.object({
      low: v.boolean(), mid: v.boolean(), high: v.boolean(),
      duringAuto: v.boolean(),
    }),
    drivetrain: v.string(),
    underTrench: v.boolean(),
    overBump: v.boolean(),
    robotNotes: v.string(),
    otherNotes: v.string(),
    photoId: v.union(v.id("_storage"), v.null()),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"]),

  matchReports: defineTable({
    eventId: v.id("events"),
    matchId: v.id("matches"),
    teamId: v.id("teams"),
    scoutId: v.id("users"),
    submittedAt: v.number(),
    updatedAt: v.number(),

    auto: v.object({
      path: autoPath,
      climbL1: v.boolean(),
      fuel: v.number(),
      fouls: v.number(),
      notes: v.string(),
    }),
    teleop: v.object({
      byShift,                       // raw, reclassifiable
      passedNeutral: v.number(),
      passedFullField: v.number(),
      stoleFuel: v.number(),
      defended: v.boolean(),
      notes: v.string(),
    }),
    endgame: v.object({
      climb: v.union(v.literal("none"), v.literal("low"),
                     v.literal("mid"), v.literal("high")),
      fuel: v.number(),
      passedNeutral: v.number(),
      passedFullField: v.number(),
      notes: v.string(),
    }),
    ratings: v.object({
      driver: v.number(), defense: v.number(), accuracy: v.number(),
      shootsOnMove: v.boolean(),
      broke: v.boolean(), brokeNotes: v.string(),
      inconsistent: v.boolean(), inconsistentNotes: v.string(),
    }),

    avgBps: v.optional(v.number()),   // observed balls per second
    finalNotes: v.optional(v.string()),
    matchStartedAt: v.union(v.number(), v.null()),
    autoWinner: v.union(v.literal("red"), v.literal("blue"), v.null()),
    autoWinnerFlagged: v.boolean(),
    hubStateSource: v.union(v.literal("timed"), v.literal("estimated"), v.literal("none")),
  })
    .index("by_event", ["eventId"])
    .index("by_event_team", ["eventId", "teamId"])
    .index("by_match", ["matchId"])
    .index("by_scout", ["scoutId"]),

  reportEdits: defineTable({
    reportId: v.id("matchReports"),
    editedBy: v.id("users"),
    editedAt: v.number(),
    reason: v.string(),
  }).index("by_report", ["reportId"]),

  /**
   * Deleting a report also deletes its edit trail, so the reason and a full
   * snapshot are recorded here instead. A gap nobody can account for is worse
   * than a bad number that was explained.
   */
  deletionLog: defineTable({
    eventId: v.id("events"),
    kind: v.union(v.literal("matchReport"), v.literal("pitReport")),
    teamNumber: v.number(),
    matchNumber: v.union(v.number(), v.null()),
    scoutName: v.string(),
    deletedBy: v.id("users"),
    deletedAt: v.number(),
    reason: v.string(),
    snapshot: v.string(),
    // The team whose admin deleted it — distinct from teamNumber above,
    // which is the team the report was ABOUT.
    ownerTeamNumber: v.optional(v.number()),
  }).index("by_event", ["eventId"]),

  /**
   * A dismissed flag. Scoped to one reason on one report, and compared against
   * the report's updatedAt on read — a dismissal made before an edit does not
   * silence a flag the edit caused.
   */
  flagDismissals: defineTable({
    reportId: v.id("matchReports"),
    reason: v.string(),
    note: v.string(),
    dismissedBy: v.id("users"),
    dismissedAt: v.number(),
  })
    .index("by_report", ["reportId"])
    .index("by_report_reason", ["reportId", "reason"]),

  pickLists: defineTable({
    eventId: v.id("events"),
    ownerId: v.union(v.id("users"), v.null()),   // null = a team's primary
    // Which FRC team this list belongs to. Optional so lists created before
    // multi-team support still validate.
    teamNumber: v.optional(v.number()),
    name: v.string(),
    isPrimary: v.boolean(),
    isSubmitted: v.boolean(),                    // max one per scout per event
    createdAt: v.number(),
  })
    .index("by_event", ["eventId"])
    .index("by_event_owner", ["eventId", "ownerId"])
    .index("by_event_submitted", ["eventId", "isSubmitted"]),

  pickListEntries: defineTable({
    pickListId: v.id("pickLists"),
    teamId: v.id("teams"),
    tier,
    order: v.number(),
    note: v.optional(v.string()),
  })
    .index("by_list", ["pickListId"])
    .index("by_list_tier", ["pickListId", "tier"]),
});
