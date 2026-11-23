#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# patch-qr-scan.sh — data transfer plan, patch 9: scanning
#   1. A Scan a QR button on both dashboards, for anyone who is online
#      (decision D-9). It opens /scan.
#   2. /scan uses the camera to read a teammate's Show my QR, collecting the
#      numbered parts in any order and showing "2 of 5 parts read".
#   3. When every part is read the camera stops and each report is uploaded
#      with its own call to the new transfer.relay, with a line for each:
#      Uploaded, Already received, Refused with the reason, or Not uploaded.
#   4. The page ends on a confirmation: "Transfer complete. 5 reports
#      uploaded for Sandy A. (1002)", and says plainly when a transfer is
#      only partly done. The name comes from the server, not from the code.
#   5. transfer.relay checks the team boundary (D-6): the person scanning
#      must be signed in and on the same team as the scout the code names.
#      The report is then written for that scout exactly as their own
#      device would have sent it, and the receipt records who relayed it.
#   6. Nothing is written twice: a second scan, or the author's own device
#      reconnecting later, gets "already received" (D-4).
#
# The scanning device keeps nothing. A scout on another team cannot upload.
#
# Reading uses the browser's built-in barcode reader where there is one
# (Chrome on Android) and the qr library's decoder everywhere else,
# iPhones included.
#
# Requires patch 8 (patch-qr-show.sh).
# Touches Convex: one new mutation, nothing existing changes. No new
# dependency. Safe to re-run.
# ---------------------------------------------------------------------------
set -euo pipefail
[[ -f vite.config.ts && -f convex/auth.ts ]] || { echo "ERROR: run from the repo root" >&2; exit 1; }
[[ -f src/lib/offline/transfer-code.ts && -f src/components/my-qr.tsx && -f convex/lib/transfer.ts ]] || {
  echo "ERROR: run patch-qr-show.sh first; nothing was changed" >&2; exit 1; }
grep -q '"qr": "0.7.2"' package.json || {
  echo "ERROR: the qr library is not installed. Run patch-qr-show.sh again; nothing was changed" >&2; exit 1; }
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

