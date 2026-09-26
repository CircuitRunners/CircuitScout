import type { ComponentType } from "react";

import { useSeason } from "@/lib/season";
import { PageShell } from "@/routes/page-shell";

// 2026: the pages as they were, unchanged.
import Dashboard2026 from "./dashboard";
import PitLanding2026 from "./pit/index";
import PitForm2026 from "./pit/form";
import ScoutLanding2026 from "./scout/index";
import MatchForm2026 from "./scout/form";
import Teams2026 from "./teams/index";
import Compare2026 from "./teams/compare";
import Plot2026 from "./teams/plot";
import MatchesPage from "./matches/index";
import MatchPreview2026 from "./matches/preview";
import PickListsPage from "./picklists/index";
import PickListBoard2026 from "./picklists/board";
import AdminData2026 from "./admin/data";
import {
  DeletionLog, FlaggedReports, ManageReports, PitReportsAdmin, TeamsNeedingAttention,
} from "./admin/reports-admin";

// Notes: for any season without its own forms.
import NotesDashboard from "./notes/dashboard";
import NotesPitLanding from "./notes/pit";
import NotesPitForm from "./notes/pit-form";
import NotesScoutLanding from "./notes/scout";
import NotesScoutForm from "./notes/scout-form";
import NotesTeams from "./notes/teams";
import NotesMatch from "./notes/match";
import NotesPickListBoard from "./notes/board";
import NotesAdminReports from "./notes/admin-notes";
import { NotAvailable } from "./notes/not-available";

export type SeasonPageKey =
  | "dashboard" | "pit" | "pitForm" | "scout" | "scoutForm"
  | "teams" | "teamsCompare" | "teamsPlot" | "matches" | "matchPreview"
  | "pickLists" | "pickListBoard" | "adminData" | "adminReports";

type SeasonPages = Record<SeasonPageKey, ComponentType>;

function Reports2026() {
  return (
    <>
      <TeamsNeedingAttention />
      <FlaggedReports />
      <ManageReports />
      <PitReportsAdmin />
      <DeletionLog />
    </>
  );
}

const PAGES_2026: SeasonPages = {
  dashboard: Dashboard2026,
  pit: PitLanding2026,
  pitForm: PitForm2026,
  scout: ScoutLanding2026,
  scoutForm: MatchForm2026,
  teams: Teams2026,
  teamsCompare: Compare2026,
  teamsPlot: Plot2026,
  matches: MatchesPage,
  matchPreview: MatchPreview2026,
  pickLists: PickListsPage,
  pickListBoard: PickListBoard2026,
  adminData: AdminData2026,
  adminReports: Reports2026,
};

const PAGES_NOTES: SeasonPages = {
  dashboard: NotesDashboard,
  pit: NotesPitLanding,
  pitForm: NotesPitForm,
  scout: NotesScoutLanding,
  scoutForm: NotesScoutForm,
  teams: NotesTeams,
  teamsCompare: () => <NotAvailable title="Compare" />,
  teamsPlot: () => <NotAvailable title="Plot" />,
  // The match list and the list of pick lists hold no scouting data, so
  // both seasons share them.
  matches: MatchesPage,
  matchPreview: NotesMatch,
  pickLists: PickListsPage,
  pickListBoard: NotesPickListBoard,
  adminData: () => <NotAvailable title="Coverage and quality" />,
  adminReports: NotesAdminReports,
};

/**
 * Seasons that have their own forms. Once a year's pages are built, add it
 * here; every event of that year switches to them. Any year not listed is
 * scouted with notes.
 */
const SEASONS: Partial<Record<number, SeasonPages>> = {
  2026: PAGES_2026,
};

function pagesFor(year: number | null): SeasonPages {
  // No active event: the 2026 pages, which already say so in their own words.
  if (year === null) return PAGES_2026;
  return SEASONS[year] ?? PAGES_NOTES;
}

/** A route element: whichever season's version of `page` the active event uses. */
export function SeasonPage({ page }: { page: SeasonPageKey }) {
  const { loading, year } = useSeason();
  if (loading) return <PageShell title="Loading…" />;
  const Page = pagesFor(year)[page];
  // Keyed by season, so switching events never carries one season's state
  // into the other's page.
  return <Page key={year ?? "none"} />;
}

/** The report tools at the bottom of the Admin page. */
export function SeasonAdminReports() {
  const { loading, year } = useSeason();
  if (loading) return null;
  const Reports = pagesFor(year).adminReports;
  return <Reports key={year ?? "none"} />;
}
