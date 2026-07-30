import type { CodexRadarSnapshot } from "../domain/codexRadar/model";
import type {
  FloatingPanelSnapshot,
  RunningThreadSummary,
  StatusMetricId,
  StatusMetricLabelStyle,
} from "../types/dashboard";

export interface StatusIndicatorItem {
  available: boolean;
  id: StatusMetricId;
  shortLabel: string;
  tooltipLabel: string;
  value: string;
}

export interface StatusIndicatorPresentation {
  title: string;
  tooltip: string;
  width: number;
  visibleItems: StatusIndicatorItem[];
}

export interface StatusIndicatorPresentationInput {
  labelStyle: StatusMetricLabelStyle;
  metricStates: StatusMetricStates;
  order: readonly StatusMetricId[];
  radar?: CodexRadarSnapshot | null;
  running?: RunningThreadSummary | null;
  snapshot: FloatingPanelSnapshot;
}

export interface StatusMetricState {
  available: boolean;
  value: string;
}

export interface StatusMetricStates {
  rate: StatusMetricState;
  requests: StatusMetricState;
  today: StatusMetricState;
  total: StatusMetricState;
  unread: StatusMetricState;
}

export interface StatusMetricStatesInput {
  liveRateEnabled: boolean;
  snapshot: FloatingPanelSnapshot;
  sourceReady: boolean;
}

export function buildStatusMetricStates({
  liveRateEnabled,
  snapshot,
  sourceReady,
}: StatusMetricStatesInput): StatusMetricStates {
  const rateAvailable = sourceReady
    && liveRateEnabled
    && snapshot.liveRateAvailable === true
    && snapshot.liveRateStatusKind !== "failure"
    && Number.isFinite(snapshot.tokensPerSecond);
  const unreadAvailable = sourceReady
    && snapshot.unreadSummary.source !== "pending"
    && Number.isFinite(snapshot.unreadSummary.count);

  return {
    rate: {
      available: rateAvailable,
      value: rateAvailable ? formatStatusRate(snapshot.tokensPerSecond) : "—",
    },
    today: summaryLabelState(sourceReady, snapshot.todayTokensLabel, /^今\s*/),
    total: summaryLabelState(sourceReady, snapshot.totalTokensLabel, /^总\s*/),
    requests: summaryLabelState(sourceReady, snapshot.requestsLabel, /^次\s*/),
    unread: {
      available: unreadAvailable,
      value: unreadAvailable
        ? String(Math.max(0, Math.round(snapshot.unreadSummary.count)))
        : "—",
    },
  };
}

export function buildStatusIndicatorPresentation({
  labelStyle,
  metricStates,
  order,
  radar = null,
  running = null,
  snapshot,
}: StatusIndicatorPresentationInput): StatusIndicatorPresentation {
  const visibleItems = order.flatMap((id) => {
    const item = statusIndicatorItem(
      id,
      labelStyle,
      metricStates,
      snapshot,
      radar,
      running,
    );
    return item === null ? [] : [item];
  });
  const title = visibleItems.map((item) => item.shortLabel).join(" · ");
  return {
    title,
    tooltip: visibleItems.length > 0
      ? `Codex Token Bar · ${visibleItems.map((item) => item.tooltipLabel).join(" · ")}`
      : "Codex Token Bar",
    width: estimateStatusIndicatorWidth(title),
    visibleItems,
  };
}

export function buildStatusIndicatorPreview(
  order: readonly StatusMetricId[],
  labelStyle: StatusMetricLabelStyle = "compact",
): StatusIndicatorPresentation {
  const sampleValues: Record<StatusMetricId, string> = {
    rate: "12.4",
    fiveHour: "42%",
    sevenDay: "76%",
    iq: "104",
    today: "84K",
    total: "1.2M",
    requests: "42",
    running: "3",
    unread: "2",
  };
  const tooltips: Record<StatusMetricId, string> = {
    rate: "速度 12.4 tok/s",
    fiveHour: "5 小时额度剩余 42%",
    sevenDay: "7 天额度剩余 76%",
    iq: "雷达 IQ 104",
    today: "今日 Token 84K",
    total: "累计 Token 1.2M",
    requests: "请求 42",
    running: "运行任务 3",
    unread: "未读会话 2",
  };
  const visibleItems = order.map((id) => ({
    available: true,
    id,
    shortLabel: shortMetricLabel(id, sampleValues[id], labelStyle),
    tooltipLabel: tooltips[id],
    value: sampleValues[id],
  }));
  const title = visibleItems.map((item) => item.shortLabel).join(" · ");
  return {
    title,
    tooltip: visibleItems.length > 0
      ? `Codex Token Bar · ${visibleItems.map((item) => item.tooltipLabel).join(" · ")}`
      : "Codex Token Bar",
    width: estimateStatusIndicatorWidth(title),
    visibleItems,
  };
}

