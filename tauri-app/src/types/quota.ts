import type { LocalDataWarning } from "./diagnostics";

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
  fiveHourRemainingPercent: number | null;
  sevenDayRemainingPercent: number | null;
}

export interface ResetCreditSummary {
  availableCount: number;
  status: string;
  credits: ResetCreditDetail[];
}

export interface ResetCreditDetail {
  title: string;
  status: string;
  summary: string;
  issuedAt: string;
  expiresAt: string;
  redeemedAt: string;
  source: string;
  associatedUser: string;
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
  quotaHistory24h: QuotaHistoryPoint[];
  warnings: LocalDataWarning[];
}
