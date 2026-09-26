import { useSeason } from "@/lib/season";
import { PageShell } from "@/routes/page-shell";

/**
 * For pages that only exist for seasons with their own forms. Says so plainly
 * rather than showing another season's page with nothing in it.
 */
export function NotAvailable({ title }: { title: string }) {
  const { year } = useSeason();
  return (
    <PageShell title={title}>
      <p className="text-muted-foreground rounded-lg border border-dashed p-8 text-center text-sm">
        CircuitScout has no {year ?? "this season's"} forms yet, so this event is
        scouted with notes and {title.toLowerCase()} has nothing to show.
      </p>
    </PageShell>
  );
}
