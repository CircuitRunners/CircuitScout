import { Link } from "react-router";

import { Button } from "@/components/ui/button";

export default function NotFoundPage() {
  return (
    <div className="flex min-h-svh flex-col items-center justify-center gap-4">
      <p className="text-muted-foreground text-sm">
        404 — that route does not exist.
      </p>
      {/* Base UI uses `render`, not Radix's `asChild`. */}
      <Button variant="outline" render={<Link to="/" />}>
        Back home
      </Button>
    </div>
  );
}
