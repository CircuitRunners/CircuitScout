#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-offline-login.sh — offline plan, patch 3 of 5: cached login
#   1. The auth gate. With no connection, the app lets the last confirmed
#      user in automatically, when this device holds BOTH a sign-in token and
#      that same user's cached data. No checkbox. (src/lib/offline/session.ts
#      has the five gate states and the reasoning.)
#   2. Sign-out goes through useSignOutAndClear(): the offline store is
#      emptied first, so the next person on a shared tablet sees nothing of
#      the previous scout. Offline, where Convex Auth's own signOut() would
#      wait on the server forever, the tokens are removed from the device
#      directly and the app reloads onto the sign-in screen.
#   3. <NeedsConnection> replaces endless spinners: "Connect once to sign in"
#      at the gate, and "Needs a connection" on My profile and Past Events.
#      The sign-in pages show an offline notice.
#   4. Admin routes open from the cached role when offline. That only decides
#      which pages open; Convex still checks every write.
#
# Requires patch-offline-store.sh (patch 2). A real cold start with no
# connection also needs patch-pwa.sh (patch 1), or the app files do not load.
#
# No Convex change, no schema change, no new dependency. Safe to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f vite.config.ts && -f convex/auth.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
[[ -f src/lib/offline/store.ts && -f src/lib/offline/use-cached-query.ts ]] || {
  echo "ERROR: run patch-offline-store.sh (patch 2) first; nothing was changed" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# ---- 1. Check every anchor before writing anything ------------------------
say "Checking anchors"
if grep -q "useGate" src/routes/auth-layout.tsx; then
  echo "  already patched  src/routes/auth-layout.tsx"
elif grep -q "useConvexAuth" src/routes/auth-layout.tsx && [[ $(wc -l < src/routes/auth-layout.tsx) -lt 30 ]]; then
  echo "  ok               src/routes/auth-layout.tsx"
else
  echo "ERROR: src/routes/auth-layout.tsx is not the file this patch expects; nothing was changed" >&2
  exit 1
fi
trap 'rm -f .patch-offline-login.mjs' EXIT
cat > .patch-offline-login.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";

const mode = process.argv[2]; // "check" | "write"
const plan = [];
const read = (path) => readFileSync(path, "utf8").replace(/\r\n/g, "\n");

/** Skip when `marker` is present; otherwise every anchor must appear exactly once. */
function edit(path, marker, pairs) {
  let source = read(path);
  if (source.includes(marker)) return plan.push({ path, skip: true });
  for (const [anchor] of pairs) {
    const count = source.split(anchor).length - 1;
    if (count !== 1) throw new Error(`${path}: expected anchor once, found ${count}:\n  ${anchor}`);
  }
  for (const [anchor, replacement] of pairs) source = source.replace(anchor, replacement);
  plan.push({ path, skip: false, next: source });
}

// ---- store.ts: expose whose rows are held ----------------------------------
edit("src/lib/offline/store.ts", "cachedUserId", [
  [
    "export const isStoreReady = (): boolean => ready;\n",
    `export const isStoreReady = (): boolean => ready;
/** Whose rows the store holds: the last user the server confirmed on this device. */
export const cachedUserId = (): string | null => userId;
`,
  ],
]);

// ---- require-auth.tsx: the gate --------------------------------------------
edit("src/routes/require-auth.tsx", "useGate", [
  [
    'import { useConvexAuth, useAction, useQuery } from "convex/react";\n',
    'import { useAction } from "convex/react";\n',
  ],
  [
    'import { LoadingWheel } from "@/components/loading-wheel";\n',
    `import { LoadingWheel } from "@/components/loading-wheel";
import { NeedsConnection } from "@/components/needs-connection";
import { useOnline } from "@/lib/offline/status";
import { useCachedQuery } from "@/lib/offline/use-cached-query";
import { useGate } from "@/lib/offline/use-gate";
`,
  ],
  [
    `function RequireProfile() {
  const profile = useQuery(api.profiles.me);

  if (profile === undefined) return <FullPageSpinner />;
  // Accounts created before this gate existed have no firstName; prompt them
  // too rather than leaving their reports signed "Scout".
  if (profile === null || !profile.firstName) {
    return <ProfileSetup existingName={profile?.displayName ?? null} />;
  }
  return <Outlet />;
}

export function RequireAuth() {
  const { isLoading, isAuthenticated } = useConvexAuth();
  const location = useLocation();

  if (isLoading) return <FullPageSpinner />;
  if (!isAuthenticated) {
    return <Navigate to="/sign-in" replace state={{ from: location.pathname }} />;
  }
  return <RequireProfile />;
}

export function RequireAdmin() {
  const profile = useQuery(api.profiles.me);
`,
    `const CONNECT_FIRST = {
  title: "Connect once to sign in",
  description:
    "Sign in while this device has a connection. After that, CircuitScout opens offline.",
};

function RequireProfile() {
  // Offline this is the copy saved on this device (offline plan, section 6).
  const profile = useCachedQuery(api.profiles.me);
  const online = useOnline();

  if (profile === undefined) {
    return online ? <FullPageSpinner /> : <NeedsConnection fullPage {...CONNECT_FIRST} />;
  }
  // Accounts created before this gate existed have no firstName; prompt them
  // too rather than leaving their reports signed "Scout".
  if (profile === null || !profile.firstName) {
    // Finishing a profile is a server call.
    if (!online) {
      return (
        <NeedsConnection
          fullPage
          title="Connect to finish setting up"
          description="Your name and team number are saved on the server."
        />
      );
    }
    return <ProfileSetup existingName={profile?.displayName ?? null} />;
  }
  return <Outlet />;
}

export function RequireAuth() {
  // See src/lib/offline/session.ts for the five states.
  const gate = useGate();
  const location = useLocation();

  if (gate === "loading") return <FullPageSpinner />;
  if (gate === "signed-out") {
    return <Navigate to="/sign-in" replace state={{ from: location.pathname }} />;
  }
  if (gate === "connect-first") return <NeedsConnection fullPage {...CONNECT_FIRST} />;
  // "live", or "offline": no connection, and this device holds both a sign-in
  // token and that same user's cached data.
  return <RequireProfile />;
}

export function RequireAdmin() {
  // Offline the role is the cached one. It only decides which pages open;
  // Convex still checks every write when it reaches the server.
  const profile = useCachedQuery(api.profiles.me);
`,
  ],
]);

// ---- Sign-out clears the device --------------------------------------------
edit("src/components/app-nav.tsx", "useSignOutAndClear", [
  ['import { useAuthActions } from "@convex-dev/auth/react";\n', ""],
  [
    'import { ConnectionIndicator } from "@/components/connection-indicator";\n',
    'import { ConnectionIndicator } from "@/components/connection-indicator";\nimport { useSignOutAndClear } from "@/lib/offline/use-sign-out";\n',
  ],
  ["  const { signOut } = useAuthActions();\n", "  const signOut = useSignOutAndClear();\n"],
]);

edit("src/routes/profile.tsx", "useSignOutAndClear", [
  [
    'import { api } from "../../convex/_generated/api";\n',
    'import { api } from "../../convex/_generated/api";\nimport { useSignOutAndClear } from "@/lib/offline/use-sign-out";\n',
  ],
  [
    "  const { signIn, signOut } = useAuthActions();\n",
    "  const { signIn } = useAuthActions();\n  const signOut = useSignOutAndClear();\n",
  ],
]);

// ---- Pages that need a connection ------------------------------------------
edit("src/routes/router.tsx", "OnlineOnly", [
  [
    'import { SeasonPage } from "./seasons";\n',
    'import { SeasonPage } from "./seasons";\nimport { OnlineOnly } from "./online-only";\n',
  ],
  ['              { path: "archive", element: <ArchivePage /> },\n', ""],
  ['              { path: "archive/:eventKey", element: <ArchiveEventPage /> },\n', ""],
  [
    '              { path: "profile", element: <ProfilePage /> },\n',
    `              {
                // Not cached: offline these say "Needs a connection".
                element: <OnlineOnly />,
                children: [
                  { path: "profile", element: <ProfilePage /> },
                  { path: "archive", element: <ArchivePage /> },
                  { path: "archive/:eventKey", element: <ArchiveEventPage /> },
                ],
              },
`,
  ],
]);

for (const e of plan) {
  if (e.skip) console.log(`  already patched  ${e.path}`);
  else if (mode === "write") {
    writeFileSync(e.path, e.next);
    console.log(`  patched          ${e.path}`);
  } else console.log(`  ok               ${e.path}`);
}
MJS
bun .patch-offline-login.mjs check || { echo "ERROR: nothing was changed" >&2; exit 1; }

# ---- 2. New files ----------------------------------------------------------
say "Gate, sign-out, NeedsConnection"
cat > src/lib/offline/session.ts <<'EOF_FILE'
/**
 * The cached-login decision (offline plan, section 5.1). Pure, so it can be
 * reasoned about and tested without React or Convex.
 *
 *   live           the server confirmed the session: the app, exactly as before
 *   offline        no connection, but this device holds a sign-in token and the
 *                  offline store holds that same user's data: the app, from cache
 *   signed-out     there is a connection and no session: /sign-in
 *   connect-first  no connection and nothing usable on the device
 *   loading        there is a connection and the server has not answered yet
 *
 * Nothing here grants anything. "offline" only decides what the UI shows;
 * every write is still checked by Convex when it reaches the server.
 */
export type Gate = "live" | "offline" | "signed-out" | "connect-first" | "loading";

export function decideGate(input: {
  /** useConvexAuth(): the server has confirmed the session. */
  isAuthenticated: boolean;
  /** useConvexAuth(): the server has not answered yet. */
  isLoading: boolean;
  online: boolean;
  /** The user id inside the stored sign-in token, or null when there is none. */
  tokenUserId: string | null;
  /** Whose data the offline store holds, or null when it holds nobody's. */
  cachedUserId: string | null;
}): Gate {
  if (input.isAuthenticated) return "live";
  if (input.online) return input.isLoading ? "loading" : "signed-out";
  // The token and the cache must be the same person's. A token alone shows
  // nothing; a cache alone could be the previous user's.
  if (input.tokenUserId !== null && input.tokenUserId === input.cachedUserId) return "offline";
  return "connect-first";
}

/**
 * Reads the user id out of a Convex Auth token without verifying it. Convex
 * Auth sets the subject to "<userId>|<sessionId>". The result is only ever
 * compared with the cached user id, to decide whose cached data to show; an
 * unreadable token simply means no offline entry.
 */
export function userIdFromToken(token: string | null): string | null {
  if (!token) return null;
  try {
    const payload = token.split(".")[1];
    if (!payload) return null;
    const base64 = payload.replace(/-/g, "+").replace(/_/g, "/");
    const json = atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "="));
    const subject: unknown = (JSON.parse(json) as { sub?: unknown }).sub;
    if (typeof subject !== "string") return null;
    const id = subject.split("|")[0];
    return id ? id : null;
  } catch {
    return null;
  }
}

