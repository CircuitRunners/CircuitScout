#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-green-theme.sh — CircuitScout green.
#   --secondary  -> green        filled secondary buttons, active chips, badges
#   --accent     -> light green  every hover, and the pick list drop target
#   --destructive unchanged      warnings, flags and deletes stay red
#
# Also puts the logo left of the wordmark. Save your PNG as public/logo.png —
# Vite serves that folder from the site root, so no import is needed. If the
# file is missing the header falls back to text alone rather than a broken
# image.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/index.css ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "Theme tokens"
cat > /tmp/g1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/index.css";
let s = readFileSync(p, "utf8");
if (s.includes("CircuitScout green")) { console.log("already patched"); process.exit(0); }
s += `
/* CircuitScout green. Appended last so it wins over the generated theme
   without editing shadcn's own blocks — a later \`shadcn add\` can rewrite
   those, and this survives it.

   Dark mode gets its own pair: a pale green hover on a dark surface reads as
   a stain rather than a highlight. */
:root {
  --secondary: #22c55e;
  --secondary-foreground: #052e16;
  --accent: #dcfce7;
  --accent-foreground: #14532d;
  --ring: #22c55e;
}

.dark {
  --secondary: #22c55e;
  --secondary-foreground: #052e16;
  --accent: #14532d;
  --accent-foreground: #bbf7d0;
  --ring: #22c55e;
}
`;
writeFileSync(p, s);
console.log("src/index.css patched");
MJS
bun /tmp/g1.mjs

say "Logo in the header"
cat > /tmp/g2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/components/app-nav.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("logo.png")) { console.log("already patched"); process.exit(0); }

const old = `        <NavLink to="/" className="font-semibold tracking-tight">
          CircuitScout
        </NavLink>`;
if (!s.includes(old)) fail("could not find the wordmark");
s = s.replace(old, `        <NavLink to="/" className="flex items-center gap-2 font-semibold tracking-tight">
          <img
            src="/logo.png"
            alt=""
            className="size-6 shrink-0"
            onError={(e) => { e.currentTarget.style.display = "none"; }}
          />
          CircuitScout
        </NavLink>`);

s = s.replace(`          <SheetHeader>
            <SheetTitle>CircuitScout</SheetTitle>
          </SheetHeader>`,
`          <SheetHeader>
            <SheetTitle className="flex items-center gap-2">
              <img
                src="/logo.png"
                alt=""
                className="size-5 shrink-0"
                onError={(e) => { e.currentTarget.style.display = "none"; }}
              />
              CircuitScout
            </SheetTitle>
          </SheetHeader>`);

writeFileSync(p, s);
console.log("src/components/app-nav.tsx patched");
MJS
bun /tmp/g2.mjs

say "Drop target"
cat > /tmp/g3.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/picklists/board.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("border-secondary")) { console.log("already patched"); process.exit(0); }
const old = `        isOver ? "bg-accent/50" : "",`;
if (!s.includes(old)) fail("could not find the drop target style");
// Full accent plus a green border: hover and "you can drop here" share the
// hue, so the border is what distinguishes them.
s = s.replace(old, `        isOver ? "bg-accent border-secondary" : "",`);
writeFileSync(p, s);
console.log("src/routes/picklists/board.tsx patched");
MJS
bun /tmp/g3.mjs
rm -f /tmp/g1.mjs /tmp/g2.mjs /tmp/g3.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."

cat <<'DONE'

  Save your PNG as public/logo.png. Until then the header shows text only.

DONE
