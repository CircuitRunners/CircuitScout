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
