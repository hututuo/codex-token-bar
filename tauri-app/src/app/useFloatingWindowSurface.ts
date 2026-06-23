import { useCallback, useEffect, useRef, useState } from "react";
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
  const settingsReadyRef = useRef(false);
  const enabledPreferenceRef = useRef(false);

  settingsReadyRef.current = ready;
  enabledPreferenceRef.current = enabled;

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;

    void desktopPlatform.onFloatingWindowHidden(() => {
      if (!settingsReadyRef.current || !enabledPreferenceRef.current) {
        return;
      }
      setFloatingVisible(false);
      onPreferenceConfirmed(false);
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
  }, [onPreferenceConfirmed]);

  useEffect(() => {
    if (!ready) {
      return;
    }

    let cancelled = false;
    const shouldShowFloating = enabled && available;

    async function applyFloatingPreference() {
      const nextVisible = shouldShowFloating
        ? await desktopPlatform.showFloatingWindow()
        : await desktopPlatform.hideFloatingWindow();
      if (!cancelled) {
        setFloatingVisible(nextVisible);
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

    const nextVisible = nextEnabled
      ? await desktopPlatform.showFloatingWindow()
      : await desktopPlatform.hideFloatingWindow();
    onPreferenceConfirmed(nextVisible);
    setFloatingVisible(nextVisible);
  }, [available, enabled, onPreferenceConfirmed]);

  return {
    floatingVisible,
    toggleFloatingWindow,
  };
}
