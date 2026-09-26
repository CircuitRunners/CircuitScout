import { createBrowserRouter } from "react-router";

import { AppLayout } from "./app-layout";
import { AuthLayout } from "./auth-layout";
import { RequireAdmin, RequireAuth } from "./require-auth";
import { RootLayout } from "./root-layout";
import { SeasonPage } from "./seasons";

import ArchivePage from "./archive/index";
import ArchiveEventPage from "./archive/event";
import ProfilePage from "./profile";
import NotFoundPage from "./not-found";
import SignInPage from "./sign-in";
import AdminPage from "./admin/index";
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
              { index: true, element: <SeasonPage page="dashboard" /> },
              { path: "profile", element: <ProfilePage /> },

              { path: "pit", element: <SeasonPage page="pit" /> },
              { path: "pit/:teamNumber", element: <SeasonPage page="pitForm" /> },

              { path: "scout", element: <SeasonPage page="scout" /> },
              { path: "scout/:matchNumber/:teamNumber", element: <SeasonPage page="scoutForm" /> },

              { path: "teams", element: <SeasonPage page="teams" /> },
              { path: "teams/compare", element: <SeasonPage page="teamsCompare" /> },
              { path: "teams/plot", element: <SeasonPage page="teamsPlot" /> },

              { path: "matches", element: <SeasonPage page="matches" /> },
              { path: "archive", element: <ArchivePage /> },
              { path: "archive/:eventKey", element: <ArchiveEventPage /> },
              { path: "matches/:matchNumber", element: <SeasonPage page="matchPreview" /> },

              { path: "picklists", element: <SeasonPage page="pickLists" /> },
              { path: "picklists/:listId", element: <SeasonPage page="pickListBoard" /> },

              {
                element: <RequireAdmin />,
                children: [
                  { path: "admin", element: <AdminPage /> },
                  { path: "admin/data", element: <SeasonPage page="adminData" /> },
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