function statusIndicatorItem(
  id: StatusMetricId,
  labelStyle: StatusMetricLabelStyle,
  metricStates: StatusMetricStates,
  snapshot: FloatingPanelSnapshot,
  radar: CodexRadarSnapshot | null,
  running: RunningThreadSummary | null,
): StatusIndicatorItem | null {
  switch (id) {
    case "rate": {
      const { available, value } = metricStates.rate;
      return {
        available,
        id,
        shortLabel: shortMetricLabel(id, value, labelStyle),
        tooltipLabel: available ? `速度 ${value} tok/s` : "速度暂不可用",
        value,
      };
    }
    case "fiveHour":
      return quotaItem(
        id,
        "5 小时额度",
        snapshot.fiveHourAvailability,
        snapshot.fiveHourRemainingPercent,
        labelStyle,
      );
    case "sevenDay":
      return quotaItem(
        id,
        "7 天额度",
        snapshot.sevenDayAvailability,
        snapshot.sevenDayRemainingPercent,
        labelStyle,
      );
    case "iq": {
      const score = radar === null ? null : primaryIqScore(radar);
      const available = score !== null;
      const value = available ? compactDecimal(score) : "—";
      return {
        available,
        id,
        shortLabel: shortMetricLabel(id, value, labelStyle),
        tooltipLabel: available ? `雷达 IQ ${value}` : "雷达 IQ 暂不可用",
        value,
      };
    }
    case "today":
      return metricStateItem(id, "今日 Token", metricStates.today, labelStyle);
    case "total":
      return metricStateItem(id, "累计 Token", metricStates.total, labelStyle);
    case "requests":
      return metricStateItem(id, "请求", metricStates.requests, labelStyle);
    case "running": {
      const total = running?.total;
      const available = total !== null && total !== undefined && Number.isFinite(total);
      const value = available ? String(Math.max(0, Math.round(total))) : "—";
      return {
        available,
        id,
        shortLabel: shortMetricLabel(id, value, labelStyle),
        tooltipLabel: available ? `运行任务 ${value}` : "运行任务暂不可用",
        value,
      };
    }
    case "unread": {
      const { available, value } = metricStates.unread;
      return {
        available,
        id,
        shortLabel: shortMetricLabel(id, value, labelStyle),
        tooltipLabel: available ? `未读会话 ${value}` : "未读会话暂不可用",
        value,
      };
    }
  }
}

function formatStatusRate(value: number): string {
  if (value <= 0) {
    return "0";
  }
  return value < 0.05 ? "0" : value.toFixed(1);
}

function primaryIqScore(radar: CodexRadarSnapshot): number | null {
  const points = [
    radar.modelIq.latest,
    ...Object.values(radar.modelIq.comparisons ?? {}).map((comparison) => comparison.latest),
  ];
  const measured = points.find((point) => (
    Number.isFinite(point.score)
    && (point.validTasks > 0 || point.tasks > 0 || point.passed > 0)
  ));
  return measured?.score ?? null;
}

function quotaItem(
  id: "fiveHour" | "sevenDay",
  tooltipPrefix: string,
  availability: FloatingPanelSnapshot["fiveHourAvailability"],
  remainingPercent: number | null,
  labelStyle: StatusMetricLabelStyle,
): StatusIndicatorItem {
  const measured = availability === "measured"
    && remainingPercent !== null
    && Number.isFinite(remainingPercent)
    ? remainingPercent
    : null;
  const value = measured !== null
    ? `${Math.round(Math.min(100, Math.max(0, measured)))}%`
    : "—";
  return {
    available: measured !== null,
    id,
    shortLabel: shortMetricLabel(id, value, labelStyle),
    tooltipLabel: measured !== null ? `${tooltipPrefix}剩余 ${value}` : `${tooltipPrefix}暂不可用`,
    value,
  };
}

function metricStateItem(
  id: "today" | "total" | "requests",
  tooltipPrefix: string,
  state: StatusMetricState,
  labelStyle: StatusMetricLabelStyle,
): StatusIndicatorItem {
  return {
    available: state.available,
    id,
    shortLabel: shortMetricLabel(id, state.value, labelStyle),
    tooltipLabel: state.available
      ? `${tooltipPrefix} ${state.value}`
      : `${tooltipPrefix}暂不可用`,
    value: state.value,
  };
}

function summaryLabelState(
  sourceReady: boolean,
  rawLabel: string,
  prefixPattern: RegExp,
): StatusMetricState {
  const value = rawLabel.replace(prefixPattern, "").trim();
  const unavailable = !sourceReady || isUnavailableSummaryValue(value);
  return {
    available: !unavailable,
    value: unavailable ? "—" : value,
  };
}

function isUnavailableSummaryValue(value: string): boolean {
  const normalized = value.replace(/\s+/gu, "");
  return normalized.length === 0
    || normalized === "—"
    || normalized.includes("待读取")
    || normalized.includes("读取失败")
    || normalized.includes("不可用");
}

function shortMetricLabel(
  id: StatusMetricId,
  value: string,
  labelStyle: StatusMetricLabelStyle,
): string {
  if (labelStyle === "hidden") {
    return value;
  }
  const prefixes: Record<StatusMetricId, { compact: string; full: string }> = {
    rate: { compact: "", full: "速率" },
    fiveHour: { compact: "⁵ʰ", full: "5h" },
    sevenDay: { compact: "⁷ᵈ", full: "7d" },
    iq: { compact: "IQ", full: "IQ" },
    today: { compact: "今", full: "今日" },
    total: { compact: "总", full: "累计" },
    requests: { compact: "次", full: "请求" },
    running: { compact: "跑", full: "运行" },
    unread: { compact: "未", full: "未读" },
  };
  const prefix = prefixes[id][labelStyle];
  const suffix = id === "rate" ? "/s" : "";
  return `${prefix}${value}${suffix}`;
}

function compactDecimal(value: number): string {
  const rounded = Math.round(value * 10) / 10;
  return Number.isInteger(rounded) ? rounded.toFixed(0) : rounded.toFixed(1);
}

export function estimateStatusIndicatorWidth(title: string): number {
  if (!title) {
    return 0;
  }
  let contentWidth = 0;
  for (const character of title) {
    if (/[\u2E80-\u9FFF]/u.test(character)) {
      contentWidth += 12;
    } else if (/[A-Z]/u.test(character)) {
      contentWidth += 8;
    } else if (/[0-9]/u.test(character)) {
      contentWidth += 7;
    } else {
      contentWidth += 5;
    }
  }
  return Math.ceil(Math.min(720, Math.max(64, contentWidth + 44)));
}
