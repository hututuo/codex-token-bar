import type { RecentUsagePoint } from "../types/dashboard";

interface RecentUsageChartProps {
  points: RecentUsagePoint[];
}

function pathFor(values: number[], width: number, height: number) {
  const max = Math.max(...values, 1);
  return values
    .map((value, index) => {
      const x = (index / Math.max(values.length - 1, 1)) * width;
      const y = height - (value / max) * height;
      return `${index === 0 ? "M" : "L"} ${x.toFixed(1)} ${y.toFixed(1)}`;
    })
    .join(" ");
}

function percentPath(
  points: RecentUsagePoint[],
  key: "cacheHitRate" | "fiveHourRemainingPercent" | "sevenDayRemainingPercent",
  width: number,
  height: number,
) {
  const values = points.map((point) => point[key] ?? null);
  const segments: string[] = [];

  values.forEach((value, index) => {
    if (value === null) {
      return;
    }
    const x = (index / Math.max(values.length - 1, 1)) * width;
    const y = height - value * height;
    segments.push(`${segments.length === 0 ? "M" : "L"} ${x.toFixed(1)} ${y.toFixed(1)}`);
  });

  return segments.join(" ");
}

export function RecentUsageChart({ points }: RecentUsageChartProps) {
  const width = 980;
  const height = 230;
  const tokenValues = points.map((point) => point.tokens);
  const callsValues = points.map((point) => point.calls);

  return (
    <section className="chart-section" aria-label="最近 24 小时">
      <div className="section-title-row">
        <div>
          <h2>最近 24 小时</h2>
          <span>5 分钟粒度 · 5 分钟自动刷新</span>
        </div>
        <div className="chart-legend">
          <span className="legend-dot legend-dot--token" /> Token
          <span className="legend-dot legend-dot--calls" /> 调用
          <span className="legend-dot legend-dot--hit" /> 命中率
          <span className="legend-dot legend-dot--five" /> 5h
          <span className="legend-dot legend-dot--seven" /> 7d
        </div>
      </div>

      <svg className="usage-chart" viewBox={`0 0 ${width} ${height}`} role="img">
        <path className="chart-area" d={`${pathFor(tokenValues, width, height)} L ${width} ${height} L 0 ${height} Z`} />
        <path className="chart-line chart-line--token" d={pathFor(tokenValues, width, height)} />
        <path className="chart-line chart-line--calls" d={pathFor(callsValues, width, height)} />
        <path className="chart-line chart-line--hit" d={percentPath(points, "cacheHitRate", width, height)} />
        <path className="chart-line chart-line--five" d={percentPath(points, "fiveHourRemainingPercent", width, height)} />
        <path className="chart-line chart-line--seven" d={percentPath(points, "sevenDayRemainingPercent", width, height)} />
      </svg>
    </section>
  );
}
