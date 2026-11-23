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