# ---- 1. Check everything before writing anything --------------------------
say "Checking"
trap 'rm -f .patch-qr-scan.mjs .patch-qr-scan.json' EXIT
cat > .patch-qr-scan.json <<'EOF_JSON'
{
 "convex/transfer.ts": {
  "marker": "export const relay = mutation(",
  "edits": [
   {
    "old": "import { requireUser } from \"./lib/guards\";",
    "new": "import { profileOf, requireUser } from \"./lib/guards\";"
   },
   {
    "old": "const MAX_IDS = 200;\n",
    "new": "const MAX_IDS = 200;\n\n/**\n * A relayed report larger than this, as JSON, is refused. The largest real\n * form, with every notes box at its limit, is well under it.\n */\nconst MAX_RELAY_CHARS = 40_000;\n\n/**\n * A refusal that is about the code as a whole, not one report in it: every\n * other report in the same code would be refused the same way, so the\n * scanner stops at the first.\n */\nfunction refuseCode(message: string): never {\n  throw new ConvexError({ scope: \"code\" as const, message });\n}\n"
   },
   {
    "old": "    await acceptReport(ctx, await requireUser(ctx), args.report, { via: \"direct\" }),\n});",
    "new": "    await acceptReport(ctx, await requireUser(ctx), args.report, { via: \"direct\" }),\n});\n\n/**\n * Uploads one report from a teammate's QR code (data transfer plan,\n * section 7). The code is not signed. What the server checks is the team\n * boundary: the caller must be signed in and on the same team as the scout\n * the code names. The report is then written for that scout exactly as\n * transfer.send would write it, practice mode included, and the receipt\n * records who relayed it.\n *\n * Safe to call again with the same report: the second call answers\n * \"received\" and writes nothing, as does the author's own device later.\n */\nexport const relay = mutation({\n  args: { author: v.string(), report: heldReport },\n  handler: async (ctx, args) => {\n    const relayedBy = await requireUser(ctx);\n    const mine = await profileOf(ctx, relayedBy);\n    if (mine?.teamNumber === undefined) {\n      refuseCode(\"Set your team number on your profile before uploading for a teammate.\");\n    }\n    const authorId = ctx.db.normalizeId(\"users\", args.author);\n    const theirs = authorId ? await profileOf(ctx, authorId) : null;\n    if (!authorId || !theirs) {\n      refuseCode(\"This code is from an account that does not exist here.\");\n    }\n    if (theirs.teamNumber !== mine.teamNumber) {\n      refuseCode(\"This code belongs to a scout on another team. Only a teammate can upload it.\");\n    }\n    if (JSON.stringify(args.report).length > MAX_RELAY_CHARS) {\n      throw new ConvexError(\"That report is larger than a form can produce.\");\n    }\n    const arrival = await acceptReport(ctx, authorId, args.report, { via: \"relay\", relayedBy });\n    // The name comes from the server, never from the code.\n    return { ...arrival, author: theirs.displayName };\n  },\n});"
   }
  ]
 },
 "src/routes/router.tsx": {
  "marker": "{ path: \"scan\", element: <ScanPage /> }",
  "edits": [
   {
    "old": "import ProfilePage from \"./profile\";\nimport NotFoundPage from \"./not-found\";",
    "new": "import ProfilePage from \"./profile\";\nimport ScanPage from \"./scan\";\nimport NotFoundPage from \"./not-found\";"
   },
   {
    "old": "\n              { path: \"pit\", element: <SeasonPage page=\"pit\" /> },",
    "new": "\n              // Says so itself when offline: a scan in progress must not vanish.\n              { path: \"scan\", element: <ScanPage /> },\n\n              { path: \"pit\", element: <SeasonPage page=\"pit\" /> },"
   }
  ]
 },
 "src/routes/dashboard.tsx": {
  "marker": "<ScanQrLink />",
  "edits": [
   {
    "old": "import { HeldList } from \"@/components/held\";\nimport { OfflineReady } from \"@/components/offline-ready\";",
    "new": "import { HeldList } from \"@/components/held\";\nimport { ScanQrLink } from \"@/components/scan-link\";\nimport { OfflineReady } from \"@/components/offline-ready\";"
   },
   {
    "old": "      <HeldList />\n      {assignments?.upNext ? (",
    "new": "      <HeldList />\n      <ScanQrLink />\n      {assignments?.upNext ? ("
   }
  ]
 },
 "src/routes/notes/dashboard.tsx": {
  "marker": "<ScanQrLink />",
  "edits": [
   {
    "old": "import { HeldList } from \"@/components/held\";\nimport { OfflineReady } from \"@/components/offline-ready\";",
    "new": "import { HeldList } from \"@/components/held\";\nimport { ScanQrLink } from \"@/components/scan-link\";\nimport { OfflineReady } from \"@/components/offline-ready\";"
   },
   {
    "old": "      <HeldList />\n      {assignments?.upNext ? (",
    "new": "      <HeldList />\n      <ScanQrLink />\n      {assignments?.upNext ? ("
   }
  ]
 }
}
EOF_JSON
cat > .patch-qr-scan.mjs <<'MJS'
import { readFileSync, writeFileSync } from "node:fs";

const mode = process.argv[2]; // "check" | "write"
const plan = JSON.parse(readFileSync(".patch-qr-scan.json", "utf8"));
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
bun .patch-qr-scan.mjs check || { echo "ERROR: nothing was changed" >&2; exit 1; }

# ---- 2. New files ----------------------------------------------------------
say "Scanner, upload, page"
cat > src/lib/offline/relay.ts <<'EOF_FILE'
import { ConvexError } from "convex/values";

