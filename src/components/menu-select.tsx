import { ChevronDown } from "lucide-react";

import { Button } from "@/components/ui/button";
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuRadioGroup,
  DropdownMenuRadioItem, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

export type MenuOption<T extends string> = { value: T; label: string };

/**
 * The app's dropdown: an outline button with a chevron that opens a menu of
 * choices, built like the Teams page's Sort menu. Used instead of a native
 * <select>, which draws in the browser's own style and ignores the app's
 * light and dark themes.
 */
export function MenuSelect<T extends string>({
  label,
  value,
  options,
  onChange,
  placeholder = "Choose",
  invalid = false,
  className,
}: {
  /** What the menu picks, for screen readers ("X axis", "Battery 1 type"). */
  label: string;
  /** "" while nothing is picked; the placeholder shows instead. */
  value: T | "";
  options: ReadonlyArray<MenuOption<T>>;
  onChange: (next: T) => void;
  placeholder?: string;
  invalid?: boolean;
  className?: string;
}) {
  const current = options.find((o) => o.value === value);
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button size="sm" variant="outline"
            aria-label={current ? `${label}: ${current.label}` : label}
            aria-invalid={invalid || undefined}
            className={[
              "min-w-0 justify-between",
              current ? "" : "text-muted-foreground",
              invalid ? "border-destructive" : "",
              className ?? "",
            ].join(" ")} />
        }
      >
        <span className="truncate">{current?.label ?? placeholder}</span>
        <ChevronDown className="size-3 shrink-0" />
      </DropdownMenuTrigger>
      <DropdownMenuContent className="max-h-80 min-w-40">
        <DropdownMenuRadioGroup value={value}
          onValueChange={(next) => onChange(next as T)}>
          {options.map((o) => (
            <DropdownMenuRadioItem key={o.value} value={o.value} className="py-2.5">
              {o.label}
            </DropdownMenuRadioItem>
          ))}
        </DropdownMenuRadioGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
