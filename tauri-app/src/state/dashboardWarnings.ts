import type { CommandFailureDiagnostic } from "../api/client";
import type { LocalDataWarning, QuotaDiagnostic } from "../types/dashboard";

const QUOTA_WARNING_SOURCES = new Set(["account_quota", "reset_credit", "quota_history"]);
const ACCOUNT_QUOTA_WARNING_SOURCES = new Set(["account_quota", "quota_history"]);
const RESET_CREDIT_WARNING_SOURCES = new Set(["reset_credit"]);
const QUOTA_DIAGNOSTIC_SOURCES = new Set([
  "account_quota",
  "reset_credit",
  "source_integrity",
  "frontend_command",
]);
const ACCOUNT_QUOTA_DIAGNOSTIC_SOURCES = new Set([
  "account_quota",
  "source_integrity",
]);
const RESET_CREDIT_DIAGNOSTIC_SOURCES = new Set(["reset_credit"]);
export const USAGE_PRECISION_WARNING_SOURCE = "usage_precision";

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

export function replaceAccountQuotaWarnings(
  previous: LocalDataWarning[],
  latest: LocalDataWarning[],
): LocalDataWarning[] {
  return replaceWarningsBySource(previous, latest, ACCOUNT_QUOTA_WARNING_SOURCES);
}

export function replaceResetCreditWarnings(
  previous: LocalDataWarning[],
  latest: LocalDataWarning[],
): LocalDataWarning[] {
  return replaceWarningsBySource(previous, latest, RESET_CREDIT_WARNING_SOURCES);
}

export function removeUsagePrecisionWarnings(warnings: LocalDataWarning[]): LocalDataWarning[] {
  return warnings.filter((warning) => !isUsagePrecisionWarning(warning));
}

export function usagePrecisionWarnings(warnings: LocalDataWarning[]): LocalDataWarning[] {
  return warnings.filter(isUsagePrecisionWarning);
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

export function replaceAccountQuotaDiagnostics(
  previous: QuotaDiagnostic[],
  latest: QuotaDiagnostic[],
): QuotaDiagnostic[] {
  return replaceDiagnosticsBySource(previous, latest, ACCOUNT_QUOTA_DIAGNOSTIC_SOURCES);
}

export function replaceResetCreditDiagnostics(
  previous: QuotaDiagnostic[],
  latest: QuotaDiagnostic[],
): QuotaDiagnostic[] {
  return replaceDiagnosticsBySource(previous, latest, RESET_CREDIT_DIAGNOSTIC_SOURCES);
}

export function hasStaleAccountQuotaData(diagnostics: readonly QuotaDiagnostic[]): boolean {
  return diagnostics.some((diagnostic) => (
    ACCOUNT_QUOTA_DIAGNOSTIC_SOURCES.has(diagnostic.source)
    && (diagnostic.staleDataDisplayed || diagnostic.category === "stale_cached_data")
  ));
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

function isUsagePrecisionWarning(warning: LocalDataWarning): boolean {
  return warning.source === USAGE_PRECISION_WARNING_SOURCE;
}

function isQuotaDiagnostic(diagnostic: QuotaDiagnostic): boolean {
  return QUOTA_DIAGNOSTIC_SOURCES.has(diagnostic.source);
}

function replaceWarningsBySource(
  previous: LocalDataWarning[],
  latest: LocalDataWarning[],
  sources: ReadonlySet<string>,
): LocalDataWarning[] {
  return mergeWarnings(
    previous.filter((warning) => !sources.has(warning.source)),
    latest.filter((warning) => sources.has(warning.source)),
  );
}

function replaceDiagnosticsBySource(
  previous: QuotaDiagnostic[],
  latest: QuotaDiagnostic[],
  sources: ReadonlySet<string>,
): QuotaDiagnostic[] {
  return mergeQuotaDiagnostics(
    previous.filter((diagnostic) => !sources.has(diagnostic.source)),
    latest.filter((diagnostic) => sources.has(diagnostic.source)),
  );
}
