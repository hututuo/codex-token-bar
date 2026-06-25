import { useCallback, useRef, useState } from "react";
import { saveDisplaySurfaces } from "../api/client";
import {
  canUseFloatingWindow,
  canUseStatusTrayLiveText,
  INACTIVE_DISPLAY_SURFACES,
  sanitizeDisplaySurfaces,
} from "../settings/displaySettings";
import { useStatusTray } from "../tray/useStatusTray";
import type {
  DisplaySurfaceSettings,
  LiveRateSnapshot,
  PlatformCapabilities,
} from "../types/dashboard";
import { useFloatingWindowSurface } from "./useFloatingWindowSurface";

interface DisplaySurfaceSettingsOptions {
  platform: PlatformCapabilities | null;
  liveRate: LiveRateSnapshot;
}

export interface DisplaySurfaceSettingsState {
  displaySurfaces: DisplaySurfaceSettings;
  floatingVisible: boolean;
  applyDisplaySurfaces: (settings: Partial<DisplaySurfaceSettings>) => void;
  toggleFloatingWindow: () => Promise<void>;
  toggleStatusTrayLiveText: () => void;
}

export function useDisplaySurfaceSettings({
  liveRate,
  platform,
}: DisplaySurfaceSettingsOptions): DisplaySurfaceSettingsState {
  const [displaySurfaces, setDisplaySurfaces] = useState(INACTIVE_DISPLAY_SURFACES);
  const displaySettingsLoaded = useRef(false);
  const floatingAvailable = canUseFloatingWindow(platform);
  const statusTrayLiveTextAvailable = canUseStatusTrayLiveText(platform);

  useStatusTray(
    platform,
    displaySurfaces.statusTrayLiveTextEnabled && statusTrayLiveTextAvailable,
    liveRate,
  );

  const updateDisplaySurfaces = useCallback((next: Partial<DisplaySurfaceSettings>) => {
    setDisplaySurfaces((current) => {
      const sanitized = sanitizeDisplaySurfaces({ ...current, ...next });
      if (displaySettingsLoaded.current) {
        void saveDisplaySurfaces(sanitized).catch(() => {});
      }
      return sanitized;
    });
  }, []);

  const applyDisplaySurfaces = useCallback((settings: Partial<DisplaySurfaceSettings>) => {
    displaySettingsLoaded.current = true;
    setDisplaySurfaces(sanitizeDisplaySurfaces(settings));
  }, []);

  const confirmFloatingPreference = useCallback((enabled: boolean) => {
    updateDisplaySurfaces({ floatingWindowEnabled: enabled });
  }, [updateDisplaySurfaces]);

  const { floatingVisible, toggleFloatingWindow } = useFloatingWindowSurface({
    available: floatingAvailable,
    enabled: displaySurfaces.floatingWindowEnabled,
    onPreferenceConfirmed: confirmFloatingPreference,
    ready: displaySettingsLoaded.current,
  });

  const toggleStatusTrayLiveText = useCallback(() => {
    if (!statusTrayLiveTextAvailable) {
      return;
    }
    updateDisplaySurfaces({
      statusTrayLiveTextEnabled: !displaySurfaces.statusTrayLiveTextEnabled,
    });
  }, [
    displaySurfaces.statusTrayLiveTextEnabled,
    statusTrayLiveTextAvailable,
    updateDisplaySurfaces,
  ]);

  return {
    displaySurfaces,
    floatingVisible,
    applyDisplaySurfaces,
    toggleFloatingWindow,
    toggleStatusTrayLiveText,
  };
}
