#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-qr-show.sh — data transfer plan, patch 8: Show my QR
#   1. A Show my QR button beside the Waiting to send heading, shown only
#      while something is waiting (decision D-3).
#   2. It opens a full-screen white page with a QR code holding this scout's
#      waiting reports: the scout's name and the count above it, the part
#      number below it. The screen is kept awake while it is open, where the
#      browser allows.
#   3. More than fits in one code is shown as a cycle of numbered parts
#      (plan section 5.4). A scanner can read them in any order.
#   4. The code is rebuilt whenever a report is saved, sent or dismissed.
#      Reports the server has refused are left out.
#   5. The sign-out question gains a Show my QR choice.
#
# The code is not signed (D-6). Nothing can scan it until patch 9 adds the
# scanner, so this patch changes nothing about how reports are sent.
#
# Two numbers are set by judgement and not by a phone trial, because the
# trial needs the scanner: PART_CHARS in src/lib/offline/transfer-code.ts
# (560 characters, a code of at most 77 modules) and PART_MS in src/components/my-qr.tsx
# (300 ms a part). Patch 9 revisits both.
#
# Requires patch 7 (patch-outbox.sh).
# Adds one dependency: qr 0.7.2 (no dependencies of its own).
# Client only: no Convex change. Safe to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f vite.config.ts && -f convex/auth.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
[[ -f src/components/sign-out-dialog.tsx ]] && grep -q 'export function startSending(' src/lib/offline/held.ts 2>/dev/null || {
  echo "ERROR: run patch-outbox.sh first; nothing was changed" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# ---- 1. Check everything before writing anything --------------------------
say "Checking"
trap 'rm -f .patch-qr-show.mjs .patch-qr-show.json' EXIT
cat > .patch-qr-show.json <<'EOF_JSON'
{
 "src/lib/offline/held.ts": {
  "marker": "export function heldTransfer(",
  "edits": [
   {
    "old": "\n/** Every held report of the signed-in scout, oldest first. */",
    "new": "\n/**\n * What \"my QR\" carries: the signed-in scout's waiting reports, oldest first,\n * each exactly as transfer.send would be given it. Failed reports are left\n * out: the server has already refused them.\n */\nexport function heldTransfer(): { author: string; reports: SendArgs[] } | null {\n  load();\n  const userId = cachedUserId();\n  if (userId === null) return null;\n  const reports = rows\n    .filter((row) => row.userId === userId && row.status === \"waiting\")\n    .sort((a, b) => a.heldAt - b.heldAt)\n    .map((row) => ({ id: row.id, eventId: row.eventId, ...row.report }) as SendArgs);\n  return { author: userId, reports };\n}\n\n/** Every held report of the signed-in scout, oldest first. */"
   }
  ]
 },
 "src/components/held.tsx": {
  "marker": "<MyQrButton />",
  "edits": [
   {
    "old": "  Card, CardContent, CardDescription, CardHeader, CardTitle,",
    "new": "  Card, CardAction, CardContent, CardDescription, CardHeader, CardTitle,"
   },
   {
    "old": "} from \"@/components/ui/card\";\nimport {",
    "new": "} from \"@/components/ui/card\";\nimport { MyQrButton } from \"@/components/my-qr\";\nimport {"
   },
   {
    "old": "        <CardTitle>Waiting to send</CardTitle>\n        <CardDescription>",
    "new": "        <CardTitle>Waiting to send</CardTitle>\n        <CardAction><MyQrButton /></CardAction>\n        <CardDescription>"
   }
  ]
 },
 "src/components/sign-out-dialog.tsx": {
  "marker": "canShowQr",
  "edits": [
   {
    "old": "import { Button } from \"@/components/ui/button\";",
    "new": "import { useState } from \"react\";\n\nimport { MyQrDialog } from \"@/components/my-qr\";\nimport { Button } from \"@/components/ui/button\";"
   },
   {
    "old": "} from \"@/components/ui/dialog\";\nimport { useOnline } from \"@/lib/offline/status\";",
    "new": "} from \"@/components/ui/dialog\";\nimport { useHeldItems } from \"@/lib/offline/held\";\nimport { useOnline } from \"@/lib/offline/status\";"
   },
   {
    "old": " * discards them (data transfer plan, D-2). Mounted once, in the app layout.",
    "new": " * discards them (data transfer plan, D-2). Offers the QR first: it is the\n * way to hand the reports to a teammate with a connection. Mounted once, in\n * the app layout."
   },
   {
    "old": "  const count = question?.count ?? 0;\n  return (\n    <Dialog open={question !== null} onOpenChange={(open) => { if (!open) cancelSignOut(); }}>",
    "new": "  const count = question?.count ?? 0;\n  const [showQr, setShowQr] = useState(false);\n  const canShowQr = useHeldItems().some((item) => item.status === \"waiting\");\n  return (\n    <>\n    <Dialog open={question !== null} onOpenChange={(open) => { if (!open) cancelSignOut(); }}>"
   },
   {
    "old": "              : \"To keep them, cancel and stay signed in until you are back online.\"}",
    "new": "              : \"To keep them, cancel and stay signed in until you are back online, or have a teammate who is online scan your QR first.\"}"
   },
   {
    "old": "          <Button variant=\"outline\" onClick={cancelSignOut}>Cancel</Button>\n          <Button variant=\"destructive\" onClick={() => question?.proceed()}>",
    "new": "          <Button variant=\"outline\" onClick={cancelSignOut}>Cancel</Button>\n          {canShowQr ? (\n            <Button\n              variant=\"outline\"\n              onClick={() => {\n                cancelSignOut();\n                setShowQr(true);\n              }}\n            >\n              Show my QR\n            </Button>\n          ) : null}\n          <Button variant=\"destructive\" onClick={() => question?.proceed()}>"
   },
   {
    "old": "    </Dialog>\n  );",
    "new": "    </Dialog>\n    <MyQrDialog open={showQr} onOpenChange={setShowQr} />\n    </>\n  );"
   }
  ]
 }
}
EOF_JSON
cat > .patch-qr-show.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";

const mode = process.argv[2]; // "check" | "write"
const plan = JSON.parse(readFileSync(".patch-qr-show.json", "utf8"));
const staged = [];
let already = 0;

for (const [path, { marker, edits }] of Object.entries(plan)) {
  let source;
  try {
    source = readFileSync(path, "utf8").replace(/\r\n/g, "\n");
  } catch {
    throw new Error(`${path} is missing`);
  }
  if (source.includes(marker)) {
    already += 1;
    console.log(`  already applied  ${path}`);
    continue;
  }
  for (const { old, new: next } of edits) {
    const found = source.split(old).length - 1;
    if (found !== 1) {
      throw new Error(
        `${path} is not the version this patch expects (${found === 0 ? "not found" : "found more than once"}):\n` +
        old.split("\n").slice(0, 4).join("\n"),
      );
    }
    source = source.replace(old, () => next);
  }
  if (!source.includes(marker)) throw new Error(`${path}: the edit did not take`);
  staged.push([path, source]);
}

for (const [path, source] of staged) {
  if (mode === "write") {
    writeFileSync(path, source);
    console.log(`  patched          ${path}`);
  } else console.log(`  ok               ${path}`);
}
if (mode === "write" && staged.length === 0 && already > 0) console.log("  nothing to do");
MJS
bun .patch-qr-show.mjs check || { echo "ERROR: nothing was changed" >&2; exit 1; }

# ---- 2. Dependency ----------------------------------------------------------
say "qr library"
if grep -q '"qr": "0.7.2"' package.json; then
  echo "  already installed"
else
  bun add --exact qr@0.7.2 || { echo "ERROR: could not install qr; no source file was changed" >&2; exit 1; }
fi

# ---- 3. New files ----------------------------------------------------------
say "Code format and dialog"
cat > src/lib/offline/transfer-code.ts <<'EOF_FILE'
/**
 * The text inside "my QR" (data transfer plan, section 5).
 *
 * A scout's waiting reports are written as compact JSON, compressed, and
 * turned into base45 text, which uses only the characters a QR code stores
 * most densely. That text is cut into numbered parts, one QR code each, and
 * the codes are shown in a cycle. A scanner collects the parts in any order
 * and puts the text back together.
 *
 *   part = "CS1/" id "/" number "/" count "/" chunk
 *
 * CS1 is the format. id is a checksum of the whole text, so it changes when
 * the reports do (a scanner that sees a new id starts again) and it proves
 * the parts were put back together correctly.
 *
 * Nothing here is secret or signed: the server decides whether the person
 * scanning may upload for the author (plan, section 7).
 */

/** One report as it travels: what transfer.send and transfer.relay take. */
export type TransferReport = { id: string; eventId: string; kind: string; args: unknown };
export type Transfer = { author: string; reports: TransferReport[] };

const FORMAT = "CS1";
const BASE45 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

/**
 * Characters of text per part. With the header a part is under 600
 * characters, which fits a version 15 code (77 modules a side) at medium
 * error correction. Smaller codes scan more easily from one phone screen to
 * another; larger ones mean fewer parts. To be tuned on real phones.
 */
export const PART_CHARS = 560;

function toBase45(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i + 1 < bytes.length; i += 2) {
    const n = (bytes[i] ?? 0) * 256 + (bytes[i + 1] ?? 0);
    out += BASE45.charAt(n % 45) + BASE45.charAt(Math.floor(n / 45) % 45) + BASE45.charAt(Math.floor(n / 2025));
  }
  if (bytes.length % 2 === 1) {
    const n = bytes[bytes.length - 1] ?? 0;
    out += BASE45.charAt(n % 45) + BASE45.charAt(Math.floor(n / 45));
  }
  return out;
}

