import {
  invokePlatformCommand,
  invokePlatformCommandResult,
  type PlatformCommandResult,
} from "./desktopBridge";

export type SurfaceCommandResult = PlatformCommandResult<boolean>;

export function showFloatingWindow(): Promise<boolean> {
  return invokePlatformCommand("show_floating_window", false);
}

export function showFloatingWindowCommand(): Promise<SurfaceCommandResult> {
  return invokePlatformCommandResult("show_floating_window", false);
}

export function hideFloatingWindow(): Promise<boolean> {
  return invokePlatformCommand("hide_floating_window", true);
}

export function hideFloatingWindowCommand(): Promise<SurfaceCommandResult> {
  return invokePlatformCommandResult("hide_floating_window", true);
}

export function showStatusPanelWindow(): Promise<boolean> {
  return invokePlatformCommand("show_status_panel_window", false);
}

export function hideStatusPanelWindow(): Promise<boolean> {
  return invokePlatformCommand("hide_status_panel_window", true);
}

export function showDashboardWindow(): Promise<boolean> {
  return invokePlatformCommand("show_dashboard_window", false);
}

export function setStatusTrayReadout(title: string, tooltip: string): Promise<boolean> {
  return invokePlatformCommand("set_status_tray_readout", false, { title, tooltip });
}

export function startLiveRateStream(
  selectedThreadId?: string | null,
  controlsSelectedThread = false,
): Promise<boolean> {
  return invokePlatformCommand("start_live_rate_stream", false, {
    selectedThreadId: selectedThreadId || null,
    controlsSelectedThread,
  });
}

export function startLiveRateStreamCommand(
  selectedThreadId?: string | null,
  controlsSelectedThread = false,
): Promise<SurfaceCommandResult> {
  return invokePlatformCommandResult("start_live_rate_stream", false, {
    selectedThreadId: selectedThreadId || null,
    controlsSelectedThread,
  });
}

export function stopLiveRateStream(): Promise<boolean> {
  return invokePlatformCommand("stop_live_rate_stream", false);
}
