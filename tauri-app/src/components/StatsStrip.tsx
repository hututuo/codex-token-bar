import { memo, useEffect, useMemo, useState } from "react";
import type { DashboardStats, LocalDataWarning } from "../types/dashboard";
import { usagePrecisionWarnings } from "../state/dashboardWarnings";
import { formatTokens } from "../utils/format";
import type { OfficialAPIPriceModel } from "./recentUsageChart/model";
import {
  estimateLifetimeSavings,
  isOfficialAPIPriceModel,
  QUOTA_PRICE_MODEL_EVENT,
  lifetimeBreakdownFromStats,
  savingsPresentation,
} from "./statsStrip/savings";
import { readStoredQuotaPriceModel } from "../settings/quotaPriceModel";

interface StatsStripProps {
  stats: DashboardStats;
  planLabel: string;
  warnings?: LocalDataWarning[];
}

const statsConfig: Array<[keyof DashboardStats, string, (value: number) => string]> = [
  ["totalTokens", "累计 Token 数", formatTokens],
  ["peakDayTokens", "峰值 Token 数", formatTokens],
  ["peakThreadTokens", "单会话最大 Token", formatTokens],
  ["currentStreakDays", "当前连续天数", (value) => `${value} 天`],
  ["longestStreakDays", "最长连续天数", (value) => `${value} 天`],
];

function StatsStripView({ stats, planLabel, warnings = [] }: StatsStripProps) {
  const usageWarnings = usagePrecisionWarnings(warnings);
  const [priceModel, setPriceModel] = useState<OfficialAPIPriceModel>("gpt56Sol");
  const savings = useMemo(() => savingsPresentation(estimateLifetimeSavings({
    breakdown: lifetimeBreakdownFromStats(stats),
    firstUsageAt: stats.firstUsageAt,
    planLabel,
    priceModel,
    modelBreakdowns: stats.modelBreakdowns,
  })), [planLabel, priceModel, stats]);

  useEffect(() => {
    setPriceModel(readStoredQuotaPriceModel());
    const onPriceModel = (event: Event) => {
      const next = (event as CustomEvent<string>).detail;
      if (isOfficialAPIPriceModel(next)) setPriceModel(next);
    };
    window.addEventListener(QUOTA_PRICE_MODEL_EVENT, onPriceModel);
    return () => window.removeEventListener(QUOTA_PRICE_MODEL_EVENT, onPriceModel);
  }, []);

  return (
    <>
      <section className="stats-strip" aria-label="Token 总览">
        {statsConfig.slice(0, 1).map(([key, label, format]) => (
          <div className="stats-cell" key={key}>
            <strong>{format(Number(stats[key]))}</strong>
            <span>{label}</span>
          </div>
        ))}
        <div className="stats-cell stats-cell--savings" title={savings.helpText}>
          <strong>{savings.valueText}</strong>
          <span>{savings.labelText}</span>
        </div>
        {statsConfig.slice(1).map(([key, label, format]) => (
          <div className="stats-cell" key={key}>
            <strong>{format(Number(stats[key]))}</strong>
            <span>{label}</span>
          </div>
        ))}
      </section>
      {usageWarnings.length > 0 ? (
        <section className="usage-precision-note" aria-label="Token 统计读取提示" role="status">
          <strong>Token 统计准备中</strong>
          <span>{usageWarnings.map((warning) => warning.message).join("；")}</span>
        </section>
      ) : null}
    </>
  );
}

export const StatsStrip = memo(StatsStripView);
