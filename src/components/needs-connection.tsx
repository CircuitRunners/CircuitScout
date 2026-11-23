import { CloudOff } from "lucide-react";

/**
 * Shown in place of an endless spinner when a page has nothing it can show
 * without a connection. `fullPage` centres it on the screen, for use outside
 * the app layout (the sign-in gate).
 */
export function NeedsConnection({
  title = "Needs a connection",
  description = "This page will load when you are back online.",
  fullPage = false,
}: {
  title?: string;
  description?: string;
  fullPage?: boolean;
}) {
  const body = (
    <div
      role="status"
      className="text-muted-foreground mx-auto flex max-w-sm flex-col items-center gap-3 rounded-lg border border-dashed p-8 text-center"
    >
      <CloudOff className="size-8" aria-hidden />
      <p className="text-foreground text-base font-medium">{title}</p>
      <p className="text-sm">{description}</p>
    </div>
  );
  if (!fullPage) return body;
  return <div className="flex min-h-svh items-center justify-center p-6">{body}</div>;
}
