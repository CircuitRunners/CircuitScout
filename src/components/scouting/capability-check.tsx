import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";

export function CapabilityCheck({
  id,
  label,
  description,
  checked,
  onChange,
}: {
  id: string;
  label: string;
  description?: string;
  checked: boolean;
  onChange: (next: boolean) => void;
}) {
  return (
    <label
      htmlFor={id}
      className="hover:bg-accent/50 flex min-h-14 cursor-pointer items-center gap-3 rounded-lg border p-3"
    >
      <Checkbox
        id={id}
        checked={checked}
        onCheckedChange={(next: boolean) => onChange(Boolean(next))}
      />
      <div className="space-y-0.5">
        <Label htmlFor={id} className="cursor-pointer text-base">{label}</Label>
        {description ? (
          <p className="text-muted-foreground text-xs">{description}</p>
        ) : null}
      </div>
    </label>
  );
}
