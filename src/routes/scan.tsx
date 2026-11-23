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
