const WARNING_THROTTLE_MS = 5_000;
const MAX_LOCAL_DIAGNOSTICS = 50;
const SILENT_FAILURE_COMMANDS = new Set([
  "record_startup_event",
  "platform:command:show_floating_window",
  "platform:command:hide_floating_window",
  "platform:command:show_status_panel_window",
  "platform:command:hide_status_panel_window",
  "platform:command:set_status_tray_readout",
]);

const lastWarningAtByKey = new Map<string, number>();
const diagnosticsByKey = new Map<string, CommandFailureDiagnostic>();
const diagnosticsListeners = new Set<(diagnostics: CommandFailureDiagnostic[]) => void>();

export interface CommandFailureDiagnostic {
  command: string;
  message: string;
  occurredAt: string;
  count: number;
}

export function getCommandDiagnosticsSnapshot(): CommandFailureDiagnostic[] {
  return Array.from(diagnosticsByKey.values()).sort((left, right) =>
    right.occurredAt.localeCompare(left.occurredAt),
  );
}

export function subscribeCommandDiagnostics(
  listener: (diagnostics: CommandFailureDiagnostic[]) => void,
): () => void {
  diagnosticsListeners.add(listener);
  listener(getCommandDiagnosticsSnapshot());
  return () => {
    diagnosticsListeners.delete(listener);
  };
}

export function recordCommandFailure(command: string, error: unknown) {
  if (SILENT_FAILURE_COMMANDS.has(command)) {
    return;
  }

  const now = Date.now();
  const lastWarningAt = lastWarningAtByKey.get(command) ?? 0;
  if (now - lastWarningAt < WARNING_THROTTLE_MS) {
    return;
  }

  const previous = diagnosticsByKey.get(command);
  lastWarningAtByKey.set(command, now);
  if (previous) {
    diagnosticsByKey.delete(command);
  }
  diagnosticsByKey.set(command, {
    command,
    message: commandFailureMessage(error),
    occurredAt: new Date(now).toISOString(),
    count: (previous?.count ?? 0) + 1,
  });
  trimCommandDiagnostics();
  emitCommandDiagnostics();
  console.warn(`Local operation failed: ${command}`, error);
}

export function clearCommandFailure(command: string) {
  if (diagnosticsByKey.delete(command)) {
    lastWarningAtByKey.delete(command);
    emitCommandDiagnostics();
  }
}

function trimCommandDiagnostics() {
  while (diagnosticsByKey.size > MAX_LOCAL_DIAGNOSTICS) {
    const oldestCommand = diagnosticsByKey.keys().next().value;
    if (!oldestCommand) {
      return;
    }
    diagnosticsByKey.delete(oldestCommand);
    lastWarningAtByKey.delete(oldestCommand);
  }
}

function emitCommandDiagnostics() {
  const snapshot = getCommandDiagnosticsSnapshot();
  diagnosticsListeners.forEach((listener) => listener(snapshot));
}

function commandFailureMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  if (typeof error === "string") {
    return error;
  }
  try {
    return JSON.stringify(error);
  } catch {
    return String(error);
  }
}
