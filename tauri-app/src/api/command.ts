import { invoke } from "@tauri-apps/api/core";
import {
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

export async function callCommand<T>(
  command: string,
  fallback: T,
  args?: Record<string, unknown>,
  timeoutMs = DEFAULT_COMMAND_TIMEOUT_MS,
): Promise<T> {
  if (!isTauriRuntimeAvailable()) {
    recordCommandFailure(command, new Error("当前不是 Tauri 桌面运行环境。"));
    return fallback;
  }

  try {
    const result = await withTimeout(invoke<T>(command, args), timeoutMs);
    clearCommandFailure(command);
    return result;
  } catch (error) {
    recordCommandFailure(command, error);
    return fallback;
  }
}

export async function callCommandOptional<T>(
  command: string,
  args?: Record<string, unknown>,
  timeoutMs = DEFAULT_COMMAND_TIMEOUT_MS,
): Promise<T | null> {
  if (!isTauriRuntimeAvailable()) {
    recordCommandFailure(command, new Error("当前不是 Tauri 桌面运行环境。"));
    return null;
  }

  try {
    const result = await withTimeout(invoke<T>(command, args), timeoutMs);
    clearCommandFailure(command);
    return result;
  } catch (error) {
    recordCommandFailure(command, error);
    return null;
  }
}

export async function callCommandStrict<T>(
  command: string,
  args?: Record<string, unknown>,
  timeoutMs = DEFAULT_COMMAND_TIMEOUT_MS,
): Promise<T> {
  if (!isTauriRuntimeAvailable()) {
    const error = new Error("当前不是 Tauri 桌面运行环境。");
    recordCommandFailure(command, error);
    throw error;
  }

  try {
    const result = await withTimeout(invoke<T>(command, args), timeoutMs);
    clearCommandFailure(command);
    return result;
  } catch (error) {
    const normalized = normalizeCommandError(error);
    recordCommandFailure(command, normalized);
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
    return new Error(JSON.stringify(error));
  } catch {
    return new Error(String(error));
  }
}
