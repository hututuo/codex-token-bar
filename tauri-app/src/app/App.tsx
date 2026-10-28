import { lazy, Suspense, useMemo } from "react";
import { desktopPlatform } from "../platform/desktop";
import { BusinessStartupGate } from "./BusinessStartupGate";

// Each native window loads its own surface. Shared modules remain Vite-managed chunks.
const QuotaSidebarApp = lazy(() => import("../quota-sidebar/QuotaSidebarApp").then(m => ({ default: m.QuotaSidebarApp })));
const FloatingGuideOverlayApp = lazy(() => import("../floating/FloatingGuideOverlayApp").then(m => ({ default: m.FloatingGuideOverlayApp })));
const FloatingWindowApp = lazy(() => import("../floating/FloatingWindowApp").then(m => ({ default: m.FloatingWindowApp })));
const StatusPanelApp = lazy(() => import("../status/StatusPanelApp").then(m => ({ default: m.StatusPanelApp })));
const DashboardApp = lazy(() => import("./DashboardApp").then(m => ({ default: m.DashboardApp })));

export function App() {
  return <BusinessStartupGate><Suspense fallback={null}><Surface /></Suspense></BusinessStartupGate>;
}

function Surface() {
  const surface = useMemo(getSurfaceMode, []);
  const guide = new URLSearchParams(window.location.search).get("surface");
  if (guide === "quota-sidebar" || guide === "quota-sidebar-detail") return <QuotaSidebarApp />;
  if (guide === "floating-guide-card" || guide === "floating-guide-cursor") {
    return <FloatingGuideOverlayApp cursor={guide === "floating-guide-cursor"} />;
  }
  if (surface === "floating") {
    return <FloatingWindowApp />;
  }
  if (surface === "status") {
    return <StatusPanelApp />;
  }

  return <DashboardApp />;
}

function getSurfaceMode() {
  return desktopPlatform.getSurfaceMode();
}
