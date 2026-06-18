import type { ActivityDay } from "../types/dashboard";
import { clamp } from "../utils/format";

interface TokenActivitySectionProps {
  days: ActivityDay[];
}

export function TokenActivitySection({ days }: TokenActivitySectionProps) {
  return (
    <section className="activity-section" aria-label="Token 活动">
      <div className="section-title-row">
        <h2>Token 活动</h2>
        <div className="segmented">
          <button className="active" type="button">
            每日
          </button>
          <button type="button">每周</button>
          <button type="button">累计</button>
          <button type="button">命中率</button>
          <button type="button">额度</button>
        </div>
      </div>

      <div className="heatmap-grid">
        {days.map((day) => {
          const level = clamp(day.tokens / 58_000_000, 0, 1);
          return (
            <span
              aria-label={`${day.date} ${day.tokens} tokens`}
              className="heatmap-cell"
              key={day.date}
              style={{
                backgroundColor: `color-mix(in srgb, var(--accent) ${Math.round(
                  18 + level * 72,
                )}%, var(--heatmap-empty))`,
              }}
              title={`${day.date} · ${day.calls} calls`}
            />
          );
        })}
      </div>

      <div className="range-summary">
        <span>点击开始和结束日期，可显示范围总计</span>
        <strong>总计</strong>
      </div>
    </section>
  );
}
