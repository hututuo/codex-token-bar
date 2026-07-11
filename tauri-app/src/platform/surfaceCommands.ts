import {
  invokePlatformCommand,
  invokePlatformCommandResult,
  type PlatformCommandResult,
} from "./desktopBridge";
import type {
  CodexHomeSourceToken,
  LiveRateStreamLease,
} from "../types/dashboard";

export type SurfaceCommandResult = PlatformCommandResult<boolean>;
export type LiveRateStreamCommandResult = PlatformCommandResult<LiveRateStreamLease | null>;

export interface LiveRateStreamStartOptions {
  controlsSelectedThread: boolean;
  ownerGeneration: number;
  ownerSessionEpoch: number;
  selectedThreadId?: string | null;
  sourceToken?: CodexHomeSourceToken | null;
  subscriberOwnerToken: string;
}

export function claimLiveRateOwnerSession(
  subscriberOwnerToken: string,
  ownerSessionEpoch: number,
  sourceToken: CodexHomeSourceToken,
): Promise<boolean> {
  return invokePlatformCommand("claim_live_rate_owner_session", false, {
    subscriberOwnerToken,
    ownerSessionEpoch,
    sourceToken,
  });
}

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

export function dismissStatusPanelOnBlur(): Promise<boolean> {
  return invokePlatformCommand("dismiss_status_panel_on_blur", false);
}

export function showDashboardWindow(): Promise<boolean> {
  return invokePlatformCommand("show_dashboard_window", false);
}

export function setStatusTrayReadout(title: string, tooltip: string): Promise<boolean> {
  return invokePlatformCommand("set_status_tray_readout", false, { title, tooltip });
}

export function startLiveRateStream(
  options: LiveRateStreamStartOptions,
): Promise<LiveRateStreamLease | null> {
  return invokePlatformCommand("start_live_rate_stream", null, {
    ...options,
    selectedThreadId: options.selectedThreadId || null,
    sourceToken: options.sourceToken ?? null,
  });
}

export function startLiveRateStreamCommand(
  options: LiveRateStreamStartOptions,
): Promise<LiveRateStreamCommandResult> {
  return invokePlatformCommandResult("start_live_rate_stream", null, {
    ...options,
    selectedThreadId: options.selectedThreadId || null,
    sourceToken: options.sourceToken ?? null,
  }, null);
}

export function stopLiveRateStream(leaseId: string): Promise<boolean> {
  return invokePlatformCommand("stop_live_rate_stream", false, { leaseId });
}
