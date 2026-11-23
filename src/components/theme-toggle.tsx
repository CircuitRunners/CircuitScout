import { useSyncExternalStore } from "react";
import { useTheme } from "next-themes";
import { Monitor, Moon, Sun } from "lucide-react";

import { Button } from "@/components/ui/button";

const ORDER = ["light", "dark", "system"] as const;
type ThemeName = (typeof ORDER)[number];

const subscribeNothing = () => () => {};

export function ThemeToggle() {
  const { theme, setTheme } = useTheme();
  // False for the first render only, so the icon never disagrees with the
  // theme next-themes settles on. Same result as the old mount effect,
  // without a second render triggered from inside an effect.
  const mounted = useSyncExternalStore(subscribeNothing, () => true, () => false);

  const current: ThemeName =
    theme === "light" || theme === "dark" ? theme : "system";

  const next = (): ThemeName => {
    const index = ORDER.indexOf(current);
    return ORDER[(index + 1) % ORDER.length] ?? "system";
  };

  const Icon = current === "light" ? Sun : current === "dark" ? Moon : Monitor;

  return (
    <Button
      variant="ghost"
      size="icon"
      aria-label={`Theme: ${current}. Switch to ${next()}.`}
      onClick={() => setTheme(next())}
    >
      {mounted ? <Icon className="size-4" /> : <span className="size-4" />}
    </Button>
  );
}
