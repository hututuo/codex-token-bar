import { FloatingGuideOverlayApp } from "../floating/FloatingGuideOverlayApp";
import { useMemo } from "react";
import { FloatingWindowApp } from "../floating/FloatingWindowApp";
import { desktopPlatform } from "../platform/desktop";
import { StatusPanelApp } from "../status/StatusPanelApp";
import { DashboardApp } from "./DashboardApp";

export function App() {
  const surface = useMemo(getSurfaceMode, []);
  const guide = new URLSearchParams(window.location.search).get("surface");
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
