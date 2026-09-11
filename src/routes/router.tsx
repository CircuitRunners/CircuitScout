import { createBrowserRouter } from "react-router";

import { AppLayout } from "./app-layout";
import { AuthLayout } from "./auth-layout";
import { RequireAdmin, RequireAuth } from "./require-auth";
import { RootLayout } from "./root-layout";

import DashboardPage from "./dashboard";
import ArchivePage from "./archive/index";
import ArchiveEventPage from "./archive/event";
import ProfilePage from "./profile";
import NotFoundPage from "./not-found";
import SignInPage from "./sign-in";
import PitLandingPage from "./pit/index";
import PitFormPage from "./pit/form";
import ScoutLandingPage from "./scout/index";
import MatchFormPage from "./scout/form";
import TeamsPage from "./teams/index";
import ComparePage from "./teams/compare";
import PlotPage from "./teams/plot";
import MatchesPage from "./matches/index";
import MatchPreviewPage from "./matches/preview";
import PickListsPage from "./picklists/index";
import PickListBoardPage from "./picklists/board";
import AdminPage from "./admin/index";
import AdminDataPage from "./admin/data";
import AdminMergePage from "./admin/merge";

export const router = createBrowserRouter([
  {
    path: "/",
    element: <RootLayout />,
    children: [
      {
        element: <AuthLayout />,
        children: [{ path: "sign-in", element: <SignInPage /> }],
      },
      {
        element: <RequireAuth />,
        children: [
          {
            element: <AppLayout />,
            children: [
              { index: true, element: <DashboardPage /> },
              { path: "profile", element: <ProfilePage /> },

              { path: "pit", element: <PitLandingPage /> },
              { path: "pit/:teamNumber", element: <PitFormPage /> },

              { path: "scout", element: <ScoutLandingPage /> },
              { path: "scout/:matchNumber/:teamNumber", element: <MatchFormPage /> },

              { path: "teams", element: <TeamsPage /> },
              { path: "teams/compare", element: <ComparePage /> },
              { path: "teams/plot", element: <PlotPage /> },

              { path: "matches", element: <MatchesPage /> },
              { path: "archive", element: <ArchivePage /> },
              { path: "archive/:eventKey", element: <ArchiveEventPage /> },
              { path: "matches/:matchNumber", element: <MatchPreviewPage /> },

              { path: "picklists", element: <PickListsPage /> },
              { path: "picklists/:listId", element: <PickListBoardPage /> },

              {
                element: <RequireAdmin />,
                children: [
                  { path: "admin", element: <AdminPage /> },
                  { path: "admin/data", element: <AdminDataPage /> },
                  { path: "admin/merge", element: <AdminMergePage /> },
                ],
              },
            ],
          },
        ],
      },
      { path: "*", element: <NotFoundPage /> },
    ],
  },
]);
