import { invoke } from "@tauri-apps/api/core";
import {
  beginCommandAttempt,
  clearCommandFailure,
  getCommandDiagnosticsSnapshot,
  recordCommandFailure,
  subscribeCommandDiagnostics,
  type CommandFailureDiagnostic,
} from "../diagnostics/localDiagnostics";
import { isTauriRuntimeAvailable, withTimeout } from "../platform/runtime";

const DEFAULT_COMMAND_TIMEOUT_MS = 4_000;

export {
  getCommandDiagnosticsSnapshot,
  subscribeCommandDiagnostics,
  type CommandFailureDiagnostic,
};

export function clearCommandDiagnostic(command: string) {
  clearCommandFailure(command);
}

export async function callCommand<T>(
  command: string,
  fallback: T,
  args?: Record<string, unknown>,
  timeoutMs: number | null = DEFAULT_COMMAND_TIMEOUT_MS,
): Promise<T> {
  if (!isTauriRuntimeAvailable()) {
    recordCommandFailure(command, new Error("当前不是 Tauri 桌面运行环境。"));
    return fallback;
  }

  const attempt = beginCommandAttempt(command);
  const invocation = invoke<T>(command, args);
  void invocation.then(
    () => clearCommandFailure(command, attempt),
    (error) => recordCommandFailure(command, error, attempt),
  );
  try {
    const result = await (timeoutMs === null
      ? invocation
      : withTimeout(invocation, timeoutMs));
    clearCommandFailure(command, attempt);
    return result;
  } catch (error) {
    recordCommandFailure(command, error, attempt);
    return fallback;
  }
}

export async function callCommandOptional<T>(
  command: string,
  args?: Record<string, unknown>,
  timeoutMs: number | null = DEFAULT_COMMAND_TIMEOUT_MS,
): Promise<T | null> {
  if (!isTauriRuntimeAvailable()) {
    recordCommandFailure(command, new Error("当前不是 Tauri 桌面运行环境。"));
    return null;
  }

  const attempt = beginCommandAttempt(command);
  const invocation = invoke<T>(command, args);
  void invocation.then(
    () => clearCommandFailure(command, attempt),
    (error) => recordCommandFailure(command, error, attempt),
  );
  try {
    const result = await (timeoutMs === null
      ? invocation
      : withTimeout(invocation, timeoutMs));
    clearCommandFailure(command, attempt);
    return result;
  } catch (error) {
    recordCommandFailure(command, error, attempt);
    return null;
  }
}

export async function callCommandStrict<T>(
  command: string,
  args?: Record<string, unknown>,
  timeoutMs: number | null = DEFAULT_COMMAND_TIMEOUT_MS,
): Promise<T> {
  if (!isTauriRuntimeAvailable()) {
    const error = new Error("当前不是 Tauri 桌面运行环境。");
    recordCommandFailure(command, error);
    throw error;
  }

  const attempt = beginCommandAttempt(command);
  const invocation = invoke<T>(command, args);
  void invocation.then(
    () => clearCommandFailure(command, attempt),
    (error) => recordCommandFailure(command, normalizeCommandError(error), attempt),
  );
  try {
    const result = await (timeoutMs === null
      ? invocation
      : withTimeout(invocation, timeoutMs));
    clearCommandFailure(command, attempt);
    return result;
  } catch (error) {
    const normalized = normalizeCommandError(error);
    recordCommandFailure(command, normalized, attempt);
    throw normalized;
  }
}

export function normalizeCommandError(error: unknown): Error {
  if (error instanceof Error) {
    return error;
  }
  if (typeof error === "string") {
    return new Error(error);
  }
  try {
    const normalized = new Error(JSON.stringify(error));
    Object.defineProperty(normalized, "commandPayload", {
      configurable: false,
      enumerable: false,
      value: error,
      writable: false,
    });
    return normalized;
  } catch {
    return new Error(String(error));
  }
}

export function commandErrorPayload(error: unknown): unknown {
  if (typeof error !== "object" || error === null) return null;
  return (error as { commandPayload?: unknown }).commandPayload ?? null;
}
