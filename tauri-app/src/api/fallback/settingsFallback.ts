import type { AppSettingsSnapshot } from "../../types/settings";
import { DEFAULT_FLOATING_CONTENT_VISIBILITY } from "../../floating/floatingContent";

export const fallbackAppSettings: AppSettingsSnapshot = {
  codexHome: null,
  customAccountDisplayName: "",
  floatingWindow: {
    opacity: 0.92,
    scale: 1,
    tokenRateFullScale: 200,
    unreadEffect: "ripple",
    gradientStart: "#ffffff",
    gradientEnd: "#daefff",
    gradientDirection: "135deg",
    gradientType: "linear",
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
};
