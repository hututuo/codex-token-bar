const WARNING_THROTTLE_MS = 5_000;
const SILENT_FAILURE_COMMANDS = new Set(["record_startup_event"]);

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

  lastWarningAtByKey.set(command, now);
  const previous = diagnosticsByKey.get(command);
  diagnosticsByKey.set(command, {
    command,
    message: commandFailureMessage(error),
    occurredAt: new Date(now).toISOString(),
    count: (previous?.count ?? 0) + 1,
  });
  emitCommandDiagnostics();
  console.warn(`Local operation failed: ${command}`, error);
}

export function clearCommandFailure(command: string) {
  if (diagnosticsByKey.delete(command)) {
    emitCommandDiagnostics();
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
