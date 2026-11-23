import type { ReactNode } from "react";
import { ConvexAuthProvider } from "@convex-dev/auth/react";
import { ConvexReactClient } from "convex/react";
import { ThemeProvider } from "next-themes";

import { OfflineProvider } from "@/lib/offline/offline-provider";

const convexUrl = import.meta.env.VITE_CONVEX_URL;

if (!convexUrl) {
  throw new Error(
    "VITE_CONVEX_URL is missing. Run `bunx convex dev` to provision a deployment.",
  );
}

const convex = new ConvexReactClient(convexUrl);

export function AppProviders({ children }: { children: ReactNode }) {
  return (
    <ThemeProvider
      attribute="class"
      defaultTheme="system"
      enableSystem
      disableTransitionOnChange
    >
      <ConvexAuthProvider client={convex}>
        <OfflineProvider>{children}</OfflineProvider>
      </ConvexAuthProvider>
    </ThemeProvider>
  );
}