/**
 * Removes Convex Auth's tokens from this device. Only for signing out with no
 * connection: Convex Auth's own signOut() erases them after a server call,
 * and offline that call never returns. The session on the server stays valid
 * until it expires, but nothing on this device can use it any more.
 *
 * Convex Auth keeps its keys in localStorage under the "__convexAuth" prefix
 * (@convex-dev/auth 0.0.95). If a future version moves them, signing out
 * offline stops clearing the token and the app still shows no cached data,
 * because clearOfflineData() has already emptied the store.
 */
export function forgetAuthTokens() {
  try {
    const doomed: string[] = [];
    for (let i = 0; i < localStorage.length; i += 1) {
      const key = localStorage.key(i);
      if (key?.startsWith("__convexAuth")) doomed.push(key);
    }
    for (const key of doomed) localStorage.removeItem(key);
  } catch {
    // Storage is unavailable; there is nothing to forget.
  }
}
EOF_FILE
echo "  wrote            src/lib/offline/session.ts"
cat > src/lib/offline/use-gate.ts <<'EOF_FILE'
import { useAuthToken } from "@convex-dev/auth/react";
import { useConvexAuth } from "convex/react";
import { useSyncExternalStore } from "react";

import { decideGate, userIdFromToken, type Gate } from "./session";
import { useOnline } from "./status";
import { cachedUserId, subscribeStore } from "./store";

