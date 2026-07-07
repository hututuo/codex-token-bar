import {
  notifyFloatingWindowHidden,
  onAppSettingsChanged,
  onFloatingSettingsChanged,
  onFloatingWindowHidden,
  onDisplaySurfacesChanged,
  onLiveRateSnapshot,
  publishAppSettings,
  publishDisplaySurfaces,
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
  hideFloatingWindowCommand,
  hideStatusPanelWindow,
  setStatusTrayReadout,
  showDashboardWindow,
  showFloatingWindow,
  showFloatingWindowCommand,
  showStatusPanelWindow,
  startLiveRateStream,
  startLiveRateStreamCommand,
  stopLiveRateStream,
} from "./surfaceCommands";

export type SurfaceMode = "dashboard" | "floating" | "status";
export type { DesktopPosition };

export const desktopPlatform = {
  isAvailable: isDesktopRuntimeAvailable,
  getSurfaceMode,
  showFloatingWindow,
  showFloatingWindowCommand,
  hideFloatingWindow,
  hideFloatingWindowCommand,
  showStatusPanelWindow,
  hideStatusPanelWindow,
  showDashboardWindow,
  notifyFloatingWindowHidden,
  onFloatingWindowHidden,
  publishAppSettings,
  onAppSettingsChanged,
  publishFloatingSettings,
  onFloatingSettingsChanged,
  publishDisplaySurfaces,
  onDisplaySurfacesChanged,
  resizeFloatingWindow,
  startFloatingWindowDrag,
  setFloatingWindowPosition,
  onFloatingWindowMoved,
  setStatusTrayReadout,
  startLiveRateStream,
  startLiveRateStreamCommand,
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
