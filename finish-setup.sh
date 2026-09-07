#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# finish-setup.sh — resume a half-finished scaffold.
#
# Run from the REPO ROOT (the folder with package.json) in Git Bash.
# Safe to re-run: every step overwrites rather than duplicates.
# ---------------------------------------------------------------------------
set -euo pipefail

[[ -f package.json ]] || { echo "ERROR: run this from the folder containing package.json" >&2; exit 1; }

RR7="^7.18.3"
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Step 1/6  Installing dependencies"
bun install
bun add "react-router@${RR7}" convex zustand next-themes lucide-react sonner
bun add "@convex-dev/auth" "@auth/core@^0.41.1"
bun add -d tailwindcss @tailwindcss/vite @types/node

# 3. Build + TS config (must land before shadcn init reads the path aliases)
# ---------------------------------------------------------------------------
say "Step 2/6  Writing Vite + TypeScript config"

cat > vite.config.ts <<'EOF'
import { fileURLToPath, URL } from "node:url";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url)),
    },
  },
  server: { port: 5173 },
});
EOF

cat > tsconfig.json <<'EOF'
{
  "files": [],
  "references": [
    { "path": "./tsconfig.app.json" },
    { "path": "./tsconfig.node.json" }
  ],
  "compilerOptions": {
    "baseUrl": ".",
    "paths": { "@/*": ["./src/*"] }
  }
}
EOF

cat > tsconfig.app.json <<'EOF'
{
  "compilerOptions": {
    "tsBuildInfoFile": "./node_modules/.tmp/tsconfig.app.tsbuildinfo",
    "target": "ES2022",
    "useDefineForClassFields": true,
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "moduleResolution": "bundler",
    "moduleDetection": "force",
    "jsx": "react-jsx",
    "allowImportingTsExtensions": true,
    "verbatimModuleSyntax": true,
    "isolatedModules": true,
    "skipLibCheck": true,
    "noEmit": true,

    "strict": true,
    "noImplicitOverride": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true,
    "noUncheckedIndexedAccess": true,
    "noUncheckedSideEffectImports": true,

    "baseUrl": ".",
    "paths": { "@/*": ["./src/*"] }
  },
  "include": ["src"]
}
EOF

cat > tsconfig.node.json <<'EOF'
{
  "compilerOptions": {
    "tsBuildInfoFile": "./node_modules/.tmp/tsconfig.node.tsbuildinfo",
    "target": "ES2023",
    "lib": ["ES2023"],
    "module": "ESNext",
    "moduleResolution": "bundler",
    "moduleDetection": "force",
    "allowImportingTsExtensions": true,
    "verbatimModuleSyntax": true,
    "isolatedModules": true,
    "skipLibCheck": true,
    "noEmit": true,
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "types": ["node"]
  },
  "include": ["vite.config.ts"]
}
EOF

mkdir -p src
cat > src/vite-env.d.ts <<'EOF'
/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_CONVEX_URL: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
EOF

# Minimal stylesheet; `shadcn init` layers its theme tokens on top of this.
# (Replaces the Vite template's boilerplate CSS outright.)
echo '@import "tailwindcss";' > src/index.css

# ---------------------------------------------------------------------------

say "Step 3/6  shadcn\/ui (Base UI)"
if [[ ! -f components.json ]]; then
  bunx shadcn@latest init -b base -y --css-variables || {
    echo ""
    echo "shadcn init FAILED. Common causes:"
    echo "  * no internet / proxy blocking ui.shadcn.com"
    echo "  * it tried to prompt and could not"
    echo "Fix, then re-run this script. Nothing above is lost."
    exit 1
  }
fi
bunx shadcn@latest add -y \
  sonner button card dialog input textarea select checkbox label \
  dropdown-menu tabs sheet tooltip separator scroll-area

# 5. Convex backend (domain data + auth)
# ---------------------------------------------------------------------------
say "Step 4/6  Writing Convex backend"
mkdir -p convex