import { cacheKey, readCached } from "./store";
import type { Transfer, TransferReport } from "./transfer-code";

/**
 * Uploading a scanned code (data transfer plan, section 6): one call per
 * report, so a report the server refuses cannot undo the good ones beside it,
 * and a line of result for each.
 */

export type RelayStatus =
  | "pending" | "uploading"
  /** Written now. */
  | "uploaded"
  /** The server already had it. Nothing was written. */
  | "received"
  | "refused"
  /** Never reached the server: the connection went, or the code was refused whole. */
  | "notUploaded";

export type RelayLine = { id: string; label: string; status: RelayStatus; reason: string | null };

export type RelayOutcome = {
  lines: RelayLine[];
  /** The author's name as the server gave it, once any report was answered. */
  author: string | null;
  /** Set when the whole code was refused: wrong team, unknown account. */
  refusedWhole: string | null;
};

/** The server call: transfer.relay. */
export type RelayCall = (author: string, report: TransferReport) =>
  Promise<{ status: "accepted" | "received"; author: string }>;

function refusal(error: unknown): { whole: boolean; reason: string } {
  if (error instanceof ConvexError) {
    const data: unknown = error.data;
    if (typeof data === "string") return { whole: false, reason: data };
    if (data !== null && typeof data === "object") {
      const { scope, message } = data as { scope?: unknown; message?: unknown };
      if (typeof message === "string") return { whole: scope === "code", reason: message };
    }
    return { whole: false, reason: "The server refused this report." };
  }
  return { whole: false, reason: "The server could not read this report." };
}

/**
 * Uploads every report in a scanned code, in order. onChange is given a fresh
 * outcome after every step, for the screen. Never throws.
 */
export async function relayAll(
  transfer: Transfer,
  labels: ReadonlyArray<string>,
  call: RelayCall,
  isOnline: () => boolean,
  onChange: (outcome: RelayOutcome) => void,
): Promise<RelayOutcome> {
  let outcome: RelayOutcome = {
    lines: transfer.reports.map((report, i): RelayLine => ({
      id: report.id, label: labels[i] ?? "Report", status: "pending", reason: null,
    })),
    author: null,
    refusedWhole: null,
  };
  const set = (index: number, status: RelayStatus, reason: string | null = null) => {
    outcome = {
      ...outcome,
      lines: outcome.lines.map((line, i) => (i === index ? { ...line, status, reason } : line)),
    };
  };
  const rest = (from: number, reason: string) => {
    outcome = {
      ...outcome,
      lines: outcome.lines.map((line, i) => (i >= from ? { ...line, status: "notUploaded", reason } : line)),
    };
  };
  onChange(outcome);

  for (const [index, report] of transfer.reports.entries()) {
    if (!isOnline()) {
      rest(index, "The connection was lost.");
      break;
    }
    set(index, "uploading");
    onChange(outcome);
    try {
      const answer = await call(transfer.author, report);
      outcome = { ...outcome, author: answer.author };
      set(index, answer.status === "accepted" ? "uploaded" : "received");
    } catch (error) {
      const { whole, reason } = refusal(error);
      if (whole) {
        outcome = { ...outcome, refusedWhole: reason };
        rest(index, reason);
        break;
      }
      set(index, "refused", reason);
    }
    onChange(outcome);
  }
  onChange(outcome);
  return outcome;
}

const plural = (n: number, one: string) => `${n} ${one}${n === 1 ? "" : "s"}`;

