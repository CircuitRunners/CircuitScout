import { Outlet } from "react-router";
import { AppNav } from "@/components/app-nav";
import { OfflineBanner } from "@/components/offline-banner";
import { PracticeBanner } from "@/components/practice-banner";
import { ViewOnlyNotice } from "@/components/view-only-notice";
import { SeasonProvider } from "@/components/season-provider";

export function AppLayout() {
  return (
    <div className="flex min-h-svh flex-col">
      {/* Sticky together, so the banner stays on screen with the nav. */}
      <div className="sticky top-0 z-40">
        <PracticeBanner />
        <AppNav />
        <OfflineBanner />
        <ViewOnlyNotice />
      </div>
      <main className="mx-auto w-full max-w-6xl flex-1 px-4 py-6">
        <SeasonProvider>
          <Outlet />
        </SeasonProvider>
      </main>
      <footer className="text-muted-foreground py-3 text-center text-xs">
        Created by Tarun A, FRC 1002
      </footer>
    </div>
  );
}
