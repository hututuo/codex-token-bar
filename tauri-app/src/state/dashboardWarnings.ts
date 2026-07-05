import type { CommandFailureDiagnostic } from "../api/client";
import type { LocalDataWarning, QuotaDiagnostic } from "../types/dashboard";

const QUOTA_WARNING_SOURCES = new Set(["account_quota", "reset_credit", "quota_history"]);
const QUOTA_DIAGNOSTIC_SOURCES = new Set([
  "account_quota",
  "reset_credit",
  "source_integrity",
  "frontend_command",
]);

export function mergeWarnings(left: LocalDataWarning[], right: LocalDataWarning[]): LocalDataWarning[] {
  const byKey = new Map<string, LocalDataWarning>();
  [...left, ...right].forEach((warning) => {
    const key = `${warning.source}:${warning.message}`;
    byKey.set(key, warning);
  });
  return Array.from(byKey.values());
}

export function replaceQuotaWarnings(
  previous: LocalDataWarning[],
  latest: LocalDataWarning[],
): LocalDataWarning[] {
  return mergeWarnings(previous.filter((warning) => !isQuotaWarning(warning)), latest);
}

export function mergeQuotaDiagnostics(
  left: QuotaDiagnostic[],
  right: QuotaDiagnostic[],
): QuotaDiagnostic[] {
  const byKey = new Map<string, QuotaDiagnostic>();
  [...left, ...right].forEach((diagnostic) => {
    const key = [
      diagnostic.source,
      diagnostic.category,
      diagnostic.message,
      diagnostic.rawCause ?? "",
      diagnostic.underlyingCategory ?? "",
    ].join(":");
    byKey.set(key, diagnostic);
  });
  return Array.from(byKey.values());
}

export function replaceQuotaDiagnostics(
  previous: QuotaDiagnostic[],
  latest: QuotaDiagnostic[],
): QuotaDiagnostic[] {
  return mergeQuotaDiagnostics(previous.filter((diagnostic) => !isQuotaDiagnostic(diagnostic)), latest);
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

function isQuotaWarning(warning: LocalDataWarning): boolean {
  return QUOTA_WARNING_SOURCES.has(warning.source);
}

function isQuotaDiagnostic(diagnostic: QuotaDiagnostic): boolean {
  return QUOTA_DIAGNOSTIC_SOURCES.has(diagnostic.source);
}
