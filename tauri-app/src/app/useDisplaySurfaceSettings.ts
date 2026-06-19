import { useCallback, useEffect, useRef, useState } from "react";
import { saveDisplaySurfaces } from "../api/client";
import { desktopPlatform } from "../platform/desktop";
import {
  canUseFloatingWindow,
  canUseStatusTrayLiveText,
  INACTIVE_DISPLAY_SURFACES,
  sanitizeDisplaySurfaces,
} from "../settings/displaySettings";
import { useStatusTray } from "../tray/useStatusTray";
import type {
  DisplaySurfaceSettings,
  PlatformCapabilities,
} from "../types/dashboard";

interface DisplaySurfaceSettingsOptions {
  platform: PlatformCapabilities | null;
}

export interface DisplaySurfaceSettingsState {
  displaySurfaces: DisplaySurfaceSettings;
  floatingVisible: boolean;
  applyDisplaySurfaces: (settings: Partial<DisplaySurfaceSettings>) => void;
  toggleFloatingWindow: () => Promise<void>;
  toggleStatusTrayLiveText: () => void;
}

export function useDisplaySurfaceSettings({
  platform,
}: DisplaySurfaceSettingsOptions): DisplaySurfaceSettingsState {
  const [floatingVisible, setFloatingVisible] = useState(false);
  const [displaySurfaces, setDisplaySurfaces] = useState(INACTIVE_DISPLAY_SURFACES);
  const displaySettingsLoaded = useRef(false);
  const floatingAvailable = canUseFloatingWindow(platform);
  const statusTrayLiveTextAvailable = canUseStatusTrayLiveText(platform);

  useStatusTray(
    platform,
    displaySurfaces.statusTrayLiveTextEnabled && statusTrayLiveTextAvailable,
  );

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;

    void desktopPlatform.onFloatingWindowHidden(() => {
      setFloatingVisible(false);
    }).then((listener) => {
      if (disposed) {
        listener();
      } else {
        unlisten = listener;
      }
    });

    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  useEffect(() => {
    if (!displaySettingsLoaded.current) {
      return;
    }

    let cancelled = false;
    const shouldShowFloating = displaySurfaces.floatingWindowEnabled && floatingAvailable;

    async function applyFloatingPreference() {
      const confirmed = shouldShowFloating
        ? await desktopPlatform.showFloatingWindow()
        : await desktopPlatform.hideFloatingWindow();
      if (!cancelled) {
        setFloatingVisible(shouldShowFloating && confirmed);
      }
    }

    void applyFloatingPreference();

    return () => {
      cancelled = true;
    };
  }, [displaySurfaces.floatingWindowEnabled, floatingAvailable]);

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

  const toggleFloatingWindow = useCallback(async () => {
    const nextVisible = !floatingVisible;
    if (!floatingAvailable) {
      setFloatingVisible(false);
      return;
    }
    setFloatingVisible(nextVisible);
    const confirmed = nextVisible
      ? await desktopPlatform.showFloatingWindow()
      : await desktopPlatform.hideFloatingWindow();
    setFloatingVisible(confirmed);
    updateDisplaySurfaces({ floatingWindowEnabled: confirmed });
  }, [floatingAvailable, floatingVisible, updateDisplaySurfaces]);

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
