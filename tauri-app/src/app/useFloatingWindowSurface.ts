import { useCallback, useEffect, useState } from "react";
import { desktopPlatform } from "../platform/desktop";

interface FloatingWindowSurfaceOptions {
  available: boolean;
  enabled: boolean;
  ready: boolean;
  onPreferenceConfirmed: (enabled: boolean) => void;
}

export interface FloatingWindowSurfaceState {
  floatingVisible: boolean;
  toggleFloatingWindow: () => Promise<void>;
}

export function useFloatingWindowSurface({
  available,
  enabled,
  onPreferenceConfirmed,
  ready,
}: FloatingWindowSurfaceOptions): FloatingWindowSurfaceState {
  const [floatingVisible, setFloatingVisible] = useState(false);

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
    if (!ready) {
      return;
    }

    let cancelled = false;
    const shouldShowFloating = enabled && available;

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
  }, [available, enabled, ready]);

  const toggleFloatingWindow = useCallback(async () => {
    const nextEnabled = !enabled;
    if (!available) {
      setFloatingVisible(false);
      onPreferenceConfirmed(false);
      return;
    }

    onPreferenceConfirmed(nextEnabled);
    setFloatingVisible(nextEnabled);
    const confirmed = nextEnabled
      ? await desktopPlatform.showFloatingWindow()
      : await desktopPlatform.hideFloatingWindow();
    setFloatingVisible(confirmed);
  }, [available, enabled, onPreferenceConfirmed]);

  return {
    floatingVisible,
    toggleFloatingWindow,
  };
}
