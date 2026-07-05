import type { LocalDataWarning, QuotaDiagnostic } from "./diagnostics";

export interface AccountInfo {
  displayName: string;
  planLabel: string;
}

export interface QuotaLimit {
  label: string;
  remainingPercent: number;
  usedPercent: number;
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
  account: AccountInfo;
  quota: QuotaSnapshot;
  quotaHistoryDaily: QuotaHistoryDailyPoint[];
  quotaHistory24h: QuotaHistoryPoint[];
  quotaHistory7d: QuotaHistoryPoint[];
  quotaHistory30d: QuotaHistoryPoint[];
  warnings: LocalDataWarning[];
  diagnostics: QuotaDiagnostic[];
}