/** Which of the five gate states the app is in. See session.ts. */
export function useGate(): Gate {
  const { isAuthenticated, isLoading } = useConvexAuth();
  const online = useOnline();
  const token = useAuthToken();
  const cached = useSyncExternalStore(subscribeStore, cachedUserId);
  return decideGate({
    isAuthenticated,
    isLoading,
    online,
    tokenUserId: userIdFromToken(token),
    cachedUserId: cached,
  });
}
EOF_FILE
echo "  wrote            src/lib/offline/use-gate.ts"
cat > src/lib/offline/use-sign-out.ts <<'EOF_FILE'
import { useAuthActions } from "@convex-dev/auth/react";
import { useCallback } from "react";

import { forgetAuthTokens } from "./session";
import { useOnline } from "./status";
import { clearOfflineData } from "./store";

/**
 * The only way the app signs out. Empties the offline store first, so the
 * next person on a shared tablet never sees the previous scout's data, then
 * signs out.
 *
 * With no connection, Convex Auth's signOut() would wait forever on a server
 * call, so the tokens are removed from the device directly and the page is
 * reloaded onto the sign-in screen.
 */
export function useSignOutAndClear(): () => Promise<void> {
  const { signOut } = useAuthActions();
  const online = useOnline();
  return useCallback(async () => {
    clearOfflineData();
    if (online) {
      await signOut();
      return;
    }
    forgetAuthTokens();
    window.location.assign("/sign-in");
  }, [online, signOut]);
}
EOF_FILE
echo "  wrote            src/lib/offline/use-sign-out.ts"
cat > src/components/needs-connection.tsx <<'EOF_FILE'
import { CloudOff } from "lucide-react";

