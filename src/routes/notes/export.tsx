import { useConvex, useQuery } from "convex/react";
import { Download, LoaderCircle } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { api } from "../../../convex/_generated/api";
import { Button } from "@/components/ui/button";
import {
  Card, CardContent, CardDescription, CardHeader, CardTitle,
} from "@/components/ui/card";

/**
 * Pit notes and match notes as a two-sheet workbook. No cooldown: notes are
 * a few rows of text, nothing like the 2026 workbook's reads.
 */
export function NotesExport() {
  const convex = useConvex();
  const me = useQuery(api.profiles.me);
  const [busy, setBusy] = useState(false);

  if (me?.role !== "admin" && me?.role !== "teamAdmin") return null;

  const download = async () => {
    setBusy(true);
    try {
      const data = await convex.query(api.notes.forExport, {});
      if (!data) {
        toast.error("No active event");
        return;
      }
      // Dynamic import: nobody downloads the xlsx library until they export.
      const XLSX = await import("xlsx");
      const book = XLSX.utils.book_new();
      XLSX.utils.book_append_sheet(book,
        XLSX.utils.json_to_sheet(data.pit.length > 0 ? data.pit : [{}]), "Pit notes");
      XLSX.utils.book_append_sheet(book,
        XLSX.utils.json_to_sheet(data.matches.length > 0 ? data.matches : [{}]), "Match notes");
      XLSX.writeFile(book, `circuitscout-${data.eventKey}-notes.xlsx`);
      toast.success("Downloaded", {
        description: `${data.pit.length} pit notes · ${data.matches.length} match notes.`,
      });
    } catch (error) {
      toast.error("Could not build the workbook", {
        description: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>Export notes</CardTitle>
        <CardDescription>
          Two sheets: pit notes{me.role === "admin" ? " from every team" : " from your team"},
          and every match note at this event.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <Button variant="outline" disabled={busy} onClick={() => void download()}>
          {busy ? <LoaderCircle className="size-4 animate-spin" /> : <Download className="size-4" />}
          Download .xlsx
        </Button>
      </CardContent>
    </Card>
  );
}
