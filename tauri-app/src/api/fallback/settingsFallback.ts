import type { AppSettingsSnapshot } from "../../types/settings";
import { DEFAULT_FLOATING_CONTENT_VISIBILITY } from "../../floating/floatingContent";
import { DEFAULT_QUOTA_REFRESH_INTERVAL_MS } from "../../settings/quotaRefreshCadence";
import { DEFAULT_AUTO_RESUME_SETTINGS } from "../../settings/autoResume";

export const fallbackAppSettings: AppSettingsSnapshot = {
  codexHome: null,
  customAccountDisplayName: "",
  quotaRefreshIntervalMs: DEFAULT_QUOTA_REFRESH_INTERVAL_MS,
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
    contentVisibility: DEFAULT_FLOATING_CONTENT_VISIBILITY,
  },
  floatingPosition: null,
  displaySurfaces: {
    floatingWindowEnabled: true,
    liveRateEnabled: true,
    statusTrayLiveTextEnabled: true,
  },
  setupGuideCompleted: false,
  autoResume: DEFAULT_AUTO_RESUME_SETTINGS,
};
