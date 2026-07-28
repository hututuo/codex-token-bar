const WARNING_THROTTLE_MS = 5_000;
const MAX_LOCAL_DIAGNOSTICS = 50;
const SILENT_FAILURE_COMMANDS = new Set([
  "record_startup_event",
  "platform:command:show_floating_window",
  "platform:command:hide_floating_window",
  "platform:command:show_status_panel_window",
  "platform:command:hide_status_panel_window",
]);

const lastWarningAtByKey = new Map<string, number>();
const diagnosticsByKey = new Map<string, CommandFailureDiagnostic>();
const diagnosticsListeners = new Set<(diagnostics: CommandFailureDiagnostic[]) => void>();
const latestAttemptByCommand = new Map<string, number>();
let commandAttemptSequence = 0;

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

export function beginCommandAttempt(command: string): number {
  commandAttemptSequence += 1;
  latestAttemptByCommand.set(command, commandAttemptSequence);
  return commandAttemptSequence;
}

export function recordCommandFailure(command: string, error: unknown, attempt?: number) {
  if (!isCurrentCommandAttempt(command, attempt)) {
    return;
  }
  if (SILENT_FAILURE_COMMANDS.has(command)) {
    return;
  }

  const now = Date.now();
  const lastWarningAt = lastWarningAtByKey.get(command) ?? 0;
  const throttled = now - lastWarningAt < WARNING_THROTTLE_MS;
  if (throttled && attempt === undefined) {
    return;
  }

  const previous = diagnosticsByKey.get(command);
  if (!throttled) {
    lastWarningAtByKey.set(command, now);
  }
  if (previous) {
    diagnosticsByKey.delete(command);
  }
  diagnosticsByKey.set(command, {
    command,
    message: commandFailureMessage(error),
    occurredAt: new Date(now).toISOString(),
    count: previous === undefined
      ? 1
      : previous.count + (throttled ? 0 : 1),
  });
  trimCommandDiagnostics();
  emitCommandDiagnostics();
  if (!throttled) {
    console.warn(`Local operation failed: ${command}`, error);
  }
}

export function clearCommandFailure(command: string, attempt?: number) {
  if (!isCurrentCommandAttempt(command, attempt)) {
    return;
  }
  if (attempt === undefined) {
    latestAttemptByCommand.delete(command);
  }
  if (diagnosticsByKey.delete(command)) {
    lastWarningAtByKey.delete(command);
    emitCommandDiagnostics();
  }
}

function isCurrentCommandAttempt(command: string, attempt?: number): boolean {
  return attempt === undefined || latestAttemptByCommand.get(command) === attempt;
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
