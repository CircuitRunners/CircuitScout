import { LoaderCircle } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";

/**
 * The whole notes form: one box, one button. Mount it with a key once the
 * saved note has loaded, so `initial` seeds it exactly once.
 */
export function NoteEditor({
  id, initial, onSave, onSaved,
}: {
  id: string;
  initial: string;
  onSave: (notes: string) => Promise<unknown>;
  onSaved?: () => void;
}) {
  const [text, setText] = useState(initial);
  const [saved, setSaved] = useState(initial);
  const [saving, setSaving] = useState(false);
  const dirty = text.trim() !== saved.trim();

  return (
    <div className="space-y-2">
      <Label htmlFor={id}>Notes</Label>
      <Textarea id={id} rows={8} value={text} className="text-base"
        placeholder="What did you see?"
        onChange={(e) => setText(e.target.value)} />
      <Button className="w-full sm:w-auto" disabled={saving || !dirty || text.trim() === ""}
        onClick={() => {
          setSaving(true);
          void onSave(text)
            .then(() => {
              setSaved(text);
              toast.success("Notes saved");
              onSaved?.();
            })
            .catch((error: unknown) =>
              toast.error("Could not save", {
                description: error instanceof Error ? error.message : String(error),
              }))
            .finally(() => setSaving(false));
        }}>
        {saving ? <LoaderCircle className="size-4 animate-spin" /> : null}
        {dirty || saved === "" ? "Save notes" : "Saved"}
      </Button>
    </div>
  );
}
