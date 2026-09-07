#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-tba-link.sh — link to the event on The Blue Alliance, beside the event
# name on the dashboard. PageShell's title becomes a ReactNode so it can hold
# markup rather than only a string.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f src/routes/dashboard.tsx ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

say "PageShell: title accepts markup"
cat > /tmp/tl1.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/page-shell.tsx";
let s = readFileSync(p, "utf8");
if (s.includes("title: ReactNode")) { console.log("already patched"); process.exit(0); }
if (!s.includes("  title: string;")) { console.error("could not find the title prop"); process.exit(1); }
s = s.replace("  title: string;", "  title: ReactNode;");
s = s.replace('<h1 className="text-2xl font-semibold tracking-tight">{title}</h1>',
  '<h1 className="flex flex-wrap items-baseline gap-x-3 gap-y-1 text-2xl font-semibold tracking-tight">\n            {title}\n          </h1>');
writeFileSync(p, s);
console.log("src/routes/page-shell.tsx patched");
MJS
bun /tmp/tl1.mjs

say "Dashboard: TBA link"
cat > /tmp/tl2.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";
const p = "src/routes/dashboard.tsx";
let s = readFileSync(p, "utf8");
const fail = (m) => { console.error(m); process.exit(1); };
if (s.includes("thebluealliance.com/event")) { console.log("already patched"); process.exit(0); }

s = s.replace('import { Link } from "react-router";',
              'import { Link } from "react-router";\nimport { useState } from "react";\nimport { ExternalLink } from "lucide-react";');

s = s.replace("function Metric({", `/**
 * The mark is hotlinked from TBA, so it can fail — a blocked request, an
 * offline venue, a changed path. Falls back to a generic external-link icon
 * rather than leaving a broken image in the page heading.
 */
function TbaLink({ eventKey }: { eventKey: string }) {
  const [markFailed, setMarkFailed] = useState(false);

  return (
    <a
      href={\`https://www.thebluealliance.com/event/\${eventKey}\`}
      target="_blank"
      rel="noreferrer noopener"
      className="text-muted-foreground hover:text-foreground inline-flex items-center gap-1.5 text-sm font-normal transition-colors"
    >
      {markFailed ? (
        <ExternalLink className="size-3.5" />
      ) : (
        <img
          src="https://www.thebluealliance.com/favicon.ico"
          alt=""
          className="size-4 rounded-sm"
          onError={() => setMarkFailed(true)}
        />
      )}
      The Blue Alliance
    </a>
  );
}

function Metric({`);

const oldTitle = `      title={event ? event.name : "No active event"}`;
if (!s.includes(oldTitle)) fail("could not find the dashboard title");
s = s.replace(oldTitle, `      title={
        event ? (
          <>
            {event.name}
            <TbaLink eventKey={event.tbaEventKey} />
          </>
        ) : (
          "No active event"
        )
      }`);

writeFileSync(p, s);
console.log("src/routes/dashboard.tsx patched");
MJS
bun /tmp/tl2.mjs
rm -f /tmp/tl1.mjs /tmp/tl2.mjs

say "Typecheck"
bun run typecheck || echo "Typecheck reported issues — see above."