/** The confirmation the scanning device shows when the upload ends. */
export function relaySummary(outcome: RelayOutcome): { complete: boolean; title: string; detail: string } {
  const count = (status: RelayStatus) => outcome.lines.filter((line) => line.status === status).length;
  const uploaded = count("uploaded");
  const received = count("received");
  const refused = count("refused");
  const notUploaded = count("notUploaded");
  const who = outcome.author ? ` for ${outcome.author}` : "";

  if (outcome.refusedWhole) {
    return { complete: false, title: "Nothing was uploaded", detail: outcome.refusedWhole };
  }
  if (refused === 0 && notUploaded === 0) {
    if (uploaded === 0) {
      return {
        complete: true,
        title: "Transfer complete",
        detail: `${received === 1 ? "This report was" : `All ${received} reports were`} already received${who}. Nothing new was uploaded.`,
      };
    }
    return {
      complete: true,
      title: "Transfer complete",
      detail: `${plural(uploaded, "report")} uploaded${who}${received > 0 ? `, ${received} already received` : ""}.`,
    };
  }
  const parts = [
    uploaded > 0 ? `${uploaded} uploaded` : null,
    received > 0 ? `${received} already received` : null,
    refused > 0 ? `${refused} refused` : null,
    notUploaded > 0 ? `${notUploaded} not uploaded` : null,
  ].filter((part): part is string => part !== null);
  return {
    complete: false,
    title: "Transfer not complete",
    detail: `${parts.join(", ")}${who}. ${notUploaded > 0 ? "Scan the code again to finish: what already arrived will not be written twice." : "The refused reports are listed below with the reason."}`,
  };
}

// ---- What to call each report ----------------------------------------------

type Named = { _id?: unknown; number?: unknown; matchNumber?: unknown };

function saved(fn: string): Named[] {
  const key = cacheKey(fn, {});
  const result = key === null ? undefined : readCached(key)?.result;
  return Array.isArray(result) ? (result as Named[]) : [];
}

const num = (value: unknown): number | null => (typeof value === "number" ? value : null);

/**
 * A name for each report in a code, from what the report says and from the
 * schedule and team list this device has saved. A 2026 report names its
 * match and team by id, so without those lists it is just "Match report".
 */
export function relayLabels(reports: ReadonlyArray<TransferReport>): string[] {
  const teams = new Map(saved("teams:listWithStatus").map((t) => [t._id, num(t.number)]));
  const matches = new Map(saved("matches:listForEvent").map((m) => [m._id, num(m.matchNumber)]));
  return reports.map((report) => {
    const args = (report.args ?? {}) as Record<string, unknown>;
    const team = num(args.teamNumber) ?? teams.get(args.teamId) ?? null;
    const match = num(args.matchNumber) ?? matches.get(args.matchId) ?? null;
    if (report.kind === "match" || report.kind === "noteMatch") {
      return match !== null && team !== null ? `Qual ${match} · team ${team}` : "Match report";
    }
    return team !== null ? `Team ${team} pit report` : "Pit report";
  });
}
EOF_FILE
echo "  wrote            src/lib/offline/relay.ts"
cat > src/lib/offline/qr-scanner.ts <<'EOF_FILE'
/**
 * The camera side of scanning a teammate's QR (data transfer plan, section
 * 6.2). Opens the rear camera into a <video> and reports the text of every
 * QR code it reads, many times a second, until stopped.
 *
 * Reading uses the browser's own BarcodeDetector where there is one (Chrome
 * on Android). Everywhere else, iPhones included, frames are read with the
 * qr library's decoder, which is loaded only then.
 */

export type CameraProblem =
  /** No camera API here: an old browser, or a page not served over https. */
  | "unsupported"
  /** The person, or the device's settings, said no. */
  | "denied"
  /** No camera on this device. */
  | "none"
  | "failed";

export class CameraError extends Error {
  problem: CameraProblem;
  constructor(problem: CameraProblem) {
    super(problem);
    this.problem = problem;
  }
}

/** Time between reads. A read itself takes a few tens of milliseconds. */
const READ_GAP_MS = 60;
/** Frames are read from a centred square no larger than this, in pixels. */
const MAX_SIDE = 720;

