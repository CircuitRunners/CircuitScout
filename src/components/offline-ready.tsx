import { useEffect, useState, useSyncExternalStore } from "react";
import { CloudCheck, CloudDownload } from "lucide-react";

import { useOnline } from "@/lib/offline/status";
import { cacheKey, readCached, savedTick, subscribeSaved } from "@/lib/offline/store";

const AT = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

/** Whether the service worker that serves the app's files offline is in place. */
function useAppFilesSaved(): boolean {
  const [saved, setSaved] = useState(false);
  useEffect(() => {
    if (!("serviceWorker" in navigator)) return;
    let current = true;
    // Resolves once a worker is active; never, when none is registered (dev).
    void navigator.serviceWorker.ready.then(() => {
      if (current) setSaved(true);
    });
    return () => {
      current = false;
    };
  }, []);
  return saved;
}

function isInstalled(): boolean {
  if (window.matchMedia("(display-mode: standalone)").matches) return true;
  // iOS Safari's own flag for a home screen app.
  return (navigator as { standalone?: boolean }).standalone === true;
}

const isAppleTouch = (): boolean =>
  /iPhone|iPad|iPod/.test(navigator.userAgent) ||
  (navigator.userAgent.includes("Macintosh") && navigator.maxTouchPoints > 1);

/**
 * One line on the dashboard that lets a lead scout check a phone before it
 * goes into the stands (offline plan, section 2). "Offline ready" means both
 * halves are on the device: the app's files, and each list in `lists`.
 *
 * `lists` are Convex function names as "module:function", each with a hint
 * for the scout when that list is not saved yet.
 */
export function OfflineReady({
  lists,
}: {
  lists: ReadonlyArray<{ fn: string; missing: string }>;
}) {
  const online = useOnline();
  const filesSaved = useAppFilesSaved();
  // Re-read when the store writes; the tick itself is not used.
  useSyncExternalStore(subscribeSaved, savedTick);

  // No service worker: a development server, or a browser without support.
  // Saying anything about offline here would be a guess.
  if (!filesSaved) return null;

  let oldest: number | null = null;
  let firstMissing: string | null = null;
  for (const list of lists) {
    const key = cacheKey(list.fn, {});
    const hit = key === null ? undefined : readCached(key);
    if (!hit) {
      firstMissing ??= list.missing;
      continue;
    }
    if (oldest === null || hit.savedAt < oldest) oldest = hit.savedAt;
  }

  const ready = firstMissing === null && oldest !== null;
  const installHint = isInstalled()
    ? null
    : isAppleTouch()
      ? "For the most reliable offline use, tap Share, then Add to Home Screen."
      : "For the most reliable offline use, install CircuitScout from your browser's menu.";

  return (
    <div className="text-muted-foreground space-y-1 text-xs">
      <p className="flex items-center gap-1.5">
        {ready ? (
          <CloudCheck className="size-3.5 shrink-0 text-green-600 dark:text-green-400" aria-hidden />
        ) : (
          <CloudDownload className="size-3.5 shrink-0" aria-hidden />
        )}
        {ready && oldest !== null ? (
          <span>
            <span className="text-foreground font-medium">Offline ready.</span>{" "}
            {online ? `Last saved ${AT.format(oldest)}.` : `Saved ${AT.format(oldest)}.`}
          </span>
        ) : (
          <span>Not ready for offline yet. {firstMissing ?? "Waiting for the event data."}</span>
        )}
      </p>
      {installHint ? <p>{installHint}</p> : null}
    </div>
  );
}
