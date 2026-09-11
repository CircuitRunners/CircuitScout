import { useAuthActions } from "@convex-dev/auth/react";
import { useQuery } from "convex/react";
import { LogOut, Menu, User } from "lucide-react";
import { Link, NavLink } from "react-router";

import { api } from "../../convex/_generated/api";
import { ConnectionIndicator } from "@/components/connection-indicator";
import { ThemeToggle } from "@/components/theme-toggle";
import { Button } from "@/components/ui/button";
import { Sheet, SheetContent, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { useUIStore } from "@/stores/ui-store";

type NavItem = { to: string; label: string; adminOnly?: boolean };

const NAV: ReadonlyArray<NavItem> = [
  { to: "/", label: "Dashboard" },
  { to: "/pit", label: "Pit Scouting" },
  { to: "/scout", label: "Match Scouting" },
  { to: "/teams", label: "Teams" },
  { to: "/matches", label: "Matches" },
  { to: "/picklists", label: "Pick Lists" },
  { to: "/archive", label: "Past Events" },
  { to: "/admin", label: "Admin", adminOnly: true },
];

function linkClass({ isActive }: { isActive: boolean }): string {
  return [
    "rounded-md px-3 py-2 text-sm transition-colors",
    isActive
      ? "bg-accent text-accent-foreground font-medium"
      : "text-muted-foreground hover:text-foreground",
  ].join(" ");
}

export function AppNav() {
  const { signOut } = useAuthActions();
  const profile = useQuery(api.profiles.me);
  const navOpen = useUIStore((s) => s.navOpen);
  const setNavOpen = useUIStore((s) => s.setNavOpen);

  const items = NAV.filter(
    (i) => !i.adminOnly || profile?.role === "admin" || profile?.role === "teamAdmin",
  );

  return (
    <header className="bg-background sticky top-0 z-40 border-b">
      <div className="mx-auto flex h-14 w-full max-w-6xl items-center gap-2 px-4">
        <Button
          variant="ghost"
          size="icon"
          className="md:hidden"
          aria-label="Open navigation"
          onClick={() => setNavOpen(true)}
        >
          <Menu className="size-5" />
        </Button>

        <NavLink to="/" className="text-muted-foreground flex items-center gap-2 font-semibold tracking-tight">          
        <img
            src="/logo.png"
            alt=""
            className="size-6 shrink-0"
            onError={(e) => { e.currentTarget.style.display = "none"; }}
        />
          CircuitScout
        </NavLink>

        <nav className="ml-4 hidden items-center gap-1 md:flex">
          {items.map((item) => (
            <NavLink key={item.to} to={item.to} end={item.to === "/"} className={linkClass}>
              {item.label}
            </NavLink>
          ))}
        </nav>

        <div className="ml-auto flex items-center gap-2">
          <ConnectionIndicator />
          <ThemeToggle />
          <Button
            variant="ghost"
            size="icon"
            aria-label="Edit my profile"
            render={<Link to="/profile" />}
          >
            <User className="size-4" />
          </Button>
          <Button
            variant="ghost"
            size="icon"
            aria-label="Sign out"
            onClick={() => void signOut()}
          >
            <LogOut className="size-4" />
          </Button>
        </div>
      </div>

      <Sheet open={navOpen} onOpenChange={setNavOpen}>
        <SheetContent side="left" className="w-72">
          <SheetHeader>
            <SheetTitle className="flex items-center gap-2">
              <img
                src="/logo.png"
                alt=""
                className="size-5 shrink-0"
                onError={(e) => { e.currentTarget.style.display = "none"; }}
              />
              CircuitScout
            </SheetTitle>
          </SheetHeader>
          <nav className="flex flex-col gap-1 p-4">
            {items.map((item) => (
              <NavLink
                key={item.to}
                to={item.to}
                end={item.to === "/"}
                className={linkClass}
                onClick={() => setNavOpen(false)}
              >
                {item.label}
              </NavLink>
            ))}
          </nav>
        </SheetContent>
      </Sheet>
    </header>
  );
}
