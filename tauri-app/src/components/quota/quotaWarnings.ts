import type { LocalDataWarning, QuotaDiagnostic } from "../../types/dashboard";

const QUOTA_WARNING_SOURCES = new Set(["account_quota", "reset_credit"]);
const QUOTA_DIAGNOSTIC_SOURCES = new Set([
  "account_quota",
  "reset_credit",
  "source_integrity",
  "frontend_command",
]);

const CATEGORY_PRIORITY = new Map<string, number>([
  ["auth_missing", 10],
  ["http_auth", 20],
  ["app_server_unavailable", 30],
  ["source_mismatch", 40],
  ["stale_cached_data", 50],
  ["timeout", 60],
  ["network_send_fetch", 70],
  ["http_rate_limited", 80],
  ["http_server", 90],
  ["http_other", 100],
  ["parse_failure", 110],
  ["empty_quota", 120],
  ["reset_credit_failure", 130],
  ["unknown", 200],
]);

export function quotaReadWarnings(
  warnings: LocalDataWarning[],
  diagnostics: QuotaDiagnostic[] = [],
): string[] {
  const diagnosticMessages = diagnostics
    .filter((diagnostic) => QUOTA_DIAGNOSTIC_SOURCES.has(diagnostic.source))
    .filter((diagnostic) => diagnostic.message.trim().length > 0)
    .sort((left, right) => diagnosticPriority(left) - diagnosticPriority(right))
    .map((diagnostic) => diagnostic.message);

  if (diagnosticMessages.length > 0) {
    return summarizedDiagnosticMessages(diagnostics);
  }

  return warnings
    .filter((warning) => QUOTA_WARNING_SOURCES.has(warning.source))
    .map((warning) => warning.message)
    .filter((message) => message.length > 0)
    .filter((message, index, messages) => messages.indexOf(message) === index)
    .slice(0, 2);
}

function summarizedDiagnosticMessages(diagnostics: QuotaDiagnostic[]): string[] {
  const relevant = diagnostics
    .filter((diagnostic) => QUOTA_DIAGNOSTIC_SOURCES.has(diagnostic.source))
    .filter((diagnostic) => diagnostic.message.trim().length > 0);
  const staleSources = new Set(relevant
    .filter((diagnostic) => (
      diagnostic.staleDataDisplayed === true || diagnostic.category === "stale_cached_data"
    ))
    .map((diagnostic) => diagnostic.source));
  const causes = relevant
    .filter((diagnostic) => (
      diagnostic.staleDataDisplayed !== true && diagnostic.category !== "stale_cached_data"
    ))
    .sort((left, right) => rootCausePriority(left) - rootCausePriority(right));
  const primaryCause = causes[0]?.message;
  const staleMessage = combinedStaleMessage(staleSources);
  return dedupeMessages([primaryCause, staleMessage].filter((message): message is string => Boolean(message)));
}

function rootCausePriority(diagnostic: QuotaDiagnostic): number {
  const category = diagnostic.underlyingCategory ?? diagnostic.category;
  if (category === "network_send_fetch") return 25;
  return CATEGORY_PRIORITY.get(category) ?? CATEGORY_PRIORITY.get("unknown") ?? 200;
}

function combinedStaleMessage(sources: ReadonlySet<string>): string | null {
  const quotaStale = sources.has("account_quota") || sources.has("frontend_command");
  const resetStale = sources.has("reset_credit");
  if (quotaStale && resetStale) {
    return "额度和重置卡刷新失败，暂时显示上次成功结果。";
  }
  if (quotaStale) {
    return "额度刷新失败，暂时显示上次成功额度。";
  }
  if (resetStale) {
    return "重置卡刷新失败，暂时显示上次成功结果。";
  }
  return null;
}

function diagnosticPriority(diagnostic: QuotaDiagnostic): number {
  return CATEGORY_PRIORITY.get(diagnostic.category) ?? CATEGORY_PRIORITY.get("unknown") ?? 200;
}

function dedupeMessages(messages: string[]): string[] {
  return messages.filter((message, index) => messages.indexOf(message) === index);
}
