import { useMemo, useState } from "react";
import type { ActivityDay } from "../types/dashboard";
import { clamp, formatPercent, formatTokens } from "../utils/format";

type ActivityMode = "daily" | "weekly" | "cumulative" | "cache" | "quota";

interface TokenActivitySectionProps {
  days: ActivityDay[];
}

interface HeatmapDay {
  day: ActivityDay;
  intensity: number;
}

const modes: Array<{ id: ActivityMode; label: string }> = [
  { id: "daily", label: "每日" },
  { id: "weekly", label: "每周" },
  { id: "cumulative", label: "累计" },
  { id: "cache", label: "命中率" },
  { id: "quota", label: "额度" },
];

export function TokenActivitySection({ days }: TokenActivitySectionProps) {
  const [mode, setMode] = useState<ActivityMode>("daily");
  const [rangeStart, setRangeStart] = useState<string | null>(null);
  const [rangeEnd, setRangeEnd] = useState<string | null>(null);

  const heatmapDays = useMemo(() => buildHeatmapDays(days, mode), [days, mode]);
  const selectedDays = useMemo(
    () => days.filter((day) => isInRange(day.date, rangeStart, rangeEnd)),
    [days, rangeEnd, rangeStart],
  );
  const summary = summarizeRange(selectedDays, rangeStart, rangeEnd, mode);

  function chooseDate(date: string) {
    if (rangeStart === null || rangeEnd !== null) {
      setRangeStart(date);
      setRangeEnd(null);
      return;
    }
    if (date < rangeStart) {
      setRangeEnd(rangeStart);
      setRangeStart(date);
    } else {
      setRangeEnd(date);
    }
  }

  return (
    <section className="activity-section" aria-label="Token 活动">
      <div className="section-title-row">
        <h2>Token 活动</h2>
        <div className="segmented segmented--activity" role="group" aria-label="Token 活动模式">
          {modes.map((item) => (
            <button
              className={item.id === mode ? "active" : undefined}
              key={item.id}
              onClick={() => setMode(item.id)}
              type="button"
            >
              {item.label}
            </button>
          ))}
        </div>
      </div>

      <div className="heatmap-grid">
        {heatmapDays.map(({ day, intensity }) => {
          const selected = isInRange(day.date, rangeStart, rangeEnd);
          return (
            <button
              aria-label={cellLabel(day, mode)}
              aria-pressed={selected}
              className={selected ? "heatmap-cell heatmap-cell--selected" : "heatmap-cell"}
              key={day.date}
              onClick={() => chooseDate(day.date)}
              style={{ backgroundColor: cellColor(mode, intensity) }}
              title={cellLabel(day, mode)}
              type="button"
            />
          );
        })}
      </div>

      <div className="range-summary">
        <span>{summary.hint}</span>
        <strong>{summary.value}</strong>
      </div>
    </section>
  );
}

function buildHeatmapDays(days: ActivityDay[], mode: ActivityMode): HeatmapDay[] {
  let cumulative = 0;
  const rawValues = days.map((day, index) => {
    switch (mode) {
      case "weekly":
        return sumTokens(days.slice(Math.max(0, index - 6), index + 1));
      case "cumulative":
        cumulative += day.tokens;
        return cumulative > 0 ? cumulative : null;
      case "cache":
        return day.tokens > 0 ? day.cacheHitRate : null;
      case "quota":
        return day.sevenDayRemainingPercent ?? day.fiveHourRemainingPercent;
      case "daily":
      default:
        return day.tokens > 0 ? day.tokens : null;
    }
  });

  const tokenMax = Math.max(
    ...rawValues
      .filter((value): value is number => value !== null)
      .map((value) => Math.max(value, 0)),
    1,
  );

  return days.map((day, index) => {
    const value = rawValues[index];
    return {
      day,
      intensity: normalizeValue(value, tokenMax, mode),
    };
  });
}