function fromBase45(text: string): Uint8Array {
  const digits: number[] = [];
  for (const char of text) {
    const digit = BASE45.indexOf(char);
    if (digit === -1) throw new Error("not base45");
    digits.push(digit);
  }
  if (digits.length % 3 === 1) throw new Error("not base45");
  const bytes: number[] = [];
  for (let i = 0; i < digits.length; i += 3) {
    const [a = 0, b = 0, c] = digits.slice(i, i + 3);
    if (c === undefined) {
      const n = a + b * 45;
      if (n > 255) throw new Error("not base45");
      bytes.push(n);
    } else {
      const n = a + b * 45 + c * 2025;
      if (n > 65535) throw new Error("not base45");
      bytes.push(n >> 8, n & 255);
    }
  }
  return Uint8Array.from(bytes);
}

/** FNV-1a, 32 bits, as seven base 36 capitals. A checksum, not a secret. */
function checksum(text: string): string {
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(36).toUpperCase().padStart(7, "0");
}

async function through(bytes: Uint8Array, stream: CompressionStream | DecompressionStream): Promise<Uint8Array> {
  const writer = stream.writable.getWriter();
  // Not awaited: the reader below is what drains the stream.
  void writer.write(Uint8Array.from(bytes)).then(() => writer.close()).catch(() => {});
  return new Uint8Array(await new Response(stream.readable).arrayBuffer());
}

