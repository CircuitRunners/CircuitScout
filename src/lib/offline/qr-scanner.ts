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