cat > convex/tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "allowJs": true,
    "strict": true,
    "target": "ESNext",
    "lib": ["ES2021", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "jsx": "react-jsx",
    "isolatedModules": true,
    "skipLibCheck": true,
    "allowSyntheticDefaultImports": true,
    "forceConsistentCasingInFileNames": true,
    "noEmit": true
  },
  "include": ["./**/*"],
  "exclude": ["./_generated"]
}
EOF

cat > convex/schema.ts <<'EOF'
import { defineSchema } from "convex/server";
import { authTables } from "@convex-dev/auth/server";

// Convex is the source of truth for all persisted application/domain data.
// Domain tables go here alongside the auth tables.
export default defineSchema({
  ...authTables,
});
EOF

cat > convex/auth.config.ts <<'EOF'
export default {
  providers: [
    {
      domain: process.env.CONVEX_SITE_URL,
      applicationID: "convex",
    },
  ],
};
EOF

cat > convex/auth.ts <<'EOF'
import { convexAuth } from "@convex-dev/auth/server";
import { Password } from "@convex-dev/auth/providers/Password";

// Auth runs inside Convex — no separate auth service, no API routes.
// Add OAuth/magic-link providers to this array as needed.
export const { auth, signIn, signOut, store } = convexAuth({
  providers: [Password],
});
EOF

cat > convex/http.ts <<'EOF'
import { httpRouter } from "convex/server";
import { auth } from "./auth";

const http = httpRouter();

auth.addHttpRoutes(http);

export default http;
EOF

cat > convex/users.ts <<'EOF'
import { getAuthUserId } from "@convex-dev/auth/server";
import { query } from "./_generated/server";

export const currentUser = query({
  args: {},
  handler: async (ctx) => {
    const userId = await getAuthUserId(ctx);
    if (userId === null) return null;
    return await ctx.db.get(userId);
  },
});
EOF

# ---------------------------------------------------------------------------
# 6. Application source
# ---------------------------------------------------------------------------
say "Step 5/6  Writing app source"
mkdir -p src/providers src/routes src/stores src/components

rm -f src/App.tsx src/App.css

cat > src/main.tsx <<'EOF'
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { RouterProvider } from "react-router/dom";

import { AppProviders } from "@/providers/app-providers";
import { router } from "@/routes/router";
import "./index.css";

const container = document.getElementById("root");
if (!container) throw new Error("Root element #root not found.");

createRoot(container).render(
  <StrictMode>
    <AppProviders>
      <RouterProvider router={router} />
    </AppProviders>
  </StrictMode>,
);
EOF

cat > src/providers/app-providers.tsx <<'EOF'
import type { ReactNode } from "react";
import { ConvexAuthProvider } from "@convex-dev/auth/react";
import { ConvexReactClient } from "convex/react";
import { ThemeProvider } from "next-themes";

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
      <ConvexAuthProvider client={convex}>{children}</ConvexAuthProvider>
    </ThemeProvider>
  );
}
EOF

cat > src/stores/ui-store.ts <<'EOF'
import { create } from "zustand";

/**
 * Ephemeral, client-only UI state.
 *
 * Allowed here: selection, active tab, panel/sidebar/dialog open state,
 * drag state, transient editor state, local UI preferences.
 *
 * NOT allowed here: anything persisted or owned by Convex. Never mirror a
 * Convex query result into this store — subscribe with `useQuery` instead.
 */
type UIState = {
  sidebarOpen: boolean;
  commandOpen: boolean;
  activeTab: string;
  selectedId: string | null;
  isDragging: boolean;
};

type UIActions = {
  setSidebarOpen: (open: boolean) => void;
  toggleSidebar: () => void;
  setCommandOpen: (open: boolean) => void;
  setActiveTab: (tab: string) => void;
  setSelectedId: (id: string | null) => void;
  setDragging: (dragging: boolean) => void;
  reset: () => void;
};

const initialState: UIState = {
  sidebarOpen: false,
  commandOpen: false,
  activeTab: "overview",
  selectedId: null,
  isDragging: false,
};

