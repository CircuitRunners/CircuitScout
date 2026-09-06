#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# create-app.sh — one command to scaffold, install, wire and run the stack.
#
#   Bun · Vite · React 19 · TypeScript (strict) · React Router 7 (SPA)
#   Tailwind CSS v4 · shadcn/ui (Base UI) · CSS variables · Lucide
#   Convex (data + auth) · Zustand (ephemeral UI state only)
#   next-themes (class strategy) · shadcn Sonner
#
# Usage:
#   bash create-app.sh <project-name> [--team <convex-team-slug>] [--no-run]
#
# Idempotent: if <project-name> already exists it skips scaffolding and just
# installs + runs, so this is safe to use as your everyday "go" command.
# ---------------------------------------------------------------------------
set -euo pipefail

PROJECT_NAME=""
CONVEX_TEAM=""
RUN_AFTER=1
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)    CONVEX_TEAM="${2:-}"; shift 2 ;;
    --no-run)  RUN_AFTER=0; shift ;;
    --force)   FORCE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *)         PROJECT_NAME="$1"; shift ;;
  esac
done

[[ -n "$PROJECT_NAME" ]] || { echo "usage: bash create-app.sh <project-name> [--team <slug>]" >&2; exit 1; }

# React Router 7 must be pinned: the "latest" dist-tag is now 8.x.
RR7="^7.18.3"

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 0. Toolchain
# ---------------------------------------------------------------------------
if ! command -v bun >/dev/null 2>&1; then
  say "Installing Bun"
  if command -v npm >/dev/null 2>&1; then
    npm install -g bun
  else
    curl -fsSL https://bun.sh/install | bash
    export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
    export PATH="$BUN_INSTALL/bin:$PATH"
  fi
fi
say "Bun $(bun --version)"

ALREADY_EXISTS=0
[[ -f "$PROJECT_NAME/package.json" ]] && ALREADY_EXISTS=1

# ---------------------------------------------------------------------------
# 1. Scaffold
# ---------------------------------------------------------------------------
if [[ $ALREADY_EXISTS -eq 0 ]]; then
  say "Scaffolding Vite + React + TypeScript"
  bun create vite "$PROJECT_NAME" --template react-ts \
    || bunx create-vite@latest "$PROJECT_NAME" --template react-ts
fi

cd "$PROJECT_NAME"

# ---------------------------------------------------------------------------
# 2. Dependencies
# ---------------------------------------------------------------------------
say "Installing dependencies"
bun install

if [[ $ALREADY_EXISTS -eq 0 ]]; then
  bun add "react-router@${RR7}" convex zustand next-themes lucide-react sonner
  bun add "@convex-dev/auth" "@auth/core@^0.41.1"
  bun add -d tailwindcss @tailwindcss/vite @types/node
fi

BOOTSTRAP=0
if [[ $ALREADY_EXISTS -eq 0 || $FORCE -eq 1 ]]; then BOOTSTRAP=1; fi

if [[ $BOOTSTRAP -eq 0 ]]; then
  say "Existing project detected — skipping scaffolding (pass --force to rewrite)"
fi

if [[ $BOOTSTRAP -eq 1 ]]; then
# ---------------------------------------------------------------------------
# 3. Build + TS config (must land before shadcn init reads the path aliases)
# ---------------------------------------------------------------------------
say "Writing Vite / TypeScript config"

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
# 4. shadcn/ui on Base UI primitives
# ---------------------------------------------------------------------------
if [[ ! -f components.json ]]; then
  say "Initialising shadcn/ui with Base UI primitives"
  bunx shadcn@latest init -b base -y --css-variables
fi

say "Adding shadcn components"
bunx shadcn@latest add -y \
  sonner button card dialog input textarea select checkbox label \
  dropdown-menu tabs sheet tooltip separator scroll-area

# ---------------------------------------------------------------------------
# 5. Convex backend (domain data + auth)
# ---------------------------------------------------------------------------
say "Writing Convex backend"
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
say "Wiring the app baseline"
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

cat > AGENTS.md <<'EOF'
# Stack rules

