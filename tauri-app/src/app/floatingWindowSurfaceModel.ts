import type { SurfaceCommandResult } from "../platform/surfaceCommands";

export function floatingCommandVisibleState(
  result: SurfaceCommandResult,
  currentVisible: boolean,
): boolean {
  return result.ok ? result.value : currentVisible;
}

export function floatingCommandPreferenceConfirmation(
  result: SurfaceCommandResult,
): boolean | null {
  return result.ok ? result.value : null;
}

export function shouldConfirmFloatingHiddenEvent(
  settingsReady: boolean,
  enabledPreference: boolean,
): boolean {
  return settingsReady && enabledPreference;
}