export const useUIStore = create<UIState & UIActions>()((set) => ({
  ...initialState,
  setSidebarOpen: (sidebarOpen) => set({ sidebarOpen }),
  toggleSidebar: () => set((state) => ({ sidebarOpen: !state.sidebarOpen })),
  setCommandOpen: (commandOpen) => set({ commandOpen }),
  setActiveTab: (activeTab) => set({ activeTab }),
  setSelectedId: (selectedId) => set({ selectedId }),
  setDragging: (isDragging) => set({ isDragging }),
  reset: () => set(initialState),
}));
EOF

cat > src/components/theme-toggle.tsx <<'EOF'
import { useEffect, useState } from "react";
import { useTheme } from "next-themes";
import { Monitor, Moon, Sun } from "lucide-react";

import { Button } from "@/components/ui/button";

const ORDER = ["light", "dark", "system"] as const;
type ThemeName = (typeof ORDER)[number];

export function ThemeToggle() {
  const { theme, setTheme } = useTheme();
  const [mounted, setMounted] = useState(false);

  useEffect(() => setMounted(true), []);

  const current: ThemeName =
    theme === "light" || theme === "dark" ? theme : "system";

  const next = (): ThemeName => {
    const index = ORDER.indexOf(current);
    return ORDER[(index + 1) % ORDER.length] ?? "system";
  };

  const Icon = current === "light" ? Sun : current === "dark" ? Moon : Monitor;

  return (
    <Button
      variant="ghost"
      size="icon"
      aria-label={`Theme: ${current}. Switch to ${next()}.`}
      onClick={() => setTheme(next())}
    >
      {mounted ? <Icon className="size-4" /> : <span className="size-4" />}
    </Button>
  );
}
EOF

cat > src/routes/router.tsx <<'EOF'
import { createBrowserRouter } from "react-router";

import { AppLayout } from "./app-layout";
import { AuthLayout } from "./auth-layout";
import { RequireAuth } from "./require-auth";
import { RootLayout } from "./root-layout";
import HomePage from "./home";
import NotFoundPage from "./not-found";
import SettingsPage from "./settings";
import SignInPage from "./sign-in";

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
              { index: true, element: <HomePage /> },
              { path: "settings", element: <SettingsPage /> },
            ],
          },
        ],
      },
      { path: "*", element: <NotFoundPage /> },
    ],
  },
]);
EOF

cat > src/routes/root-layout.tsx <<'EOF'
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
EOF

cat > src/routes/require-auth.tsx <<'EOF'
import { useConvexAuth } from "convex/react";
import { Navigate, Outlet, useLocation } from "react-router";
import { LoaderCircle } from "lucide-react";

export function RequireAuth() {
  const { isLoading, isAuthenticated } = useConvexAuth();
  const location = useLocation();

  if (isLoading) {
    return (
      <div className="flex min-h-svh items-center justify-center">
        <LoaderCircle className="text-muted-foreground size-5 animate-spin" />
      </div>
    );
  }

  if (!isAuthenticated) {
    return <Navigate to="/sign-in" replace state={{ from: location.pathname }} />;
  }

  return <Outlet />;
}
EOF

cat > src/routes/auth-layout.tsx <<'EOF'
import { useConvexAuth } from "convex/react";
import { Navigate, Outlet } from "react-router";

export function AuthLayout() {
  const { isLoading, isAuthenticated } = useConvexAuth();

  if (isLoading) return null;
  if (isAuthenticated) return <Navigate to="/" replace />;

  return (
    <div className="flex min-h-svh items-center justify-center p-6">
      <div className="w-full max-w-sm">
        <Outlet />
      </div>
    </div>
  );
}
EOF

cat > src/routes/app-layout.tsx <<'EOF'
import { useAuthActions } from "@convex-dev/auth/react";
import { LogOut } from "lucide-react";
import { NavLink, Outlet } from "react-router";

