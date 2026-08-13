import {
  notifyFloatingWindowHidden,
  onFloatingWindowVisibilityChanged,
  onAppSettingsChanged,
  onCodexHomeSourceChanged,
  onFloatingSettingsChanged,
  onFloatingPagingGuideCompleted,
  onFloatingWindowHidden,
  onDisplaySurfacesChanged,
  onLiveRateSnapshot,
  onOpenAppSettings,
  onUnreadSummaryChanged,
  onAccountQuotaChanged,
  onAccountResetCreditsChanged,
  publishAppSettings,
  publishDisplaySurfaces,
  publishFloatingSettings,
  publishFloatingPagingGuideCompleted,
  publishOpenAppSettings,
  publishUnreadSummaryChanged,
  publishAccountQuotaChanged,
  publishAccountResetCreditsChanged,
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
  dismissStatusPanelOnBlur,
  claimLiveRateOwnerSession,
  publishStatusIndicatorReadout,
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
  dismissStatusPanelOnBlur,
  publishStatusIndicatorReadout,
  showDashboardWindow,
  notifyFloatingWindowHidden,
  onFloatingWindowHidden,
  onFloatingWindowVisibilityChanged,
  publishAppSettings,
  onAppSettingsChanged,
  onCodexHomeSourceChanged,
  publishFloatingSettings,
  onFloatingSettingsChanged,
  publishFloatingPagingGuideCompleted,
  onFloatingPagingGuideCompleted,
  publishDisplaySurfaces,
  onDisplaySurfacesChanged,
  resizeFloatingWindow,
  startFloatingWindowDrag,
  setFloatingWindowPosition,
  onFloatingWindowMoved,
  claimLiveRateOwnerSession,
  startLiveRateStream,
  startLiveRateStreamCommand,
  stopLiveRateStream,
  onLiveRateSnapshot,
  publishOpenAppSettings,
  onOpenAppSettings,
  publishUnreadSummaryChanged,
  onUnreadSummaryChanged,
  publishAccountQuotaChanged,
  onAccountQuotaChanged,
  publishAccountResetCreditsChanged,
  onAccountResetCreditsChanged,
};

function getSurfaceMode(): SurfaceMode {
  const surface = new URLSearchParams(window.location.search).get("surface");
  if (surface === "floating" || surface === "status") {
    return surface;
  }
  return "dashboard";
}
