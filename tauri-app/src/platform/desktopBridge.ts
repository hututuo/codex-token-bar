import { invoke } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";
import { clearCommandFailure, recordCommandFailure } from "../diagnostics/localDiagnostics";
import { isTauriRuntimeAvailable, withTimeout } from "./runtime";

export type Unlisten = () => void;

const PLATFORM_COMMAND_TIMEOUT_MS = 2_000;

export function isDesktopRuntimeAvailable(): boolean {
  return isTauriRuntimeAvailable();
}

export async function invokePlatformCommand<T>(
  command: string,
  fallback: T,
  args?: Record<string, unknown>,
): Promise<T> {
  if (!isTauriRuntimeAvailable()) {
    return fallback;
  }

  try {
    const result = await withTimeout(invoke<T>(command, args), PLATFORM_COMMAND_TIMEOUT_MS);
    clearPlatformFailure(`command:${command}`);
    return result;
  } catch (error) {
    warnPlatformFailure(`command:${command}`, error);
    return fallback;
  }
}

export async function emitPlatformEvent<T>(
  eventName: string,
  diagnosticKey: string,
  payload?: T,
): Promise<boolean> {
  if (!isTauriRuntimeAvailable()) {
    return false;
  }

  try {
    await emit(eventName, payload);
    clearPlatformFailure(diagnosticKey);
    return true;
  } catch (error) {
    warnPlatformFailure(diagnosticKey, error);
    return false;
  }
}

export async function listenToEvent<T = void>(
  eventName: string,
  handler: (payload: T) => void,
): Promise<Unlisten> {
  if (!isTauriRuntimeAvailable()) {
    return () => {};
  }

  try {
    const unlisten = await listen<T>(eventName, ({ payload }) => handler(payload));
    clearPlatformFailure(`listen:${eventName}`);
    return unlisten;
  } catch (error) {
    warnPlatformFailure(`listen:${eventName}`, error);
    return () => {};
  }
}

export function warnPlatformFailure(key: string, error: unknown) {
  recordCommandFailure(platformDiagnosticKey(key), error);
}

export function clearPlatformFailure(key: string) {
  clearCommandFailure(platformDiagnosticKey(key));
}

function platformDiagnosticKey(key: string) {
  return `platform:${key}`;
}