type NativeDetector = { detect: (source: HTMLVideoElement) => Promise<Array<{ rawValue: string }>> };
type NativeDetectorClass = {
  new (options: { formats: string[] }): NativeDetector;
  getSupportedFormats?: () => Promise<string[]>;
};

async function nativeDetector(): Promise<NativeDetector | null> {
  const Detector = (globalThis as { BarcodeDetector?: NativeDetectorClass }).BarcodeDetector;
  if (!Detector) return null;
  try {
    const formats = await Detector.getSupportedFormats?.();
    if (formats && !formats.includes("qr_code")) return null;
    return new Detector({ formats: ["qr_code"] });
  } catch {
    return null;
  }
}

/**
 * Starts the camera in `video` and calls onText for each code read. Resolves
 * with the function that stops it and turns the camera off. Rejects with a
 * CameraError when the camera cannot be used.
 */
export async function startScanner(
  video: HTMLVideoElement,
  onText: (text: string) => void,
): Promise<() => void> {
  if (!navigator.mediaDevices?.getUserMedia) throw new CameraError("unsupported");
  let stream: MediaStream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: { facingMode: { ideal: "environment" }, width: { ideal: 1280 }, height: { ideal: 720 } },
    });
  } catch (error) {
    const name = error instanceof DOMException ? error.name : "";
    if (name === "NotAllowedError" || name === "SecurityError") throw new CameraError("denied");
    if (name === "NotFoundError" || name === "OverconstrainedError") throw new CameraError("none");
    throw new CameraError("failed");
  }

  let stopped = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const stop = () => {
    stopped = true;
    if (timer !== undefined) clearTimeout(timer);
    for (const track of stream.getTracks()) track.stop();
    video.srcObject = null;
  };

  try {
    // iOS plays inline only when asked to, and only when muted.
    video.setAttribute("playsinline", "");
    video.muted = true;
    video.srcObject = stream;
    await video.play();
  } catch {
    stop();
    throw new CameraError("failed");
  }

  let native = await nativeDetector();
  let decode: ((image: { width: number; height: number; data: Uint8ClampedArray }) => string) | null = null;
  const canvas = document.createElement("canvas");
  const context = canvas.getContext("2d", { willReadFrequently: true });

  const read = async (): Promise<string[]> => {
    if (video.readyState < 2 || video.videoWidth === 0) return [];
    if (native) {
      try {
        return (await native.detect(video)).map((found) => found.rawValue);
      } catch {
        // The built-in reader failed on this device. Use the library from now on.
        native = null;
      }
    }
    if (!context) return [];
    decode ??= (await import("qr/decode.js")).decodeQR;
    const side = Math.min(video.videoWidth, video.videoHeight);
    const size = Math.min(side, MAX_SIDE);
    canvas.width = size;
    canvas.height = size;
    context.drawImage(
      video,
      (video.videoWidth - side) / 2, (video.videoHeight - side) / 2, side, side,
      0, 0, size, size,
    );
    try {
      return [decode(context.getImageData(0, 0, size, size))];
    } catch {
      // No code in this frame.
      return [];
    }
  };

  const step = () => {
    void read().then(
      (texts) => {
        if (stopped) return;
        for (const text of texts) onText(text);
        timer = setTimeout(step, READ_GAP_MS);
      },
      () => {
        if (!stopped) timer = setTimeout(step, READ_GAP_MS);
      },
    );
  };
  step();
  return stop;
}
EOF_FILE
echo "  wrote            src/lib/offline/qr-scanner.ts"
cat > src/routes/scan.tsx <<'EOF_FILE'
import { useMutation } from "convex/react";
import { ArrowLeft, Camera, Check, CircleCheck, Clock, TriangleAlert, X } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router";

import { api } from "../../convex/_generated/api";
import { NeedsConnection } from "@/components/needs-connection";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";
import { CameraError, startScanner, type CameraProblem } from "@/lib/offline/qr-scanner";
import {
  relayAll, relayLabels, relaySummary, type RelayLine, type RelayOutcome,
} from "@/lib/offline/relay";
import { useOnline } from "@/lib/offline/status";
import { readPart, unpackTransfer, type TransferPart } from "@/lib/offline/transfer-code";
import { PageShell } from "@/routes/page-shell";

