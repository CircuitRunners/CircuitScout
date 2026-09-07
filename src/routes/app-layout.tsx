import { Outlet } from "react-router";
import { AppNav } from "@/components/app-nav";

export function AppLayout() {
  return (
    <div className="flex min-h-svh flex-col">
      <AppNav />
      <main className="mx-auto w-full max-w-6xl flex-1 px-4 py-6">
        <Outlet />
      </main>
    </div>
  );
}