Bun · Vite · React 19 · TypeScript (strict) · React Router 7 (SPA, data mode)
Tailwind CSS v4 · shadcn/ui on **Base UI** · CSS variables · Lucide
Convex (data + auth) · Zustand (ephemeral UI only) · next-themes · shadcn Sonner

## Commands
Always `bun`, `bunx`, `bun run` — never npm/pnpm/yarn/npx.

    bun run dev         # Vite only
    bun run go          # Convex + Vite together (use this)
    bun run build
    bun run lint
    bun run typecheck

## State boundary — the rule that matters most
- **Convex** owns everything persisted: domain data, auth, live queries,
  mutations. Read with `useQuery`, write with `useMutation`.
- **Zustand** (`src/stores/ui-store.ts`) owns only ephemeral client UI state:
  selection, active tab, sidebar/panel/dialog open, drag state, transient
  editor state, local UI preferences.
- Never copy a Convex query result into Zustand.
- Never add API routes, server handlers or a backend layer for data that
  belongs in Convex.

## shadcn/ui is on Base UI, not Radix
- `components.json` `style` starts with `base-`. The primitive package is
  `@base-ui/react`.
- **Use the `render` prop, never `asChild`.** This is the #1 mistake:

      // wrong (Radix)
      <DialogTrigger asChild><Button>Open</Button></DialogTrigger>
      // right (Base UI)
      <DialogTrigger render={<Button />}>Open</DialogTrigger>
      <Button render={<Link to="/" />}>Back home</Button>

- Accordion uses `multiple` (boolean), not `type`; `defaultValue` is an array.
- Add components with `bunx shadcn@latest add <name>`. Check API against
  `bunx shadcn@latest docs <name>` — the Base UI docs live under
  `ui.shadcn.com/docs/components/base/*`.
- Never hand-roll a form control that shadcn already ships.
- Toasts: `import { toast } from "sonner"`. The `<Toaster />` from
  `@/components/ui/sonner` is already mounted in `src/routes/root-layout.tsx`.
  Do not write a custom toast wrapper.

## Routing
- React Router **7** (pinned — `latest` on npm is 8.x now).
- Routes are declared in `src/routes/router.tsx` using `createBrowserRouter`.
- Layout hierarchy: `RootLayout` → (`AuthLayout` | `RequireAuth` → `AppLayout`).
- `RouterProvider` imports from `react-router/dom`; everything else from
  `react-router`.

## Theming
- `next-themes` with `attribute="class"`, `defaultTheme="system"`,
  `enableSystem`, `disableTransitionOnChange` — configured in
  `src/providers/app-providers.tsx`.
- Colours come from CSS variables. Use semantic Tailwind tokens
  (`bg-background`, `text-muted-foreground`), not raw palette values.

## TypeScript
Strict, plus `noUnusedLocals`, `noUnusedParameters`, `noUncheckedIndexedAccess`.
No `any`, no `@ts-ignore`. Run `bun run typecheck` before declaring done.

## Scope
Framework only. Do not add product features without explicit requirements.
EOF

say "Patching package.json scripts"
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

fi  # end BOOTSTRAP

# ---------------------------------------------------------------------------
# 8. Convex provisioning (interactive: login + team selection)
# ---------------------------------------------------------------------------
if [[ ! -f .env.local ]] || ! grep -q VITE_CONVEX_URL .env.local; then
  say "Provisioning Convex"
  if [[ -n "$CONVEX_TEAM" ]]; then
    bunx convex dev --once --configure=new \
      --team "$CONVEX_TEAM" --project "$PROJECT_NAME"
  else
    echo "Pick your PERSONAL team at the prompt below."
    bunx convex dev --once --configure
  fi

  say "Generating Convex Auth keys"
  bunx @convex-dev/auth --skip-git-check
fi

say "Pushing Convex functions"
bunx convex dev --once

say "Typechecking"
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<EOF

  Done.

  cd $PROJECT_NAME
  bun run go        # Convex + Vite, http://localhost:5173

EOF

if [[ $RUN_AFTER -eq 1 ]]; then
  exec bash scripts/dev.sh
fi
