export interface LocalDataWarning {
  source: string;
  message: string;
}

export type QuotaDiagnosticCategory =
  | "auth_missing"
  | "app_server_unavailable"
  | "timeout"
  | "network_send_fetch"
  | "http_auth"
  | "http_rate_limited"
  | "http_server"
  | "http_other"
  | "parse_failure"
  | "empty_quota"
  | "reset_credit_failure"
  | "stale_cached_data"
  | "source_mismatch"
  | "unknown";

export type QuotaDiagnosticSeverity = "info" | "warning" | "error";

export interface QuotaDiagnostic {
  source: string;
  category: QuotaDiagnosticCategory | string;
  severity: QuotaDiagnosticSeverity | string;
  message: string;
  rawCause?: string | null;
  underlyingCategory?: QuotaDiagnosticCategory | string | null;
  attempts?: number | null;
  httpStatus?: number | null;
  retryable: boolean;
  occurredAt: string;
  staleDataDisplayed: boolean;
}
