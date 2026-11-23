import { useAction, useMutation } from "convex/react";
import type { FunctionReference, FunctionReturnType, OptionalRestArgs } from "convex/server";
import { useCallback } from "react";

import { useOnline } from "./status";

export const VIEW_ONLY_MESSAGE = "You are offline. This page is view only until you reconnect.";

/**
 * A rejection the caller may or may not handle. Most callers show the error
 * in a toast; a few fire and forget, and for those this must not surface as
 * an unhandled rejection.
 */
function refuse<T>(): Promise<T> {
  const refused = Promise.reject<T>(new Error(VIEW_ONLY_MESSAGE));
  refused.catch(() => {});
  return refused;
}

/**
 * useMutation for pages that are view only offline (offline plan, O-7): pick
 * lists, Admin, attention items. With a connection it is useMutation. Without
 * one the call is refused at once instead of being queued, so nothing on
 * these pages can change while the scout cannot see the result.
 *
 * Scouting forms do NOT use this. Their reports are meant to be held and sent
 * later (src/lib/offline/held.ts).
 */
export function useOnlineMutation<Mutation extends FunctionReference<"mutation">>(
  mutation: Mutation,
): (...args: OptionalRestArgs<Mutation>) => Promise<FunctionReturnType<Mutation>> {
  const run = useMutation(mutation);
  const online = useOnline();
  return useCallback(
    (...args: OptionalRestArgs<Mutation>) => (online ? run(...args) : refuse()),
    [online, run],
  );
}

/** useAction, refused offline in the same way. */
export function useOnlineAction<Action extends FunctionReference<"action">>(
  action: Action,
): (...args: OptionalRestArgs<Action>) => Promise<FunctionReturnType<Action>> {
  const run = useAction(action);
  const online = useOnline();
  return useCallback(
    (...args: OptionalRestArgs<Action>) => (online ? run(...args) : refuse()),
    [online, run],
  );
}
