import { LoaderCircle } from "lucide-react";
import { useState } from "react";

/**
 * The app's loading indicator: the team's wheel, spinning. Drop-in for the
 * spinning lucide circle; size it with the same classes (size-4, size-5...).
 * If public/loading-wheel.png is missing it falls back to the plain circle
 * rather than showing a broken image.
 */
export function LoadingWheel({ className }: { className?: string }) {
  const [failed, setFailed] = useState(false);
  const classes = ["shrink-0 animate-spin", className ?? ""].join(" ");
  if (failed) return <LoaderCircle aria-hidden className={classes} />;
  return (
    <img src="/loading-wheel.png" alt="" aria-hidden draggable={false}
      className={["object-contain select-none", classes].join(" ")}
      onError={() => setFailed(true)} />
  );
}