/**
 * Scan a teammate's QR and upload the reports in it (data transfer plan,
 * section 6). The reports go from the camera straight to the server, one
 * call each, under the name of the scout who wrote them. Nothing is kept on
 * this device.
 */

const CAMERA_HELP: Record<CameraProblem, string> = {
  denied:
    "CircuitScout is not allowed to use the camera. Allow the camera for this site in your browser's site settings (on an iPhone: Settings, then the browser or CircuitScout, then Camera), then try again.",
  unsupported: "This browser cannot use the camera on this page. Open CircuitScout in Chrome or Safari, over https.",
  none: "No camera was found on this device.",
  failed: "The camera could not be started. Close other apps that are using it, then try again.",
};

type Progress = { id: string; have: number; count: number };
type Stage =
  | { name: "scanning"; progress: Progress | null; hint: string | null }
  | { name: "camera-problem"; problem: CameraProblem }
  | { name: "uploading"; outcome: RelayOutcome }
  | { name: "done"; outcome: RelayOutcome };

function LineStatus({ line }: { line: RelayLine }) {
  switch (line.status) {
    case "uploaded":
      return <span className="flex items-center gap-1.5 text-xs"><Check className="size-3.5 shrink-0" aria-hidden /> Uploaded</span>;
    case "received":
      return <span className="text-muted-foreground flex items-center gap-1.5 text-xs"><Check className="size-3.5 shrink-0" aria-hidden /> Already received</span>;
    case "refused":
      return <span className="text-destructive flex items-start gap-1.5 text-xs"><X className="mt-0.5 size-3.5 shrink-0" aria-hidden /><span>Refused: {line.reason}</span></span>;
    case "notUploaded":
      return <span className="text-destructive flex items-start gap-1.5 text-xs"><TriangleAlert className="mt-0.5 size-3.5 shrink-0" aria-hidden /><span>Not uploaded</span></span>;
    case "uploading":
      return <span className="text-muted-foreground flex items-center gap-1.5 text-xs"><Clock className="size-3.5 shrink-0" aria-hidden /> Uploading…</span>;
    default:
      return <span className="text-muted-foreground flex items-center gap-1.5 text-xs"><Clock className="size-3.5 shrink-0" aria-hidden /> Waiting</span>;
  }
}

