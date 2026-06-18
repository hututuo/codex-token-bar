import type { DashboardStats } from "../types/dashboard";
import { formatTokens } from "../utils/format";

interface StatsStripProps {
  stats: DashboardStats;
}

const statsConfig: Array<[keyof DashboardStats, string, (value: number) => string]> = [
  ["totalTokens", "累计 Token 数", formatTokens],
  ["peakDayTokens", "峰值 Token 数", formatTokens],
  ["peakThreadTokens", "单会话最大 Token", formatTokens],
  ["currentStreakDays", "当前连续天数", (value) => `${value} 天`],
  ["longestStreakDays", "最长连续天数", (value) => `${value} 天`],
];

export function StatsStrip({ stats }: StatsStripProps) {
  return (
    <section className="stats-strip" aria-label="Token 总览">
      {statsConfig.map(([key, label, format]) => (
        <div className="stats-cell" key={key}>
          <strong>{format(Number(stats[key]))}</strong>
          <span>{label}</span>
        </div>
      ))}
    </section>
  );
}
