import { useCallback, useEffect, useRef, useState } from "react";
import { saveDisplaySurfaces } from "../api/client";
import { desktopPlatform } from "../platform/desktop";
import {
  canUseFloatingWindow,
  canUseStatusTrayLiveText,
  INACTIVE_DISPLAY_SURFACES,
  sanitizeDisplaySurfaces,
} from "../settings/displaySettings";
import {
  createTrailingSettingsPersistence,
  type TrailingSettingsPersistence,
} from "../settings/trailingSettingsPersistence";
import type {
  DisplaySurfaceSettings,
  PlatformCapabilities,
} from "../types/dashboard";
import { useFloatingWindowSurface } from "./useFloatingWindowSurface";

interface DisplaySurfaceSettingsOptions {
  onPersistenceError?: (error: unknown | null) => void;
  platform: PlatformCapabilities | null;
}

export interface DisplaySurfaceSettingsState {
  displaySurfaces: DisplaySurfaceSettings;
  floatingVisible: boolean;
  applyDisplaySurfaces: (settings: Partial<DisplaySurfaceSettings>) => void;
  toggleLiveRate: () => void;
  toggleFloatingWindow: () => Promise<void>;
  toggleStatusTrayLiveText: () => void;
}

export function useDisplaySurfaceSettings({
  onPersistenceError,
  platform,
}: DisplaySurfaceSettingsOptions): DisplaySurfaceSettingsState {
  const [displaySurfaces, setDisplaySurfaces] = useState(INACTIVE_DISPLAY_SURFACES);
  const displaySettingsLoaded = useRef(false);
  const displaySettingsEdits = useRef(0);
  const displaySurfacesRef = useRef(INACTIVE_DISPLAY_SURFACES);
  const onPersistenceErrorRef = useRef(onPersistenceError);
  onPersistenceErrorRef.current = onPersistenceError;
  const persistenceRef = useRef<TrailingSettingsPersistence<DisplaySurfaceSettings> | null>(null);
  if (persistenceRef.current === null) {
    persistenceRef.current = createTrailingSettingsPersistence(
      saveDisplaySurfaces,
      {
        equals: sameDisplaySurfaces,
        persistedValue: (_requested, result) => sanitizeDisplaySurfaces(result.displaySurfaces),
        onLatestPersisted: (_value, result) => {
          onPersistenceErrorRef.current?.(null);
          if (result !== null) {
            void desktopPlatform.publishDisplaySurfaces(
              sanitizeDisplaySurfaces(result.displaySurfaces),
            );
          }
        },
        onLatestError: (error) => {
          onPersistenceErrorRef.current?.(error);
        },
      },
    );
  }
  const floatingAvailable = canUseFloatingWindow(platform);
  const statusTrayLiveTextAvailable = canUseStatusTrayLiveText(platform);

  const updateDisplaySurfaces = useCallback((next: Partial<DisplaySurfaceSettings>) => {
    const sanitized = sanitizeDisplaySurfaces({ ...displaySurfacesRef.current, ...next });
    if (sameDisplaySurfaces(sanitized, displaySurfacesRef.current)) {
      return;
    }
    displaySettingsEdits.current += 1;
    displaySurfacesRef.current = sanitized;
    setDisplaySurfaces(sanitized);
    void desktopPlatform.publishDisplaySurfaces(sanitized);
    if (displaySettingsLoaded.current) {
      persistenceRef.current?.schedule(sanitized);
    }
  }, []);

  const applyDisplaySurfaces = useCallback((settings: Partial<DisplaySurfaceSettings>) => {
    const persisted = sanitizeDisplaySurfaces(settings);
    persistenceRef.current?.setPersisted(persisted);
    displaySettingsLoaded.current = true;
    if (displaySettingsEdits.current === 0) {
      displaySurfacesRef.current = persisted;
      setDisplaySurfaces(persisted);
      void desktopPlatform.publishDisplaySurfaces(persisted);
      return;
    }

    const edited = sanitizeDisplaySurfaces(displaySurfacesRef.current);
    displaySurfacesRef.current = edited;
    setDisplaySurfaces(edited);
    persistenceRef.current?.schedule(edited);
  }, []);

  useEffect(() => {
    const flush = () => {
      void persistenceRef.current?.flush();
    };
    window.addEventListener("pagehide", flush);
    return () => {
      window.removeEventListener("pagehide", flush);
      flush();
    };
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

  const toggleLiveRate = useCallback(() => {
    updateDisplaySurfaces({
      liveRateEnabled: !displaySurfaces.liveRateEnabled,
    });
  }, [displaySurfaces.liveRateEnabled, updateDisplaySurfaces]);

  return {
    displaySurfaces,
    floatingVisible,
    applyDisplaySurfaces,
    toggleLiveRate,
    toggleFloatingWindow,
    toggleStatusTrayLiveText,
  };
}

function sameDisplaySurfaces(
  left: DisplaySurfaceSettings,
  right: DisplaySurfaceSettings,
): boolean {
  return (
    left.floatingWindowEnabled === right.floatingWindowEnabled
    && left.liveRateEnabled === right.liveRateEnabled
    && left.statusTrayLiveTextEnabled === right.statusTrayLiveTextEnabled
  );
}