/**
 * The whole text for a transfer: a mode letter, then base45. D is compressed
 * (deflate), N is not, for a browser without CompressionStream.
 */
async function encode(transfer: Transfer): Promise<string> {
  const json = JSON.stringify({
    v: 1,
    a: transfer.author,
    r: transfer.reports.map((r) => [r.id, r.eventId, r.kind, r.args]),
  });
  const plain = new TextEncoder().encode(json);
  if (typeof CompressionStream === "function") {
    try {
      return `D${toBase45(await through(plain, new CompressionStream("deflate-raw")))}`;
    } catch {
      // Fall through to the uncompressed form.
    }
  }
  return `N${toBase45(plain)}`;
}

async function decode(text: string): Promise<Transfer> {
  const mode = text.charAt(0);
  const packed = fromBase45(text.slice(1));
  let plain: Uint8Array;
  if (mode === "D") plain = await through(packed, new DecompressionStream("deflate-raw"));
  else if (mode === "N") plain = packed;
  else throw new Error("unknown mode");
  const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plain));
  if (value === null || typeof value !== "object") throw new Error("not a transfer");
  const { v, a, r } = value as { v?: unknown; a?: unknown; r?: unknown };
  if (v !== 1 || typeof a !== "string" || !Array.isArray(r)) throw new Error("not a transfer");
  const reports = r.map((row: unknown): TransferReport => {
    if (!Array.isArray(row)) throw new Error("not a transfer");
    const [id, eventId, kind, args] = row as unknown[];
    if (typeof id !== "string" || typeof eventId !== "string" || typeof kind !== "string"
      || args === null || typeof args !== "object") {
      throw new Error("not a transfer");
    }
    return { id, eventId, kind, args };
  });
  return { author: a, reports };
}

/** The texts to show, one QR code each, in order. */
export async function packTransfer(transfer: Transfer): Promise<string[]> {
  const text = await encode(transfer);
  const id = checksum(text);
  const count = Math.max(1, Math.ceil(text.length / PART_CHARS));
  return Array.from({ length: count }, (_, i) =>
    `${FORMAT}/${id}/${i + 1}/${count}/${text.slice(i * PART_CHARS, (i + 1) * PART_CHARS)}`);
}

