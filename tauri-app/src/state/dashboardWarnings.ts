import type { CommandFailureDiagnostic } from "../api/client";
import type { LocalDataWarning } from "../types/dashboard";

export function mergeWarnings(left: LocalDataWarning[], right: LocalDataWarning[]): LocalDataWarning[] {
  const byKey = new Map<string, LocalDataWarning>();
  [...left, ...right].forEach((warning) => {
    const key = `${warning.source}:${warning.message}`;
    byKey.set(key, warning);
  });
  return Array.from(byKey.values());
}

export function mergeWarningDiagnostics(
  diagnostics: CommandFailureDiagnostic[],
  warnings: LocalDataWarning[],
  generatedAt: string,
): CommandFailureDiagnostic[] {
  if (warnings.length === 0) {
    return diagnostics;
  }
  const warningDiagnostics = warnings.map((warning) => ({
    command: `local:${warning.source}`,
    message: warning.message,
    occurredAt: generatedAt,
    count: 1,
  }));
  return [...warningDiagnostics, ...diagnostics];
}
