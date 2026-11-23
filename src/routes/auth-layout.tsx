import { CloudOff } from "lucide-react";
import { Navigate, Outlet } from "react-router";

import { useGate } from "@/lib/offline/use-gate";

export function AuthLayout() {
  const gate = useGate();

  if (gate === "loading") return null;
  // "offline" is this device's cached login: straight into the app, as a
  // confirmed session would be.
  if (gate === "live" || gate === "offline") return <Navigate to="/" replace />;

  return (
    <div className="flex min-h-svh items-center justify-center p-6">
      <div className="w-full max-w-sm">
        {gate === "connect-first" ? (
          <p
            role="status"
            className="bg-destructive mb-4 flex items-center gap-2 rounded-md px-3 py-2 text-sm font-medium text-white"
          >
            <CloudOff className="size-4 shrink-0" aria-hidden />
            You are offline. Signing in needs a connection.
          </p>
        ) : null}
        <Outlet />
      </div>
    </div>
  );
}