export default function ScanPage() {
  const online = useOnline();
  const relay = useMutation(api.transfer.relay);
  const videoRef = useRef<HTMLVideoElement>(null);
  const [stage, setStage] = useState<Stage>({ name: "scanning", progress: null, hint: null });
  // Bumped to start the camera again.
  const [attempt, setAttempt] = useState(0);

  const onlineRef = useRef(online);
  useEffect(() => {
    onlineRef.current = online;
  }, [online]);

  const upload = useCallback(async (parts: TransferPart[]) => {
    let transfer;
    try {
      transfer = await unpackTransfer(parts);
    } catch {
      setStage({ name: "scanning", progress: null, hint: "That code could not be read. Hold steady and scan it again." });
      setAttempt((n) => n + 1);
      return;
    }
    if (transfer.reports.length === 0) {
      setStage({ name: "scanning", progress: null, hint: "That code has no reports in it." });
      setAttempt((n) => n + 1);
      return;
    }
    const outcome = await relayAll(
      transfer,
      relayLabels(transfer.reports),
      // The server checks the shape of every report; here it is only text from a camera.
      (author, report) => relay({ author, report: report as Parameters<typeof relay>[0]["report"] }),
      () => onlineRef.current,
      (next) => setStage({ name: "uploading", outcome: next }),
    );
    setStage({ name: "done", outcome });
  }, [relay]);

  const scanning = stage.name === "scanning";
  useEffect(() => {
    const video = videoRef.current;
    if (!scanning || !online || !video) return;
    let over = false;
    let stop: (() => void) | null = null;
    let current: { id: string; count: number; parts: Map<number, TransferPart> } | null = null;

    const onText = (text: string) => {
      if (over) return;
      const part = readPart(text);
      if (!part) {
        setStage((s) => (s.name === "scanning" && s.hint === null
          ? { ...s, hint: "That is not a CircuitScout code. Ask your teammate to open Show my QR." }
          : s));
        return;
      }
      // A different id: the other phone's reports changed. Start again.
      if (!current || current.id !== part.id || current.count !== part.count) {
        current = { id: part.id, count: part.count, parts: new Map() };
      }
      if (current.parts.has(part.number)) return;
      current.parts.set(part.number, part);
      const have = current.parts.size;
      setStage({ name: "scanning", progress: { id: current.id, have, count: current.count }, hint: null });
      if (have === current.count) {
        over = true;
        stop?.();
        void upload([...current.parts.values()]);
      }
    };

    startScanner(video, onText).then(
      (stopper) => {
        if (over) stopper();
        else stop = stopper;
      },
      (error: unknown) => {
        if (over) return;
        setStage({ name: "camera-problem", problem: error instanceof CameraError ? error.problem : "failed" });
      },
    );
    return () => {
      over = true;
      stop?.();
    };
  }, [scanning, online, attempt, upload]);

  const again = () => {
    setStage({ name: "scanning", progress: null, hint: null });
    setAttempt((n) => n + 1);
  };
  const back = (
    <Button variant="outline" render={<Link to="/" />}>
      <ArrowLeft className="size-4" /> Dashboard
    </Button>
  );

  if (stage.name === "uploading" || stage.name === "done") {
    const summary = relaySummary(stage.outcome);
    return (
      <PageShell title="Scan a QR" actions={back}>
        {stage.name === "done" ? (
          <div
            role="status"
            className={[
              "space-y-3 rounded-lg border p-4",
              summary.complete ? "border-primary/40 bg-primary/5" : "border-destructive/40 bg-destructive/5",
            ].join(" ")}
          >
            <p className="flex items-center gap-2 text-base font-semibold">
              {summary.complete
                ? <CircleCheck className="text-primary size-5 shrink-0" aria-hidden />
                : <TriangleAlert className="text-destructive size-5 shrink-0" aria-hidden />}
              {summary.title}
            </p>
            <p className="text-sm">{summary.detail}</p>
            <div className="flex flex-wrap gap-2">
              <Button render={<Link to="/" />}>Done</Button>
              <Button variant="outline" onClick={again}>
                {summary.complete ? "Scan another" : "Scan again"}
              </Button>
            </div>
          </div>
        ) : (
          <div role="status" className="rounded-lg border p-4 text-sm font-medium">
            Uploading. Keep this page open.
          </div>
        )}
        <Card>
          <CardHeader>
            <CardTitle>Reports in this code</CardTitle>
            <CardDescription>
              Each report is filed under the scout who wrote it. Their own
              list clears when their device is back online.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-2">
            {stage.outcome.lines.map((line) => (
              <div key={line.id} className="space-y-1 rounded-md border p-3">
                <p className="truncate text-sm font-medium">{line.label}</p>
                <LineStatus line={line} />
              </div>
            ))}
          </CardContent>
        </Card>
      </PageShell>
    );
  }

  if (!online) {
    return (
      <PageShell title="Scan a QR" actions={back}>
        <NeedsConnection
          title="Scanning needs a connection"
          description="The reports in a code are uploaded as soon as it is read. Find a connection, then scan."
        />
      </PageShell>
    );
  }

  if (stage.name === "camera-problem") {
    return (
      <PageShell title="Scan a QR" actions={back}>
        <div role="alert" className="mx-auto flex max-w-sm flex-col items-center gap-3 rounded-lg border border-dashed p-8 text-center">
          <Camera className="text-muted-foreground size-8" aria-hidden />
          <p className="text-base font-medium">The camera is not available</p>
          <p className="text-muted-foreground text-sm">{CAMERA_HELP[stage.problem]}</p>
          <Button onClick={again}>Try again</Button>
        </div>
      </PageShell>
    );
  }

  const progress = stage.progress;
  return (
    <PageShell
      title="Scan a QR"
      description="Point the camera at a teammate's Show my QR screen. Their reports upload under their name."
      actions={back}
    >
      <div className="mx-auto w-full max-w-md space-y-3">
        <div className="bg-muted relative aspect-square overflow-hidden rounded-lg">
          <video ref={videoRef} className="size-full object-cover" muted playsInline aria-label="Camera" />
        </div>
        <p role="status" className="text-center text-sm font-medium tabular-nums">
          {progress
            ? `${progress.have} of ${progress.count} part${progress.count === 1 ? "" : "s"} read`
            : "Looking for a code…"}
        </p>
        <p className="text-muted-foreground text-center text-xs">
          {stage.hint
            ?? "Hold steady and fill the square with the code. It shows its parts in turn, so keep pointing until every part is read."}
        </p>
      </div>
    </PageShell>
  );
}
EOF_FILE
echo "  wrote            src/routes/scan.tsx"
cat > src/components/scan-link.tsx <<'EOF_FILE'
import { ScanLine } from "lucide-react";
import { Link } from "react-router";

