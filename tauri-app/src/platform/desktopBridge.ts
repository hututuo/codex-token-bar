import { invoke } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";
import { clearCommandFailure, recordCommandFailure } from "../diagnostics/localDiagnostics";
import { isTauriRuntimeAvailable, withTimeout } from "./runtime";

export type Unlisten = () => void;

export type EventSubscriptionResult =
  | { ok: true; unlisten: Unlisten }
  | { ok: false; error: string };

const PLATFORM_COMMAND_TIMEOUT_MS = 2_000;

export type PlatformCommandResult<T> =
  | { ok: true; value: T }
  | { ok: false; fallback: T; error: string };

export function isDesktopRuntimeAvailable(): boolean {
  return isTauriRuntimeAvailable();
}

export async function invokePlatformCommand<T>(
  command: string,
  fallback: T,
  args?: Record<string, unknown>,
): Promise<T> {
  const result = await invokePlatformCommandResult(command, fallback, args);
  return result.ok ? result.value : result.fallback;
}

export async function invokePlatformCommandResult<T>(
  command: string,
  fallback: T,
  args?: Record<string, unknown>,
  timeoutMs: number | null = PLATFORM_COMMAND_TIMEOUT_MS,
): Promise<PlatformCommandResult<T>> {
  if (!isTauriRuntimeAvailable()) {
    return {
      ok: false,
      fallback,
      error: "Tauri runtime is not available",
    };
  }

  try {
    const invocation = invoke<T>(command, args);
    const result = timeoutMs === null
      ? await invocation
      : await withTimeout(invocation, timeoutMs);
    clearPlatformFailure(`command:${command}`);
    return { ok: true, value: result };
  } catch (error) {
    warnPlatformFailure(`command:${command}`, error);
    return {
      ok: false,
      fallback,
      error: platformErrorMessage(error),
    };
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
  const result = await listenToEventResult(eventName, handler);
  return result.ok ? result.unlisten : () => {};
}

export async function listenToEventResult<T = void>(
  eventName: string,
  handler: (payload: T) => void,
): Promise<EventSubscriptionResult> {
  if (!isTauriRuntimeAvailable()) {
    return { ok: false, error: "Tauri runtime is not available" };
  }

  try {
    const unlisten = await listen<T>(eventName, ({ payload }) => handler(payload));
    clearPlatformFailure(`listen:${eventName}`);
    return { ok: true, unlisten };
  } catch (error) {
    warnPlatformFailure(`listen:${eventName}`, error);
    return { ok: false, error: platformErrorMessage(error) };
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

function platformErrorMessage(error: unknown): string {
  if (error instanceof Error && error.message.trim()) {
    return error.message;
  }
  if (typeof error === "string" && error.trim()) {
    return error;
  }
  return "Unknown platform command failure";
}
