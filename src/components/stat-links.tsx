import { ExternalLink } from "lucide-react";
import { useState } from "react";

type Target =
  | { kind: "event"; eventKey: string }
  | { kind: "match"; eventKey: string; matchKey: string }
  | { kind: "team"; eventKey: string; teamNumber: number };

const TBA = "https://www.thebluealliance.com";
const STATBOTICS = "https://statbotics.popcornpenguins.com";
const MATCH13 = "https://www.match13.com";

/** The season, from the event key's first four characters. */
function season(eventKey: string): number | null {
  const year = Number.parseInt(eventKey.slice(0, 4), 10);
  return Number.isNaN(year) ? null : year;
}

/**
 * All three sites key events and matches the same way, so one key serves
 * every link. Team pages are pinned to the event's season, so an archived
 * event's links still land on the year it was played.
 */
function urls(target: Target) {
  if (target.kind === "event") {
    const key = encodeURIComponent(target.eventKey);
    return {
      tba: `${TBA}/event/${key}`,
      statbotics: `${STATBOTICS}/event/${key}`,
      match13: `${MATCH13}/event/${key}`,
    };
  }
  if (target.kind === "match") {
    const key = encodeURIComponent(target.matchKey);
    return {
      tba: `${TBA}/match/${key}`,
      statbotics: `${STATBOTICS}/match/${key}`,
      match13: `${MATCH13}/match/${key}`,
    };
  }
  const n = target.teamNumber;
  const year = season(target.eventKey);
  return {
    tba: `${TBA}/team/${n}${year ? `/${year}` : ""}`,
    statbotics: `${STATBOTICS}/team/${n}${year ? `/${year}` : ""}`,
    match13: `${MATCH13}/team/${n}${year ? `?year=${year}` : ""}`,
  };
}

/**
 * The logos live in public/ and can go missing — a renamed file, a failed
 * deploy. Falls back to a generic external-link icon rather than leaving a
 * broken image in a heading.
 */
function SiteLink({ href, src, name }: { href: string; src: string; name: string }) {
  const [failed, setFailed] = useState(false);
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer noopener"
      title={name}
      aria-label={`Open on ${name}`}
      className="text-muted-foreground hover:text-foreground hover:bg-accent inline-flex size-8 shrink-0 items-center justify-center rounded-md transition-colors"
    >
      {failed ? (
        <ExternalLink className="size-4" />
      ) : (
        <img src={src} alt="" className="size-4 rounded-sm object-contain"
          onError={() => setFailed(true)} />
      )}
    </a>
  );
}

/**
 * The Blue Alliance, Statbotics and match13, icon only. Sized as 32px tap
 * targets so a thumb on a phone hits the logo it meant to.
 */
export function StatLinks(props: Target) {
  const u = urls(props);
  return (
    <span className="inline-flex shrink-0 items-center self-center">
      <SiteLink href={u.tba} src="/tba.png" name="The Blue Alliance" />
      <SiteLink href={u.statbotics} src="/statbotics.png" name="Statbotics" />
      <SiteLink href={u.match13} src="/match13.png" name="match13" />
    </span>
  );
}