import { ThemeToggle } from "@/components/theme-toggle";
import { Button } from "@/components/ui/button";
import { Separator } from "@/components/ui/separator";

const NAV = [
  { to: "/", label: "Home", end: true },
  { to: "/settings", label: "Settings", end: false },
];

export function AppLayout() {
  const { signOut } = useAuthActions();

  return (
    <div className="mx-auto flex min-h-svh w-full max-w-5xl flex-col">
      <header className="flex items-center gap-4 px-6 py-4">
        <nav className="flex items-center gap-1">
          {NAV.map((item) => (
            <NavLink
              key={item.to}
              to={item.to}
              end={item.end}
              className={({ isActive }) =>
                [
                  "rounded-md px-3 py-1.5 text-sm transition-colors",
                  isActive
                    ? "bg-accent text-accent-foreground"
                    : "text-muted-foreground hover:text-foreground",
                ].join(" ")
              }
            >
              {item.label}
            </NavLink>
          ))}
        </nav>
        <div className="ml-auto flex items-center gap-1">
          <ThemeToggle />
          <Button
            variant="ghost"
            size="icon"
            aria-label="Sign out"
            onClick={() => void signOut()}
          >
            <LogOut className="size-4" />
          </Button>
        </div>
      </header>
      <Separator />
      <main className="flex-1 px-6 py-8">
        <Outlet />
      </main>
    </div>
  );
}
EOF

cat > src/routes/home.tsx <<'EOF'
import { useQuery } from "convex/react";
import { toast } from "sonner";

import { api } from "../../convex/_generated/api";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useUIStore } from "@/stores/ui-store";

export default function HomePage() {
  // Domain data: live Convex subscription, never copied into Zustand.
  const user = useQuery(api.users.currentUser);

  // Ephemeral UI state: Zustand.
  const activeTab = useUIStore((s) => s.activeTab);
  const setActiveTab = useUIStore((s) => s.setActiveTab);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">
          Framework baseline
        </h1>
        <p className="text-muted-foreground text-sm">
          Signed in as {user?.email ?? "…"}
        </p>
      </div>

      <Tabs value={activeTab} onValueChange={setActiveTab}>
        <TabsList>
          <TabsTrigger value="overview">Overview</TabsTrigger>
          <TabsTrigger value="wiring">Wiring</TabsTrigger>
        </TabsList>

        <TabsContent value="overview" className="pt-4">
          <Card>
            <CardHeader>
              <CardTitle>No product code yet</CardTitle>
              <CardDescription>
                Routing, theming, Convex, auth, toasts and the UI store are
                wired. Add features once product requirements land.
              </CardDescription>
            </CardHeader>
            <CardContent>
              <Button onClick={() => toast.success("Sonner is wired up.")}>
                Fire a toast
              </Button>
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="wiring" className="pt-4">
          <Card>
            <CardHeader>
              <CardTitle>State boundaries</CardTitle>
              <CardDescription>
                The active tab above lives in Zustand. The email above comes
                from a live Convex query.
              </CardDescription>
            </CardHeader>
          </Card>
        </TabsContent>
      </Tabs>
    </div>
  );
}
EOF

cat > src/routes/settings.tsx <<'EOF'
import {
  Card,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";

export default function SettingsPage() {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Settings</CardTitle>
        <CardDescription>
          Placeholder route demonstrating nested layouts under RequireAuth.
        </CardDescription>
      </CardHeader>
    </Card>
  );
}
EOF

cat > src/routes/sign-in.tsx <<'EOF'
import { useState } from "react";
import { useAuthActions } from "@convex-dev/auth/react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

type Flow = "signIn" | "signUp";

