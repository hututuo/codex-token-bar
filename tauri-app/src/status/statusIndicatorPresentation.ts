import {
  compactRadarModelName,
  rankedModelRows,
  type CodexRadarModelIQComparisonRow,
  type CodexRadarModelIQPoint,
  type CodexRadarSnapshot,
} from "../domain/codexRadar/model.ts";
import type {
  FloatingPanelSnapshot,
  QuotaDiagnostic,
  RunningThreadSummary,
  StatusMetricId,
  StatusMetricLabelStyle,
} from "../types/dashboard";

export interface StatusIndicatorItem {
  available: boolean;
  compactMarker?: {
    bottom: "H" | "D";
    top: "5" | "7";
  };
  compactRows?: [string, string];
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
  now?: Date;
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

export function statusSnapshotForQuotaDiagnostics(
  snapshot: FloatingPanelSnapshot,
  diagnostics: readonly QuotaDiagnostic[],
): FloatingPanelSnapshot {
  const staleQuotaDisplayed = diagnostics.some((diagnostic) => (
    diagnostic.staleDataDisplayed === true
    && (diagnostic.source === "account_quota" || diagnostic.category === "stale_cached_data")
  ));
  if (!staleQuotaDisplayed) {
    return snapshot;
  }
  return {
    ...snapshot,
    fiveHourAvailability: "unavailable",
    fiveHourExpectedRemainingPercent: null,
    fiveHourLabel: "5h",
    fiveHourRemainingPercent: null,
    sevenDayAvailability: "unavailable",
    sevenDayExpectedRemainingPercent: null,
    sevenDayLabel: "7d",
    sevenDayRemainingPercent: null,
  };
}

export function buildStatusIndicatorPresentation({
  labelStyle,
  metricStates,
  order,
  radar = null,
  running = null,
  snapshot,
  now = new Date(),
}: StatusIndicatorPresentationInput): StatusIndicatorPresentation {
  const visibleItems = order.flatMap((id) => {
    const item = statusIndicatorItem(
      id,
      labelStyle,
      metricStates,
      snapshot,
      radar,
      running,
      now,
    );
    return item === null ? [] : [item];
  });
  const title = visibleItems.map((item) => item.shortLabel).join(" · ");
  const compactWidthTitle = visibleItems.map(compactWidthLabel).join(" · ");
  return {
    title,
    tooltip: visibleItems.length > 0
      ? `Codex Token Bar · ${visibleItems.map((item) => item.tooltipLabel).join(" · ")}`
      : "Codex Token Bar",
    width: estimateStatusIndicatorWidth(compactWidthTitle),
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
    iq: "1 Sol·MAX / 2 Luna·H",
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
    iq: "今日模型榜：1 Sol·MAX；2 Luna·H",
    today: "今日 Token 84K",
    total: "累计 Token 1.2M",
    requests: "请求 42",
    running: "运行任务 3",
    unread: "未读会话 2",
  };
  const visibleItems = order.map((id): StatusIndicatorItem => {
    if (id === "iq") {
      return rankingItem(["Sol·MAX", "Luna·H"]);
    }
    const value = sampleValues[id];
    return {
      available: true,
      compactMarker: quotaMarker(id, labelStyle),
      id,
      shortLabel: shortMetricLabel(id, value, labelStyle),
      tooltipLabel: tooltips[id],
      value,
    };
  });
  const title = visibleItems.map((item) => item.shortLabel).join(" · ");
  const compactWidthTitle = visibleItems.map(compactWidthLabel).join(" · ");
  return {
    title,
    tooltip: visibleItems.length > 0
      ? `Codex Token Bar · ${visibleItems.map((item) => item.tooltipLabel).join(" · ")}`
      : "Codex Token Bar",
    width: estimateStatusIndicatorWidth(compactWidthTitle),
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
  now: Date,
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
      if (snapshot.fiveHourAvailability === "absent") {
        return null;
      }
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
    case "iq":
      return rankingItem(statusModelRanking(radar, now));
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
    ? `${Math.round(Math.min(1, Math.max(0, measured)) * 100)}%`
    : "—";
  return {
    available: measured !== null,
    compactMarker: quotaMarker(id, labelStyle),
    id,
    shortLabel: shortMetricLabel(id, value, labelStyle),
    tooltipLabel: measured !== null ? `${tooltipPrefix}剩余 ${value}` : `${tooltipPrefix}暂不可用`,
    value,
  };
}

function quotaMarker(
  id: StatusMetricId,
  labelStyle: StatusMetricLabelStyle,
): StatusIndicatorItem["compactMarker"] {
  if (labelStyle !== "compact") {
    return undefined;
  }
  if (id === "fiveHour") {
    return { top: "5", bottom: "H" };
  }
  if (id === "sevenDay") {
    return { top: "7", bottom: "D" };
  }
  return undefined;
}

function rankingItem(labels: readonly string[]): StatusIndicatorItem {
  const compactRows: [string, string] = [
    `1 ${labels[0] || "—"}`,
    `2 ${labels[1] || "—"}`,
  ];
  const available = labels.length > 0;
  const value = compactRows.join(" / ");
  return {
    available,
    compactRows,
    id: "iq",
    shortLabel: value,
    tooltipLabel: available
      ? `今日模型榜：${compactRows.join("；")}`
      : "今日模型榜暂不可用：1 —；2 —",
    value,
  };
}

function statusModelRanking(radar: CodexRadarSnapshot | null, now: Date): string[] {
  if (radar === null || radar.staleDataDisplayed === true) {
    return [];
  }
  const seen = new Set<string>();
  const labels: string[] = [];
  for (const row of rankedModelRows(radar.modelIq)) {
    if (!modelPointIsUsableToday(row.point, radar.timezone, now)) {
      continue;
    }
    const label = compactStatusModelLabel(row);
    if (label === null) {
      continue;
    }
    const key = `${statusModelIdentifier(row) ?? label}:${statusReasoningEffort(row) ?? ""}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    labels.push(label);
    if (labels.length === 2) {
      break;
    }
  }
  return labels;
}

function compactStatusModelLabel(row: CodexRadarModelIQComparisonRow): string | null {
  const model = statusModelIdentifier(row);
  const compactName = compactRadarModelName([model, row.label].filter(Boolean).join(" "));
  const family = compactName.match(/\b(Sol|Luna|Terra)\b/i)?.[1];
  const familyLabel = family
    ? family.charAt(0).toUpperCase() + family.slice(1).toLowerCase()
    : model
      ? compactModelIdentifier(model)
      : compactName
        .replace(/\b(ultra|max|x\s*high|xhigh|high|medium|low|minimal)\b/giu, "")
        .trim();
  if (!familyLabel || /^(?:--|MODEL|模型)$/iu.test(familyLabel)) {
    return null;
  }
  return `${familyLabel}·${compactReasoningEffort(statusReasoningEffort(row))}`;
}

function statusModelIdentifier(row: CodexRadarModelIQComparisonRow): string | null {
  return firstNonBlank(row.point.model, row.model);
}

function statusReasoningEffort(row: CodexRadarModelIQComparisonRow): string | null {
  return firstNonBlank(row.point.reasoningEffort, row.reasoningEffort);
}

function firstNonBlank(...values: Array<string | null | undefined>): string | null {
  for (const value of values) {
    const trimmed = value?.trim();
    if (trimmed) {
      return trimmed;
    }
  }
  return null;
}

function compactModelIdentifier(model: string | null | undefined): string {
  const normalized = model?.trim().replace(/^gpt-/i, "") ?? "";
  return normalized ? normalized.slice(0, 12) : "模型";
}

function compactReasoningEffort(effort: string | null | undefined): string {
  const labels: Record<string, string> = {
    ultra: "U",
    max: "MAX",
    xhigh: "XH",
    high: "H",
    medium: "M",
    low: "L",
    minimal: "MIN",
  };
  return labels[effort?.trim().toLowerCase() ?? ""] ?? "—";
}

function modelPointIsUsableToday(
  point: CodexRadarModelIQPoint,
  timeZone: string | null | undefined,
  now: Date,
): boolean {
  const hasSamples = typeof point.validTasks === "number" && Number.isFinite(point.validTasks)
    ? point.validTasks > 0
    : [point.tasks, point.passed]
      .some((value) => typeof value === "number" && Number.isFinite(value) && value > 0);
  if (point.scoreAvailable === false || !Number.isFinite(point.score) || !hasSamples) {
    return false;
  }
  const today = calendarDateKey(now, timeZone);
  return today !== null && radarPointDateKey(point.date, timeZone) === today;
}

function radarPointDateKey(rawDate: string, timeZone: string | null | undefined): string | null {
  const trimmed = rawDate.trim();
  if (/^\d{4}-\d{2}-\d{2}(?:$|-(?:am|pm)$)/iu.test(trimmed)) {
    return trimmed.slice(0, 10);
  }
  const parsed = new Date(trimmed);
  if (!Number.isFinite(parsed.getTime())) {
    return /^\d{4}-\d{2}-\d{2}/u.test(trimmed) ? trimmed.slice(0, 10) : null;
  }
  return calendarDateKey(parsed, timeZone);
}

function calendarDateKey(date: Date, timeZone: string | null | undefined): string | null {
  if (!Number.isFinite(date.getTime())) {
    return null;
  }
  const options: Intl.DateTimeFormatOptions = {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  };
  const normalizedTimeZone = timeZone?.trim();
  if (normalizedTimeZone) {
    options.timeZone = normalizedTimeZone;
  }
  let parts: Intl.DateTimeFormatPart[];
  try {
    parts = new Intl.DateTimeFormat("en-US", options).formatToParts(date);
  } catch {
    delete options.timeZone;
    parts = new Intl.DateTimeFormat("en-US", options).formatToParts(date);
  }
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return values.year && values.month && values.day
    ? `${values.year}-${values.month}-${values.day}`
    : null;
}

function compactWidthLabel(item: StatusIndicatorItem): string {
  if (item.compactRows) {
    return item.compactRows.reduce((longest, row) => (
      estimateStatusIndicatorWidth(row) > estimateStatusIndicatorWidth(longest) ? row : longest
    ), "");
  }
  return item.shortLabel;
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
    fiveHour: { compact: "5H", full: "5H" },
    sevenDay: { compact: "7D", full: "7D" },
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
