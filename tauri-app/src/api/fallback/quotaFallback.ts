import type { AccountQuotaBundle, QuotaSnapshot } from "../../types/quota";
import { emptyRecentUsage } from "./timeSeriesFallback";

export function emptyQuotaSnapshot(): QuotaSnapshot {
  return {
    fiveHour: {
      label: "5h",
      remainingPercent: 0,
      usedPercent: 0,
      resetsAt: "待读取",
      resetsAtUnix: null,
    },
    sevenDay: {
      label: "7d",
      remainingPercent: 0,
      usedPercent: 0,
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
  return {
    account: {
      displayName: "账户待读取",
      planLabel: "计划待读取",
    },
    quota: emptyQuotaSnapshot(),
    quotaHistory24h: emptyRecentUsage(new Date()).map((point) => ({
      label: point.label,
      fiveHourRemainingPercent: null,
      sevenDayRemainingPercent: null,
    })),
    warnings: [],
  };
}
