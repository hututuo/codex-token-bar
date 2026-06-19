import { useMemo } from "react";
import { FloatingWindowApp } from "../floating/FloatingWindowApp";
import { desktopPlatform } from "../platform/desktop";
import { StatusPanelApp } from "../status/StatusPanelApp";
import { DashboardApp } from "./DashboardApp";

export function App() {
  const surface = useMemo(getSurfaceMode, []);
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
