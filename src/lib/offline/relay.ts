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
