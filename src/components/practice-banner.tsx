import { useMutation, useQuery } from "convex/react";
import { FlaskConical } from "lucide-react";
import { toast } from "sonner";

import { api } from "../../convex/_generated/api";
import { Button } from "@/components/ui/button";

/** Red strip on every page while practice mode is on. */
export function PracticeBanner() {
  const status = useQuery(api.practice.status);
  const setMode = useMutation(api.practice.setMode);
  if (!status?.on) return null;

  return (
    // A fixed dark red: the theme's destructive colour is too light under
    // white text in dark mode.
    <div role="status" className="bg-red-700 text-white dark:bg-red-800">
      <div className="mx-auto flex w-full max-w-6xl flex-wrap items-center gap-x-4 gap-y-2 px-4 py-2">
        <FlaskConical className="size-4 shrink-0" />
        <p className="min-w-0 flex-1 text-sm">
          <strong>Practice mode.</strong> Nothing you submit counts. It is
          saved only for you, marked as practice.
        </p>
        <Button size="sm" variant="outline"
          className="border-white/70 bg-transparent text-white hover:bg-white/15 hover:text-white"
          onClick={() => {
            void setMode({ on: false })
              .then(() => toast.success("Practice mode off. Submissions count again."))
              .catch(() => toast.error("Could not exit practice mode"));
          }}>
          Exit practice mode
        </Button>
      </div>
    </div>
  );
}
