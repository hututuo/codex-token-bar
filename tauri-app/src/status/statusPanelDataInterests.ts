import type {
  StatusMetricId,
  StatusSummarySectionId,
} from "../types/dashboard";

export interface StatusPanelDataInterests {
  crowdRadar: boolean;
  liveRate: boolean;
  quota: boolean;
  radar: boolean;
  running: boolean;
  snapshot: boolean;
}

export interface StatusPanelDataInterestsInput {
  liveRateEnabled: boolean;
  metricOrder: readonly StatusMetricId[];
  panelVisible: boolean;
  statusMetricsEnabled: boolean;
  summaryOrder: readonly StatusSummarySectionId[];
}

const USAGE_METRICS = new Set<StatusMetricId>([
  "today",
  "total",
  "requests",
]);
const QUOTA_METRICS = new Set<StatusMetricId>(["fiveHour", "sevenDay"]);
export function statusPanelBackgroundActive(
  statusMetricsEnabled: boolean,
  metricOrder: readonly StatusMetricId[],
): boolean {
  return statusMetricsEnabled && metricOrder.length > 0;
}

export function statusPanelSummaryVisible(
  nativeWindowVisible: boolean,
  compact: boolean,
): boolean {
  return nativeWindowVisible && !compact;
}

export function buildStatusPanelDataInterests({
  liveRateEnabled,
  metricOrder,
  panelVisible,
  statusMetricsEnabled,
  summaryOrder,
}: StatusPanelDataInterestsInput): StatusPanelDataInterests {
  const compactMetrics = statusMetricsEnabled ? metricOrder : [];
  const visibleSummaries = panelVisible ? summaryOrder : [];
  const liveRate = liveRateEnabled
    && (
      compactMetrics.includes("rate")
      || visibleSummaries.includes("overview")
    );

  return {
    liveRate,
    snapshot: compactMetrics.some((id) => USAGE_METRICS.has(id))
      || compactMetrics.includes("unread")
      || visibleSummaries.includes("usage")
      || visibleSummaries.includes("unread")
      || liveRate,
    quota: compactMetrics.some((id) => QUOTA_METRICS.has(id))
      || visibleSummaries.some((id) => id === "quota" || id === "overview"),
    running: compactMetrics.includes("running")
      || visibleSummaries.includes("running"),
    radar: visibleSummaries.includes("radar"),
    crowdRadar: compactMetrics.includes("iq")
      || visibleSummaries.includes("crowdRadar"),
  };
}
