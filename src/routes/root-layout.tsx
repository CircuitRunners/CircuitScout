import { Outlet } from "react-router";

import { Toaster } from "@/components/ui/sonner";

export function RootLayout() {
  return (
    <div className="bg-background text-foreground min-h-svh">
      <Outlet />
      <Toaster richColors closeButton />
    </div>
  );
}
