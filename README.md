# CircuitScout

A mobile-first scouting app for FIRST Robotics Competition teams, built by
CircuitRunners (FRC 1002). Scouts record pit and match reports on their
phones; the team reviews robots, compares them and builds pick lists.

Created by Tarun A, FRC 1002.

## What it does

- **Pit and match scouting** for the active event, with match assignments.
- **Teams, matches and pick lists**: stored averages, compare, data plot,
  match previews and shared pick list boards.
- **Admin**: events imported from The Blue Alliance, accounts, exports,
  past events.
- **Works offline**: after one online visit the app opens with no
  connection, shows the last data it saw, and lets scouts fill in forms.
- **Reports saved offline are kept on the device** and send by themselves
  on reconnect. A teammate who is online can also upload them by scanning
  the scout's QR code.

## Stack

Bun · Vite · React 19 · TypeScript (strict) · React Router 7 ·
Tailwind CSS v4 · shadcn/ui on Base UI · Convex (data and auth) ·
installable as a PWA.

The rules for working in this codebase are in [AGENTS.md](AGENTS.md).

## Running it

Always use `bun`.

    bun install
    bun run go            # Convex and Vite together
    bun run typecheck     # the app
    bunx tsc -p convex    # the Convex functions
    bun run lint
    bun run build

`bun run go` needs a Convex deployment. The app reads its address from
`VITE_CONVEX_URL`.

The Convex deployment needs these environment variables:

| Variable | Used for |
| --- | --- |
| `TBA_API_KEY` | Importing events, teams and schedules from The Blue Alliance |
| `MATCH13_API_KEY` | match13 ratings |
| `GMAIL_USER`, `GMAIL_APP_PASSWORD` | Password reset emails |
| `SITE_URL` | The site's address; reset links are built from it |
| `JWT_PRIVATE_KEY`, `JWKS` | Convex Auth; both from one run of the key generator |

## How changes ship

Each change is one `patch-*.sh` script at the repo root. A script checks
every file it will touch before writing anything, and is safe to run twice.

    bash patch-name.sh

Production is built on Vercel with one command, which deploys the Convex
functions and builds the site in the same step, so the two go out together:

    bunx convex deploy --cmd 'bun run build'

## Offline, in short

- The built app is stored on the device by a service worker. A new release
  shows an "Update available" prompt, never in the middle of a form.
- Pick lists and Admin are view only without a connection.
- Photos need a connection.
- Signing out discards reports that have not been sent. The app asks first.