import { Button } from "@/components/ui/button";
import { useOnline } from "@/lib/offline/status";

/**
 * On the dashboards, for anyone who is online: scan a teammate's Show my QR
 * to upload the reports they saved offline (data transfer plan, D-9).
 */
export function ScanQrLink() {
  const online = useOnline();
  if (!online) return null;
  return (
    <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-2 rounded-lg border p-3">
      <p className="text-muted-foreground min-w-0 flex-1 text-sm">
        A teammate with no connection? Scan their QR to upload their reports.
      </p>
      <Button variant="outline" size="sm" render={<Link to="/scan" />}>
        <ScanLine className="size-3.5" aria-hidden /> Scan a QR
      </Button>
    </div>
  );
}
EOF_FILE
echo "  wrote            src/components/scan-link.tsx"

# ---- 3. Edits --------------------------------------------------------------
say "transfer.relay, route, dashboards"
bun .patch-qr-scan.mjs write

say "Done"
cat <<'TXT'
Next:
  1. bunx tsc -p convex && bun run typecheck && bun run lint && bun run build
  2. bun run go          (pushes transfer.relay). For production, deploy
     Convex before, or together with, the site.
  3. Two phones, both signed in on the same team, on a production build
     (the camera needs https). Try both pairings, because the two kinds of
     phone read codes differently: an iPhone scanning an Android phone, and
     an Android phone scanning an iPhone.
     a. Phone A offline: save two or three reports, open Show my QR.
     b. Phone B online: dashboard, Scan a QR, allow the camera, point at A.
        The line counts the parts, then each report shows Uploaded and the
        page says "Transfer complete" with A's name.
     c. Check the reports are on the server under A's name, once each.
     d. Scan A again: every report says Already received.
     e. Phone A back online: Waiting to send empties with "already sent by
        QR" and nothing is written again.
     f. A code with ten reports: every part is read without stalling.
     g. Bright venue and dim room both work.
     h. A scout on a different team scans A: "This code belongs to a scout
        on another team", and nothing is uploaded.
  4. If parts are missed or reading is slow, two numbers tune it:
     PART_MS in src/components/my-qr.tsx (time each part is shown; raise
     it) and PART_CHARS in src/lib/offline/transfer-code.ts (size of each
     part; lower it for a coarser, easier code).
TXT
