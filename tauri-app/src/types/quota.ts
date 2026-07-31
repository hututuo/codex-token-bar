import type { LocalDataWarning, QuotaDiagnostic } from "./diagnostics";

export interface AccountInfo {
  displayName: string;
  planLabel: string;
}

export interface QuotaAttributionIdentity {
  /** Opaque native hash; never contains the raw account or limit identifier. */
  scopeKey: string;
  plan: string;
  limit: string;
}

export interface QuotaLimit {
  label: string;
  availability: "measured" | "unavailable" | "absent";
  remainingPercent: number | null;
  usedPercent: number | null;
  resetsAt: string;
  resetsAtUnix?: number | null;
}

export interface QuotaHistoryPoint {
  label: string;
  startUnix: number;
  fiveHourRemainingPercent: number | null;
  sevenDayRemainingPercent: number | null;
}

export interface QuotaHistoryDailyPoint {
  date: string;
  fiveHourRemainingPercent: number | null;
  sevenDayRemainingPercent: number | null;
}

export interface ResetCreditSummary {
  availableCount: number;
  status: string;
  credits: ResetCreditDetail[];
}

export interface ResetCreditDetail {
  cardId: string;
  title: string;
  status: string;
  summary: string;
  resetType: string;
  issuedAt: string;
  grantedAtUnix?: number | null;
  expiresAt: string;
  expiresAtUnix?: number | null;
  redeemStartedAt: string;
  redeemedAt: string;
  source: string;
  detailNote: string;
  associatedUser: string;
  profileImageUrl: string;
  shortId: string;
}

export interface QuotaSnapshot {
  fiveHour: QuotaLimit;
  sevenDay: QuotaLimit;
  resetCredit: ResetCreditSummary;
  paceLabel: string;
}

export interface AccountQuotaBundle {
  updatedAt: string;
  attributionIdentity?: QuotaAttributionIdentity | null;
  account: AccountInfo;
  quota: QuotaSnapshot;
  quotaHistoryDaily: QuotaHistoryDailyPoint[];
  /** Compatibility name: this is the 30-day, five-minute long recent canvas. */
  quotaHistory24h: QuotaHistoryPoint[];
  quotaHistory7d: QuotaHistoryPoint[];
  quotaHistory30d: QuotaHistoryPoint[];
  warnings: LocalDataWarning[];
  diagnostics: QuotaDiagnostic[];
}
