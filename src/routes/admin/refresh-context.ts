import { useConvex } from "convex/react";
import {
  getFunctionName, makeFunctionReference,
  type FunctionReference, type FunctionReturnType, type OptionalRestArgs,
} from "convex/server";
import { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import { toast } from "sonner";

export type Refresher = () => Promise<void>;
export type Registry = {
  register: (key: string, fn: Refresher) => () => void;
  /** Run the named refreshers, or every registered one when no keys are given. */
  refresh: (keys?: string[]) => Promise<void>;
};

// Outside the admin page there is no registry, and refreshing is a no-op.
export const RefreshContext = createContext<Registry>({
  register: () => () => {},
  refresh: async () => {},
});

export const useAdminRefresh = () => useContext(RefreshContext);

/** Put a card's refresh in the page registry under `key`. */
export function useRegisterRefresh(key: string, fn: Refresher) {
  const { register } = useAdminRefresh();
  const latest = useRef(fn);
  useEffect(() => {
    latest.current = fn;
  });
  useEffect(() => register(key, () => latest.current()), [register, key]);
}

/**
 * A query run once on mount and again on refresh — never a live
 * subscription. For admin cards whose queries read every report at the
 * event: subscribed, they re-ran on every submission for as long as the
 * page stayed open.
 */
export function useOnDemand<Q extends FunctionReference<"query">>(
  key: string,
  query: Q,
  ...args: OptionalRestArgs<Q>
) {
  const convex = useConvex();
  const [data, setData] = useState<FunctionReturnType<Q> | undefined>(undefined);
  const [loading, setLoading] = useState(true);
  const [updatedAt, setUpdatedAt] = useState<number | null>(null);

  // Both compared by VALUE. `api.x.y` builds a new object on every access,
  // so depending on the reference itself re-ran this hook's effect after
  // every render: load, set state, render, load again — a loop that froze
  // the page when results came back from the client's cache.
  const name = getFunctionName(query);
  const argsKey = JSON.stringify(args);
  // State is only set once the query settles, never synchronously.
  const load = useCallback((isCurrent: () => boolean) =>
    convex.query(
      makeFunctionReference<"query">(name) as Q,
      ...(JSON.parse(argsKey) as OptionalRestArgs<Q>),
    )
      .then((result) => {
        if (!isCurrent()) return;
        setData(result);
        setUpdatedAt(Date.now());
      })
      .catch((error: unknown) => {
        if (isCurrent()) {
          toast.error("Couldn't refresh", {
            description: error instanceof Error ? error.message : String(error),
          });
        }
      })
      .finally(() => {
        if (isCurrent()) setLoading(false);
      }), [convex, name, argsKey]);

  useEffect(() => {
    let current = true;
    void load(() => current);
    return () => {
      current = false;
    };
  }, [load]);

  const refresh = useCallback(() => {
    setLoading(true);
    return load(() => true);
  }, [load]);

  useRegisterRefresh(key, refresh);
  return { data, loading, updatedAt, refresh };
}
