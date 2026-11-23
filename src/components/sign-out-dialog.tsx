import { useState } from "react";

import { MyQrDialog } from "@/components/my-qr";
import { Button } from "@/components/ui/button";
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { useHeldItems } from "@/lib/offline/held";
import { useOnline } from "@/lib/offline/status";
import { cancelSignOut, useSignOutQuestion } from "@/lib/offline/use-sign-out";

/**
 * Asked before signing out with reports still on the device: signing out
 * discards them (data transfer plan, D-2). Offers the QR first: it is the
 * way to hand the reports to a teammate with a connection. Mounted once, in
 * the app layout.
 */
export function SignOutDialog() {
  const question = useSignOutQuestion();
  const online = useOnline();
  const count = question?.count ?? 0;
  const [showQr, setShowQr] = useState(false);
  const canShowQr = useHeldItems().some((item) => item.status === "waiting");
  return (
    <>
    <Dialog open={question !== null} onOpenChange={(open) => { if (!open) cancelSignOut(); }}>
      <DialogContent className="max-w-sm">
        <DialogHeader>
          <DialogTitle>Sign out and lose unsent reports?</DialogTitle>
          <DialogDescription>
            {count === 1
              ? "1 report on this device has not been sent."
              : `${count} reports on this device have not been sent.`}{" "}
            Signing out discards {count === 1 ? "it" : "them"}.{" "}
            {online
              ? "You are online: cancel, and wait for Waiting to send on the dashboard to empty."
              : "To keep them, cancel and stay signed in until you are back online, or have a teammate who is online scan your QR first."}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" onClick={cancelSignOut}>Cancel</Button>
          {canShowQr ? (
            <Button
              variant="outline"
              onClick={() => {
                cancelSignOut();
                setShowQr(true);
              }}
            >
              Show my QR
            </Button>
          ) : null}
          <Button variant="destructive" onClick={() => question?.proceed()}>
            Sign out and discard
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
    <MyQrDialog open={showQr} onOpenChange={setShowQr} />
    </>
  );
}
