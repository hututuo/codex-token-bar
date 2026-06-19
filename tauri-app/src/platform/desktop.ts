import {
  notifyFloatingWindowHidden,
  onFloatingSettingsChanged,
  onFloatingWindowHidden,
  onLiveRateSnapshot,
  publishFloatingSettings,
} from "./desktopEvents";
import { isDesktopRuntimeAvailable } from "./desktopBridge";
import {
  onFloatingWindowMoved,
  resizeFloatingWindow,
  setFloatingWindowPosition,
  startFloatingWindowDrag,
  type DesktopPosition,
} from "./floatingWindowControls";
import {
  hideFloatingWindow,
  hideStatusPanelWindow,
  setStatusTrayReadout,
  showDashboardWindow,
  showFloatingWindow,
  showStatusPanelWindow,
  startLiveRateStream,
  stopLiveRateStream,
} from "./surfaceCommands";

export type SurfaceMode = "dashboard" | "floating" | "status";
export type { DesktopPosition };

export const desktopPlatform = {
  isAvailable: isDesktopRuntimeAvailable,
  getSurfaceMode,
  showFloatingWindow,
  hideFloatingWindow,
  showStatusPanelWindow,
  hideStatusPanelWindow,
  showDashboardWindow,
  notifyFloatingWindowHidden,
  onFloatingWindowHidden,
  publishFloatingSettings,
  onFloatingSettingsChanged,
  resizeFloatingWindow,
  startFloatingWindowDrag,
  setFloatingWindowPosition,
  onFloatingWindowMoved,
  setStatusTrayReadout,
  startLiveRateStream,
  stopLiveRateStream,
  onLiveRateSnapshot,
};

function getSurfaceMode(): SurfaceMode {
  const surface = new URLSearchParams(window.location.search).get("surface");
  if (surface === "floating" || surface === "status") {
    return surface;
  }
  return "dashboard";
}
