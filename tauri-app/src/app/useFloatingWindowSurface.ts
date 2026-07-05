import { useCallback, useEffect, useRef, useState } from "react";
import { desktopPlatform } from "../platform/desktop";
import {
  floatingCommandPreferenceConfirmation,
  floatingCommandVisibleState,
  shouldConfirmFloatingHiddenEvent,
} from "./floatingWindowSurfaceModel";

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
  const floatingVisibleRef = useRef(false);

  settingsReadyRef.current = ready;
  enabledPreferenceRef.current = enabled;

  function updateFloatingVisible(nextVisible: boolean) {
    floatingVisibleRef.current = nextVisible;
    setFloatingVisible(nextVisible);
  }

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;

    void desktopPlatform.onFloatingWindowHidden(() => {
      if (!shouldConfirmFloatingHiddenEvent(settingsReadyRef.current, enabledPreferenceRef.current)) {
        return;
      }
      updateFloatingVisible(false);
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
      const result = shouldShowFloating
        ? await desktopPlatform.showFloatingWindowCommand()
        : await desktopPlatform.hideFloatingWindowCommand();
      if (!cancelled) {
        updateFloatingVisible(floatingCommandVisibleState(result, floatingVisibleRef.current));
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
      updateFloatingVisible(false);
      onPreferenceConfirmed(false);
      return;
    }

    const result = nextEnabled
      ? await desktopPlatform.showFloatingWindowCommand()
      : await desktopPlatform.hideFloatingWindowCommand();
    const confirmedPreference = floatingCommandPreferenceConfirmation(result);
    if (confirmedPreference !== null) {
      onPreferenceConfirmed(confirmedPreference);
    }
    updateFloatingVisible(floatingCommandVisibleState(result, floatingVisibleRef.current));
  }, [available, enabled, onPreferenceConfirmed]);

  return {
    floatingVisible,
    toggleFloatingWindow,
  };
}
