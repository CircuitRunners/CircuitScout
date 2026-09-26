import { useMutation, useQuery } from "convex/react";
import { ArrowLeft } from "lucide-react";
import { Link, useNavigate, useParams } from "react-router";

import { api } from "../../../convex/_generated/api";
import { NoteEditor } from "./note-editor";
import { PageShell } from "@/routes/page-shell";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";

export default function NotesScoutFormPage() {
  const params = useParams();
  const navigate = useNavigate();
  const matchNumber = Number.parseInt(params.matchNumber ?? "", 10);
  const teamNumber = Number.parseInt(params.teamNumber ?? "", 10);
  const bad = Number.isNaN(matchNumber) || Number.isNaN(teamNumber);
  const data = useQuery(api.notes.matchNote, bad ? "skip" : { matchNumber, teamNumber });
  const save = useMutation(api.notes.saveMatch);

  const back = (
    <Button variant="outline" render={<Link to="/scout" />}>
      <ArrowLeft className="size-4" /> All matches
    </Button>
  );

  if (bad) return <PageShell title="Match notes" description="Bad URL." actions={back} />;
  if (data === undefined) return <PageShell title="Match notes" description="Loading…" actions={back} />;
  if (data === null) {
    return (
      <PageShell title="Match notes" actions={back}
        description={`Team ${teamNumber} is not in Qual ${matchNumber} at the active event.`} />
    );
  }

  return (
    <PageShell
      title={
        <>
          Qual {data.matchNumber} · {data.teamNumber}
          <Badge className={data.alliance === "red" ? "bg-red-600 text-white" : "bg-blue-600 text-white"}>
            {data.alliance === "red" ? "Red" : "Blue"}
          </Badge>
        </>
      }
      description={
        data.notes === null
          ? `${data.nickname}. Your notes on this robot in this match.`
          : `${data.nickname}. You have notes on this robot already; saving replaces them.`
      }
      actions={back}
    >
      <NoteEditor key={`${data.matchNumber}:${data.teamNumber}`} id="match-notes"
        initial={data.notes ?? ""}
        onSave={(notes) => save({ matchNumber, teamNumber, notes })}
        onSaved={() => void navigate("/scout")} />
    </PageShell>
  );
}
