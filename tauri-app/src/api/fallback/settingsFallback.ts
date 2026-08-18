import type { AppSettingsSnapshot } from "../../types/settings";
import { DEFAULT_FLOATING_CONTENT_VISIBILITY } from "../../floating/floatingContent";
import { DEFAULT_QUOTA_REFRESH_INTERVAL_MS } from "../../settings/quotaRefreshCadence";
import { DEFAULT_AUTO_RESUME_SETTINGS } from "../../settings/autoResume";
import { DEFAULT_SESSION_ENHANCEMENTS } from "../../settings/sessionEnhancements";
import {
  DEFAULT_USAGE_BACKGROUND_AGGREGATE_INTERVAL_MINUTES,
  DEFAULT_USAGE_LIGHT_REFRESH_INTERVAL_SECONDS,
  DEFAULT_USAGE_VISIBLE_AGGREGATE_INTERVAL_MINUTES,
} from "../../settings/usageRefreshCadence";

export const fallbackAppSettings: AppSettingsSnapshot = {
  codexHome: null,
  customAccountDisplayName: "",
  quotaRefreshIntervalMs: DEFAULT_QUOTA_REFRESH_INTERVAL_MS,
  usageLightRefreshIntervalSeconds: DEFAULT_USAGE_LIGHT_REFRESH_INTERVAL_SECONDS,
  usageVisibleAggregateIntervalMinutes: DEFAULT_USAGE_VISIBLE_AGGREGATE_INTERVAL_MINUTES,
  usageBackgroundAggregateIntervalMinutes: DEFAULT_USAGE_BACKGROUND_AGGREGATE_INTERVAL_MINUTES,
  floatingWindow: {
    opacity: 0.92,
    scale: 1,
    tokenRateFullScale: 200,
    unreadEffect: "ripple",
    gradientStart: "#ffffff",
    gradientEnd: "#daefff",
    gradientDirection: "135deg",
    gradientType: "linear",
    quotaColorMode: "adaptive",
    quotaFixedColor: "#1469cc",
    textTone: -1,
    pagingGuideRevision: 0,
    contentVisibility: DEFAULT_FLOATING_CONTENT_VISIBILITY,
  },
  floatingPosition: null,
  displaySurfaces: {
    floatingWindowEnabled: true,
    liveRateEnabled: true,
    statusTrayLiveTextEnabled: true,
    statusMetricOrder: ["rate", "fiveHour", "sevenDay", "iq"],
    statusMetricLabelStyle: "compact",
    statusSummaryOrder: ["overview", "usage", "quota", "running", "unread", "radar", "crowdRadar"],
  },
  setupGuideCompleted: false,
  sessionEnhancements: DEFAULT_SESSION_ENHANCEMENTS,
  autoResume: DEFAULT_AUTO_RESUME_SETTINGS,
};
