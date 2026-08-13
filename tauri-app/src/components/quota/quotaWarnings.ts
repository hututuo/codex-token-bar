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

export function quotaRefreshAttemptStatus(
  lastSuccessfulAt: string | null | undefined,
  diagnostics: QuotaDiagnostic[],
): string | null {
  const lastAttemptAt = diagnostics
    .filter((diagnostic) => (
      diagnostic.source === "account_quota" || diagnostic.source === "frontend_command"
    ))
    .filter((diagnostic) => diagnostic.category !== "stale_cached_data")
    .map((diagnostic) => parsedTimestamp(diagnostic.occurredAt))
    .filter((timestamp): timestamp is number => timestamp !== null)
    .reduce<number | null>((latest, timestamp) => (
      latest === null || timestamp > latest ? timestamp : latest
    ), null);
  if (lastAttemptAt === null) {
    return null;
  }

  const successfulAt = parsedTimestamp(lastSuccessfulAt);
  const successStatus = successfulAt === null
    ? "尚无成功额度"
    : `上次成功 ${formatTimestamp(successfulAt)}`;
  return `自动重试中（最长 1 分钟） · 上次尝试 ${formatTimestamp(lastAttemptAt)} · ${successStatus}`;
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
    return "额度和重置卡刷新失败，自动重试中（最长 1 分钟）；当前显示上次成功结果。";
  }
  if (quotaStale) {
    return "额度刷新失败，自动重试中（最长 1 分钟）；当前显示上次成功额度。";
  }
  if (resetStale) {
    return "重置卡刷新失败，自动重试中（最长 1 分钟）；当前显示上次成功结果。";
  }
  return null;
}

function diagnosticPriority(diagnostic: QuotaDiagnostic): number {
  return CATEGORY_PRIORITY.get(diagnostic.category) ?? CATEGORY_PRIORITY.get("unknown") ?? 200;
}

function dedupeMessages(messages: string[]): string[] {
  return messages.filter((message, index) => messages.indexOf(message) === index);
}

function parsedTimestamp(value: string | null | undefined): number | null {
  if (typeof value !== "string" || value.trim().length === 0) {
    return null;
  }
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? timestamp : null;
}

function formatTimestamp(timestamp: number): string {
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).format(new Date(timestamp));
}
