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

// Statbotics recomputes as matches are played, so this follows the event
// rather than the schedule release. Two hours is often enough to be current
// without hammering a free API.
crons.interval(
  "refresh statbotics and tba",
  { hours: 2 },
  internal.refresh.scheduled,
  {},
);

export default crons;
