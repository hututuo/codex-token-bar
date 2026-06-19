import type { AppSettingsSnapshot } from "../../types/settings";

export const fallbackAppSettings: AppSettingsSnapshot = {
  codexHome: null,
  floatingWindow: {
    opacity: 0.92,
    scale: 1,
    unreadEffect: "ripple",
  },
  floatingPosition: null,
  displaySurfaces: {
    floatingWindowEnabled: true,
    statusTrayLiveTextEnabled: true,
  },
  setupGuideCompleted: false,
};
