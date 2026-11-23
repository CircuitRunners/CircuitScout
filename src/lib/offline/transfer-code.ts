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
