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
