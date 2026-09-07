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