/**
 * Shown in place of an endless spinner when a page has nothing it can show
 * without a connection. `fullPage` centres it on the screen, for use outside
 * the app layout (the sign-in gate).
 */
export function NeedsConnection({
  title = "Needs a connection",
  description = "This page will load when you are back online.",
  fullPage = false,
}: {
  title?: string;
  description?: string;
  fullPage?: boolean;
}) {
  const body = (
    <div
      role="status"
      className="text-muted-foreground mx-auto flex max-w-sm flex-col items-center gap-3 rounded-lg border border-dashed p-8 text-center"
    >
      <CloudOff className="size-8" aria-hidden />
      <p className="text-foreground text-base font-medium">{title}</p>
      <p className="text-sm">{description}</p>
    </div>
  );
  if (!fullPage) return body;
  return <div className="flex min-h-svh items-center justify-center p-6">{body}</div>;
}
EOF_FILE
echo "  wrote            src/components/needs-connection.tsx"
cat > src/routes/online-only.tsx <<'EOF_FILE'
import { Outlet } from "react-router";

import { NeedsConnection } from "@/components/needs-connection";
import { useOnline } from "@/lib/offline/status";

/**
 * Route wrapper for pages that are not cached and cannot do anything useful
 * offline (My profile, Past Events). Offline they say so instead of spinning.
 */
export function OnlineOnly() {
  const online = useOnline();
  return online ? <Outlet /> : <NeedsConnection />;
}
EOF_FILE
echo "  wrote            src/routes/online-only.tsx"
cat > src/routes/auth-layout.tsx <<'EOF_FILE'
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
EOF_FILE
echo "  wrote            src/routes/auth-layout.tsx"

# ---- 3. Anchored edits -----------------------------------------------------
say "Wiring: store, require-auth, nav, profile, router"
bun .patch-offline-login.mjs write

say "Done"
cat <<'TXT'
Next:
  1. bun run typecheck && bun run lint && bun run build
  2. Test against a production build, because the service worker is off
     under bun run go:   bunx vite preview   (or a Vercel preview URL)
     a. Sign in and open the Dashboard, so this device has your data.
     b. DevTools > Network > Offline, then reload. You should land on the
        Dashboard with the red banner, not on a spinner or the sign-in page.
     c. Still offline: My profile and Past Events say "Needs a connection".
     d. Still offline: press Sign out. You land on the sign-in page with an
        offline notice. Reload: "Connect once to sign in", and no data.
     e. Back online: sign in as usual. Everything is live again.
  3. On a real phone, repeat (a) and (b) with airplane mode.
Known and expected until patch 4: offline, the robots in a match and the
match and pit forms still say Loading.
TXT
