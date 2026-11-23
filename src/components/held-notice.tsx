import { useEffect } from "react";
import { CloudOff } from "lucide-react";

import { useOnline } from "@/lib/offline/status";

/**
 * A report submitted with no connection is held in this tab's memory and
 * sent when the connection returns, but only while the app stays open
 * (offline plan, section 7.6). This says so, above the submit button, and
 * asks the browser to warn before the tab is closed or reloaded.
 *
 * It does not make the report safe. Durable storage of held reports is the
 * data transfer plan.
 */
export function HeldNotice({ saving }: { saving: boolean }) {
  const online = useOnline();
  const held = saving && !online;

  useEffect(() => {
    if (!held) return;
    const warn = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      // Older browsers need a return value to show the prompt.
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [held]);

  if (!held) return null;
  return (
    <p
      role="status"
      className="bg-destructive flex items-start gap-2 rounded-lg p-3 text-sm font-medium text-white"
    >
      <CloudOff className="mt-0.5 size-4 shrink-0" aria-hidden />
      <span>
        Held on this device. Keep CircuitScout open until it sends. It will send
        by itself when you are back online.
      </span>
    </p>
  );
}
