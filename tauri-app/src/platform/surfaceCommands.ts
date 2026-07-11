import {
  invokePlatformCommand,
  invokePlatformCommandResult,
  type PlatformCommandResult,
} from "./desktopBridge";
import type {
  CodexHomeSourceToken,
  LiveRateStreamLease,
} from "../types/dashboard";
import { publishFloatingWindowVisibility } from "./desktopEvents";

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
): Promise<boolean> {
  return invokePlatformCommand("claim_live_rate_owner_session", false, {
    subscriberOwnerToken,
    ownerSessionEpoch,
  });
}

export async function showFloatingWindow(): Promise<boolean> {
  const visible = await invokePlatformCommand("show_floating_window", false);
  await publishFloatingWindowVisibility(visible);
  return visible;
}

export async function showFloatingWindowCommand(): Promise<SurfaceCommandResult> {
  const result = await invokePlatformCommandResult("show_floating_window", false);
  if (result.ok) {
    await publishFloatingWindowVisibility(result.value);
  }
  return result;
}

export async function hideFloatingWindow(): Promise<boolean> {
  const visible = await invokePlatformCommand("hide_floating_window", true);
  await publishFloatingWindowVisibility(visible);
  return visible;
}

export async function hideFloatingWindowCommand(): Promise<SurfaceCommandResult> {
  const result = await invokePlatformCommandResult("hide_floating_window", true);
  if (result.ok) {
    await publishFloatingWindowVisibility(result.value);
  }
  return result;
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
