import type { AccountQuotaBundle, QuotaSnapshot } from "../../types/quota";
import { emptyActivityDays, emptyRecentUsage } from "./timeSeriesFallback";

export function emptyQuotaSnapshot(): QuotaSnapshot {
  return {
    fiveHour: {
      label: "5h",
      availability: "unavailable",
      remainingPercent: null,
      usedPercent: null,
      resetsAt: "待读取",
      resetsAtUnix: null,
    },
    sevenDay: {
      label: "7d",
      availability: "unavailable",
      remainingPercent: null,
      usedPercent: null,
      resetsAt: "待读取",
      resetsAtUnix: null,
    },
    resetCredit: {
      availableCount: 0,
      status: "重置卡待读取",
      credits: [],
    },
    paceLabel: "额度待读取",
  };
}

export function emptyAccountQuotaBundle(): AccountQuotaBundle {
  const now = new Date();
  const emptyQuotaHistoryDaily = emptyActivityDays(now).map((day) => ({
    date: day.date,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
  }));
  const emptyQuotaHistory24h = emptyRecentUsage(now).map((point) => ({
    label: point.label,
    startUnix: point.startUnix,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
  }));
  const emptyQuotaHistory7d = emptyRecentUsage(now, 60 * 60 * 1_000, 7 * 24).map((point) => ({
    label: point.label,
    startUnix: point.startUnix,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
  }));
  const emptyQuotaHistory30d = emptyRecentUsage(now, 6 * 60 * 60 * 1_000, 30 * 4).map((point) => ({
    label: point.label,
    startUnix: point.startUnix,
    fiveHourRemainingPercent: null,
    sevenDayRemainingPercent: null,
  }));

  return {
    account: {
      displayName: "账户待读取",
      planLabel: "计划待读取",
    },
    quota: emptyQuotaSnapshot(),
    quotaHistoryDaily: emptyQuotaHistoryDaily,
    quotaHistory24h: emptyQuotaHistory24h,
    quotaHistory7d: emptyQuotaHistory7d,
    quotaHistory30d: emptyQuotaHistory30d,
    warnings: [],
    diagnostics: [],
  };
}