export default function SignInPage() {
  const { signIn } = useAuthActions();
  const [flow, setFlow] = useState<Flow>("signIn");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [pending, setPending] = useState(false);

  const submit = async () => {
    setPending(true);
    try {
      const form = new FormData();
      form.set("email", email);
      form.set("password", password);
      form.set("flow", flow);
      await signIn("password", form);
    } catch {
      toast.error(
        flow === "signIn"
          ? "Could not sign in. Check your email and password."
          : "Could not create that account.",
      );
    } finally {
      setPending(false);
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>{flow === "signIn" ? "Sign in" : "Create account"}</CardTitle>
        <CardDescription>Authentication is handled by Convex.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="space-y-2">
          <Label htmlFor="email">Email</Label>
          <Input
            id="email"
            type="email"
            autoComplete="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        </div>
        <div className="space-y-2">
          <Label htmlFor="password">Password</Label>
          <Input
            id="password"
            type="password"
            autoComplete={
              flow === "signIn" ? "current-password" : "new-password"
            }
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
        <Button
          className="w-full"
          disabled={pending || !email || !password}
          onClick={() => void submit()}
        >
          {flow === "signIn" ? "Sign in" : "Sign up"}
        </Button>
        <Button
          variant="link"
          className="w-full"
          onClick={() => setFlow(flow === "signIn" ? "signUp" : "signIn")}
        >
          {flow === "signIn"
            ? "Need an account? Sign up"
            : "Already have an account? Sign in"}
        </Button>
      </CardContent>
    </Card>
  );
}
EOF

cat > src/routes/not-found.tsx <<'EOF'
import { Link } from "react-router";

import { Button } from "@/components/ui/button";

export default function NotFoundPage() {
  return (
    <div className="flex min-h-svh flex-col items-center justify-center gap-4">
      <p className="text-muted-foreground text-sm">
        404 — that route does not exist.
      </p>
      {/* Base UI uses `render`, not Radix's `asChild`. */}
      <Button variant="outline" render={<Link to="/" />}>
        Back home
      </Button>
    </div>
  );
}
EOF

# ---------------------------------------------------------------------------
# 7. Scripts + agent guidance
# ---------------------------------------------------------------------------
mkdir -p scripts

cat > scripts/dev.sh <<'EOF'
#!/usr/bin/env bash
# Install anything missing, make sure Convex is provisioned, run both servers.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v bun >/dev/null 2>&1 || { npm install -g bun; }
[[ -d node_modules ]] || bun install

if [[ ! -f .env.local ]] || ! grep -q VITE_CONVEX_URL .env.local; then
  echo "No Convex deployment configured — launching the Convex setup prompt."
  bunx convex dev --once --configure
fi

bunx convex dev &
CONVEX_PID=$!
trap 'kill "$CONVEX_PID" 2>/dev/null || true' EXIT INT TERM

bun run dev
EOF
chmod +x scripts/dev.sh


say "Step 6/6  Scripts"
cat > /tmp/patch-pkg.mjs <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
const pkg = JSON.parse(readFileSync("package.json", "utf8"));
pkg.scripts = {
  ...pkg.scripts,
  dev: "vite",
  build: "tsc -b --noEmit && vite build",
  preview: "vite preview",
  lint: "eslint .",
  typecheck: "tsc -b --noEmit",
  "convex:dev": "convex dev",
  "convex:deploy": "convex deploy",
  go: "bash scripts/dev.sh",
  start: "bash scripts/dev.sh",
};
writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");
EOF
bun /tmp/patch-pkg.mjs

# Keep generated Convex code out of lint.
cat > /tmp/patch-eslint.mjs <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
const file = ["eslint.config.js", "eslint.config.ts", "eslint.config.mjs"].find(existsSync);
if (file) {
  let src = readFileSync(file, "utf8");
  if (!src.includes("convex/_generated")) {
    src = src.replace(/(\[\s*['"]dist['"])/, "$1, 'convex/_generated'");
    writeFileSync(file, src);
  }
}
EOF
bun /tmp/patch-eslint.mjs || true


rm -rf src/assets

cat <<'DONE'

  Setup complete. Next:

    bunx convex dev --once --configure     # log in, pick your PERSONAL team
    bunx @convex-dev/auth --skip-git-check # generate auth keys
    bunx convex dev --once                 # push schema + functions
    bun run go                             # start everything

DONE
