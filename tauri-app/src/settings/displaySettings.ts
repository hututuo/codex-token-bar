import type {
  DisplaySurfaceSettings,
  StatusMetricId,
  StatusMetricLabelStyle,
  StatusSummarySectionId,
} from "../types/dashboard";
import type { PlatformCapabilities } from "../types/dashboard";

export const STATUS_METRIC_IDS = [
  "rate",
  "fiveHour",
  "sevenDay",
  "iq",
  "today",
  "total",
  "requests",
  "running",
  "unread",
] as const satisfies readonly StatusMetricId[];

export const DEFAULT_STATUS_METRIC_ORDER: StatusMetricId[] = [
  "rate",
  "fiveHour",
  "sevenDay",
  "iq",
];

export const DEFAULT_STATUS_METRIC_LABEL_STYLE: StatusMetricLabelStyle = "compact";

export const STATUS_SUMMARY_SECTION_IDS = [
  "overview",
  "usage",
  "quota",
  "running",
  "unread",
  "radar",
  "crowdRadar",
] as const satisfies readonly StatusSummarySectionId[];

export const DEFAULT_STATUS_SUMMARY_ORDER: StatusSummarySectionId[] = [
  ...STATUS_SUMMARY_SECTION_IDS,
];

export const DEFAULT_DISPLAY_SURFACES: DisplaySurfaceSettings = {
  floatingWindowEnabled: true,
  liveRateEnabled: true,
  statusTrayLiveTextEnabled: false,
  statusMetricOrder: [...DEFAULT_STATUS_METRIC_ORDER],
  statusMetricLabelStyle: DEFAULT_STATUS_METRIC_LABEL_STYLE,
  statusSummaryOrder: [...DEFAULT_STATUS_SUMMARY_ORDER],
};

export const INACTIVE_DISPLAY_SURFACES: DisplaySurfaceSettings = {
  floatingWindowEnabled: false,
  liveRateEnabled: true,
  statusTrayLiveTextEnabled: false,
  statusMetricOrder: [...DEFAULT_STATUS_METRIC_ORDER],
  statusMetricLabelStyle: DEFAULT_STATUS_METRIC_LABEL_STYLE,
  statusSummaryOrder: [...DEFAULT_STATUS_SUMMARY_ORDER],
};

export function sanitizeDisplaySurfaces(
  settings: Partial<DisplaySurfaceSettings>,
): DisplaySurfaceSettings {
  return {
    floatingWindowEnabled:
      typeof settings.floatingWindowEnabled === "boolean"
        ? settings.floatingWindowEnabled
        : DEFAULT_DISPLAY_SURFACES.floatingWindowEnabled,
    liveRateEnabled:
      typeof settings.liveRateEnabled === "boolean"
        ? settings.liveRateEnabled
        : DEFAULT_DISPLAY_SURFACES.liveRateEnabled,
    statusTrayLiveTextEnabled:
      typeof settings.statusTrayLiveTextEnabled === "boolean"
        ? settings.statusTrayLiveTextEnabled
        : DEFAULT_DISPLAY_SURFACES.statusTrayLiveTextEnabled,
    statusMetricOrder: sanitizeStatusMetricOrder(settings.statusMetricOrder),
    statusMetricLabelStyle: sanitizeStatusMetricLabelStyle(settings.statusMetricLabelStyle),
    statusSummaryOrder: sanitizeStatusSummaryOrder(settings.statusSummaryOrder),
  };
}

export function sanitizeStatusMetricOrder(value: unknown): StatusMetricId[] {
  if (!Array.isArray(value)) {
    return [...DEFAULT_STATUS_METRIC_ORDER];
  }
  const supported = new Set<string>(STATUS_METRIC_IDS);
  const seen = new Set<StatusMetricId>();
  const sanitized: StatusMetricId[] = [];
  for (const item of value) {
    if (typeof item !== "string" || !supported.has(item)) {
      continue;
    }
    const metric = item as StatusMetricId;
    if (!seen.has(metric)) {
      seen.add(metric);
      sanitized.push(metric);
    }
  }
  return sanitized;
}

export function sanitizeStatusMetricLabelStyle(value: unknown): StatusMetricLabelStyle {
  return value === "full" || value === "compact" || value === "hidden"
    ? value
    : DEFAULT_STATUS_METRIC_LABEL_STYLE;
}

export function sanitizeStatusSummaryOrder(value: unknown): StatusSummarySectionId[] {
  if (!Array.isArray(value)) {
    return [...DEFAULT_STATUS_SUMMARY_ORDER];
  }
  const supported = new Set<string>(STATUS_SUMMARY_SECTION_IDS);
  const seen = new Set<StatusSummarySectionId>();
  const sanitized: StatusSummarySectionId[] = [];
  for (const item of value) {
    if (typeof item !== "string" || !supported.has(item)) {
      continue;
    }
    const section = item as StatusSummarySectionId;
    if (!seen.has(section)) {
      seen.add(section);
      sanitized.push(section);
    }
  }
  return sanitized;
}

export function isPlatformCapabilitiesReady(platform: PlatformCapabilities | null): boolean {
  return platform !== null && platform.platform !== "loading";
}

export function canUseFloatingWindow(platform: PlatformCapabilities | null): boolean {
  return platform !== null && platform.platform !== "loading" && platform.floatingWindow.available;
}

export function canUseStatusTray(platform: PlatformCapabilities | null): boolean {
  return platform !== null && platform.platform !== "loading" && platform.statusTray.available;
}

export function canUseStatusTrayLiveText(platform: PlatformCapabilities | null): boolean {
  return (
    platform !== null &&
    platform.platform !== "loading" &&
    platform.statusTray.available &&
    platform.statusTrayLiveText.available
  );
}
