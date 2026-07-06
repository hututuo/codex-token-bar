import { memo } from "react";
import type { DashboardStats, LocalDataWarning } from "../types/dashboard";
import { usagePrecisionWarnings } from "../state/dashboardWarnings";
import { formatTokens } from "../utils/format";

interface StatsStripProps {
  stats: DashboardStats;
  warnings?: LocalDataWarning[];
}

const statsConfig: Array<[keyof DashboardStats, string, (value: number) => string]> = [
  ["totalTokens", "累计 Token 数", formatTokens],
  ["peakDayTokens", "峰值 Token 数", formatTokens],
  ["peakThreadTokens", "单会话最大 Token", formatTokens],
  ["currentStreakDays", "当前连续天数", (value) => `${value} 天`],
  ["longestStreakDays", "最长连续天数", (value) => `${value} 天`],
];

function StatsStripView({ stats, warnings = [] }: StatsStripProps) {
  const usageWarnings = usagePrecisionWarnings(warnings);
  return (
    <>
      <section className="stats-strip" aria-label="Token 总览">
        {statsConfig.map(([key, label, format]) => (
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