export type TransferPart = { id: string; number: number; count: number; chunk: string };

/** One scanned code, or null when it is not part of a CircuitScout transfer. */
export function readPart(scanned: string): TransferPart | null {
  const match = /^CS1\/([0-9A-Z]{7})\/([1-9][0-9]{0,2})\/([1-9][0-9]{0,2})\/([0-9A-Z $%*+\-./:]*)$/.exec(scanned);
  if (!match) return null;
  const [, id = "", n = "", total = "", chunk = ""] = match;
  const number = Number(n);
  const count = Number(total);
  if (number > count) return null;
  return { id, number, count, chunk };
}

/**
 * Puts a complete set of parts back together. Throws when a part is missing
 * or the text does not match its checksum.
 */
export async function unpackTransfer(parts: ReadonlyArray<TransferPart>): Promise<Transfer> {
  const first = parts[0];
  if (!first) throw new Error("no parts");
  const chunks = new Map<number, string>();
  for (const part of parts) {
    if (part.id !== first.id || part.count !== first.count) throw new Error("parts of different codes");
    chunks.set(part.number, part.chunk);
  }
  let text = "";
  for (let n = 1; n <= first.count; n += 1) {
    const chunk = chunks.get(n);
    if (chunk === undefined) throw new Error("a part is missing");
    text += chunk;
  }
  if (checksum(text) !== first.id) throw new Error("the parts do not match");
  return await decode(text);
}
EOF_FILE
echo "  wrote            src/lib/offline/transfer-code.ts"
cat > src/components/my-qr.tsx <<'EOF_FILE'
import encodeQR from "qr";
import { QrCode } from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import { api } from "../../convex/_generated/api";
import { Button } from "@/components/ui/button";
import {
  Dialog, DialogContent, DialogDescription, DialogTitle,
} from "@/components/ui/dialog";
import { heldTransfer, useHeldItems } from "@/lib/offline/held";
import { packTransfer } from "@/lib/offline/transfer-code";
import { useCachedQuery } from "@/lib/offline/use-cached-query";

/** How long each part stays on screen. To be tuned on real phones. */
const PART_MS = 300;

/** One code as an SVG path, a unit square per dark module. */
function drawing(text: string): { size: number; path: string } {
  // Alphanumeric mode is what makes base45 compact. border is the quiet
  // zone a scanner needs around the code.
  const rows = encodeQR(text, "raw", { ecc: "medium", encoding: "alphanumeric", border: 4 });
  let path = "";
  rows.forEach((row, y) => {
    row.forEach((dark, x) => {
      if (dark) path += `M${x} ${y}h1v1h-1z`;
    });
  });
  return { size: rows.length, path };
}

/** Keeps the screen on while the code is showing, where the browser allows. */
function useScreenAwake(on: boolean) {
  useEffect(() => {
    if (!on || !("wakeLock" in navigator)) return;
    let lock: WakeLockSentinel | null = null;
    let over = false;
    const hold = () => {
      if (document.visibilityState !== "visible") return;
      navigator.wakeLock.request("screen").then(
        (sentinel) => {
          if (over) void sentinel.release().catch(() => {});
          else lock = sentinel;
        },
        () => {
          // Refused (low battery, no permission). The code still shows.
        },
      );
    };
    hold();
    // The browser drops the lock when the page is hidden.
    document.addEventListener("visibilitychange", hold);
    return () => {
      over = true;
      document.removeEventListener("visibilitychange", hold);
      void lock?.release().catch(() => {});
    };
  }, [on]);
}

/**
 * "My QR": this scout's waiting reports as a code another scout on the same
 * team can scan to upload them (data transfer plan, sections 2 and 5).
 * Full screen and white, because a code is read best large, with nothing
 * around it. It is rebuilt whenever the waiting reports change.
 */