function normalizeValue(value: number | null, tokenMax: number, mode: ActivityMode): number {
  if (value === null || !Number.isFinite(value)) {
    return 0;
  }
  if (mode === "cache") {
    return clamp((value - 0.75) / 0.25, 0, 1);
  }
  if (mode === "quota") {
    return clamp((value - 0.55) / 0.45, 0, 1);
  }
  return clamp(value / tokenMax, 0, 1);
}

function summarizeRange(
  selectedDays: ActivityDay[],
  rangeStart: string | null,
  rangeEnd: string | null,
  mode: ActivityMode,
) {
  if (rangeStart === null) {
    return {
      hint: "点击开始和结束日期，可显示范围总计",
      value: "总计",
    };
  }
  if (rangeEnd === null) {
    return {
      hint: `${rangeStart} 已选中，再点一个结束日期`,
      value: "等待结束日期",
    };
  }

  const tokens = sumTokens(selectedDays);
  const calls = selectedDays.reduce((total, day) => total + day.calls, 0);
  if (mode === "cache") {
    return {
      hint: `${rangeStart} - ${rangeEnd}`,
      value: `命中率均值 ${formatPercent(weightedCacheRate(selectedDays))} · ${calls} calls`,
    };
  }
  if (mode === "quota") {
    return {
      hint: `${rangeStart} - ${rangeEnd}`,
      value: `7d ${formatOptionalPercent(averageQuota(selectedDays, "sevenDayRemainingPercent"))} · 5h ${formatOptionalPercent(
        averageQuota(selectedDays, "fiveHourRemainingPercent"),
      )}`,
    };
  }
  return {
    hint: `${rangeStart} - ${rangeEnd}`,
    value: `${formatTokens(tokens)} tokens · ${calls} calls`,
  };
}

function weightedCacheRate(days: ActivityDay[]): number {
  const activeDays = days.filter((day) => day.tokens > 0);
  const weightedCalls = activeDays.reduce((total, day) => total + day.calls, 0);
  if (weightedCalls === 0) {
    return 0;
  }
  return (
    activeDays.reduce((total, day) => total + day.cacheHitRate * day.calls, 0) / weightedCalls
  );
}

function averageQuota(
  days: ActivityDay[],
  key: "fiveHourRemainingPercent" | "sevenDayRemainingPercent",
): number | null {
  const values = days
    .map((day) => day[key])
    .filter((value): value is number => value !== null && Number.isFinite(value));
  if (values.length === 0) {
    return null;
  }
  return values.reduce((total, value) => total + value, 0) / values.length;
}

function formatOptionalPercent(value: number | null): string {
  return value === null ? "暂无" : formatPercent(value);
}

function isInRange(date: string, rangeStart: string | null, rangeEnd: string | null): boolean {
  if (rangeStart === null) {
    return false;
  }
  if (rangeEnd === null) {
    return date === rangeStart;
  }
  return date >= rangeStart && date <= rangeEnd;
}

function sumTokens(days: ActivityDay[]): number {
  return days.reduce((total, day) => total + day.tokens, 0);
}

function cellColor(mode: ActivityMode, intensity: number): string {
  const color = mode === "cache" ? "#03a6c8" : mode === "quota" ? "var(--green)" : "var(--accent)";
  const weight = Math.round(14 + intensity * 78);
  return `color-mix(in srgb, ${color} ${weight}%, var(--heatmap-empty))`;
}

function cellLabel(day: ActivityDay, mode: ActivityMode): string {
  if (mode === "cache") {
    return `${day.date} · 命中率 ${formatPercent(day.cacheHitRate)} · ${day.calls} calls`;
  }
  if (mode === "quota") {
    return `${day.date} · 7d ${formatOptionalPercent(day.sevenDayRemainingPercent)} · 5h ${formatOptionalPercent(
      day.fiveHourRemainingPercent,
    )}`;
  }
  return `${day.date} · ${formatTokens(day.tokens)} tokens · ${day.calls} calls`;
}
