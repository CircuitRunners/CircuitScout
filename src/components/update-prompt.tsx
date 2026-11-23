import { useEffect } from "react";
import { useLocation } from "react-router";
import { toast } from "sonner";
import { useRegisterSW } from "virtual:pwa-register/react";

const TOAST_ID = "app-update";
const CHECK_EVERY_MS = 60 * 60 * 1000;

/**
 * Scouting forms, for every season (the routes are season-switched, so the
 * 2026 forms and the generic ones share these paths). A scout mid-match must
 * never be offered a reload: it would throw the form away.
 */
const FORM_ROUTES = [/^\/scout\/[^/]+\/[^/]+\/?$/, /^\/pit\/[^/]+\/?$/];

/**
 * The update rule (offline plan, O-6):
 *  - a new version downloads quietly in the background;
 *  - while the app is running it is offered with a Reload button, on every
 *    page except a scouting form;
 *  - nothing ever reloads on its own;
 *  - an app that was fully closed starts on the new version by itself.
 * Renders nothing. Mounted once, in RootLayout.
 */
export function UpdatePrompt() {
  const { pathname } = useLocation();
  const {
    needRefresh: [needRefresh],
    updateServiceWorker,
  } = useRegisterSW({
    onRegisteredSW(_url, registration) {
      if (!registration) return;
      const check = () => {
        if (navigator.onLine) void registration.update().catch(() => {});
      };
      // Browsers only look for a new worker on navigation, and a single-page
      // app that stays open all day never navigates.
      window.setInterval(check, CHECK_EVERY_MS);
      // A phone that was in a pocket for three matches: look when it wakes.
      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "visible") check();
      });
    },
  });

  const onForm = FORM_ROUTES.some((route) => route.test(pathname));

  useEffect(() => {
    if (!needRefresh || onForm) {
      toast.dismiss(TOAST_ID);
      return;
    }
    toast("Update available", {
      id: TOAST_ID,
      description: "Reload to get the latest version of CircuitScout.",
      duration: Infinity,
      action: { label: "Reload", onClick: () => void updateServiceWorker(true) },
    });
  }, [needRefresh, onForm, updateServiceWorker]);

  return null;
}