export function MyQrDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
  const items = useHeldItems();
  const profile = useCachedQuery(api.profiles.me);
  const waiting = items.filter((item) => item.status === "waiting");
  // Changes exactly when the set of reports in the code does.
  const signature = waiting.map((item) => item.id).join(",");

  const [built, setBuilt] = useState<{ signature: string; parts: string[] } | null>(null);
  useEffect(() => {
    if (!open || signature === "") return;
    let stale = false;
    const transfer = heldTransfer();
    if (!transfer) return;
    void packTransfer(transfer).then(
      (parts) => {
        if (!stale) setBuilt({ signature, parts });
      },
      () => {
        if (!stale) setBuilt({ signature, parts: [] });
      },
    );
    return () => {
      stale = true;
    };
  }, [open, signature]);

  const parts = built?.signature === signature ? built.parts : null;
  const codes = useMemo(() => {
    if (!parts) return null;
    try {
      return parts.map(drawing);
    } catch {
      return [];
    }
  }, [parts]);

  const [tick, setTick] = useState(0);
  const count = codes?.length ?? 0;
  useEffect(() => {
    if (!open || count < 2) return;
    const timer = setInterval(() => setTick((t) => t + 1), PART_MS);
    return () => clearInterval(timer);
  }, [open, count]);
  const index = count === 0 ? 0 : tick % count;
  const code = codes?.[index];

  useScreenAwake(open && count > 0);

  const reports = `${waiting.length} report${waiting.length === 1 ? "" : "s"}`;
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent
        className="top-0 left-0 flex h-svh w-screen max-w-none translate-x-0 translate-y-0 flex-col items-center justify-center gap-3 rounded-none bg-white p-4 text-black ring-0 sm:max-w-none"
      >
        <div className="text-center">
          <DialogTitle className="text-black">
            {profile?.displayName ?? "My QR"}
          </DialogTitle>
          <DialogDescription className="text-neutral-700">
            {waiting.length === 0 ? "Nothing is waiting to send." : `${reports} waiting to send`}
          </DialogDescription>
        </div>

        {waiting.length === 0 ? (
          <p className="max-w-xs text-center text-sm text-neutral-700">
            Everything saved on this device has reached the server.
          </p>
        ) : codes === null ? (
          <p className="text-sm text-neutral-700">Building the code…</p>
        ) : !code ? (
          <p className="max-w-xs text-center text-sm text-neutral-700">
            The code could not be built on this device. Your reports are still
            saved and will send when you are back online.
          </p>
        ) : (
          <>
            <svg
              role="img"
              aria-label={`QR code, part ${index + 1} of ${count}`}
              viewBox={`0 0 ${code.size} ${code.size}`}
              shapeRendering="crispEdges"
              style={{ width: "min(100vw - 2rem, 100svh - 13rem)", height: "min(100vw - 2rem, 100svh - 13rem)" }}
            >
              <rect width={code.size} height={code.size} fill="#fff" />
              <path d={code.path} fill="#000" />
            </svg>
            <p className="text-sm font-medium tabular-nums" aria-live="off">
              Part {index + 1} of {count}
            </p>
            <p className="max-w-sm text-center text-xs text-neutral-700">
              Turn your screen brightness up. A teammate who is online opens
              Scan a QR and points their camera here until every part is
              read. Your reports stay in Waiting to send until this device
              is back online.
            </p>
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}

/** Beside the Waiting to send heading. Shown only when something is waiting. */
export function MyQrButton() {
  const [open, setOpen] = useState(false);
  const waiting = useHeldItems().filter((item) => item.status === "waiting").length;
  if (waiting === 0 && !open) return null;
  return (
    <>
      <Button variant="outline" size="sm" onClick={() => setOpen(true)}>
        <QrCode className="size-3.5" aria-hidden /> Show my QR
      </Button>
      <MyQrDialog open={open} onOpenChange={setOpen} />
    </>
  );
}
EOF_FILE
echo "  wrote            src/components/my-qr.tsx"

# ---- 4. Edits --------------------------------------------------------------
say "Held list and sign-out question"
bun .patch-qr-show.mjs write

say "Done"
cat <<'TXT'
Next:
  1. bun run typecheck && bun run lint && bun run build
  2. Against a production build, signed in, on a phone if you can:
     a. Offline, save two or three reports. Waiting to send shows a
        Show my QR button beside its heading.
     b. Tap it: a white full-screen code with your name and the count.
        With more than one part, "Part 1 of 2" counts round.
     c. Leave it open for a minute: the screen should not dim or lock.
     d. Close it, save another report, open it again: the count is one
        higher and the code is different.
     e. Press Sign out: the question now offers Show my QR.
     f. Go back online: the reports send as before and the button goes.
  3. Nothing can read the code yet. Any phone's camera app will show text
     starting CS1/, which is the format working. Patch 9 is the scanner.
TXT
