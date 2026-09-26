import { useMutation, useQuery } from "convex/react";
import { ArrowLeft } from "lucide-react";
import { Link, useParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { NoteEditor } from "./note-editor";
import { PageShell } from "@/routes/page-shell";
import { Button } from "@/components/ui/button";

export default function NotesPitFormPage() {
  const params = useParams();
  const teamNumber = Number.parseInt(params.teamNumber ?? "", 10);
  const data = useQuery(api.notes.pitNote, Number.isNaN(teamNumber) ? "skip" : { teamNumber });
  const save = useMutation(api.notes.savePit);

  const back = (
    <Button variant="outline" render={<Link to="/pit" />}>
      <ArrowLeft className="size-4" /> All teams
    </Button>
  );

  if (Number.isNaN(teamNumber)) return <PageShell title="Pit notes" description="Bad URL." actions={back} />;
  if (data === undefined) return <PageShell title="Pit notes" description="Loading…" actions={back} />;
  if (data === null) {
    return <PageShell title="Pit notes" description="That team is not at the active event." actions={back} />;
  }

  return (
    <PageShell
      title={`${data.teamNumber} · ${data.nickname}`}
      description={
        data.note
          ? `Your team's pit notes, last saved by ${data.note.scoutName} ${new Date(data.note.updatedAt).toLocaleString()}.`
          : "Your team's pit notes. Anyone on your team can add to them."
      }
      actions={back}
    >
      <NoteEditor key={data.teamNumber} id="pit-notes"
        initial={data.note?.notes ?? ""}
        onSave={(notes) => save({ teamNumber, notes })} />
    </PageShell>
  );
}
