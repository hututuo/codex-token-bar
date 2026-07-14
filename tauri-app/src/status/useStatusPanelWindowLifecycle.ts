import { useEffect, useMemo, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { desktopPlatform } from "../platform/desktop";
import { statusPanelIsActive } from "../surfaces/surfaceLifecycle";

export interface StatusPanelWindowLifecycleDependencies {
  dismissOnBlur(): Promise<boolean>;
  hasFocus(): boolean;
  isVisible(): Promise<boolean>;
}

function defaultDependencies(): StatusPanelWindowLifecycleDependencies {
  const appWindow = getCurrentWindow();
  return {
    dismissOnBlur: desktopPlatform.dismissStatusPanelOnBlur,
    hasFocus: () => document.hasFocus(),
    isVisible: () => appWindow.isVisible(),
  };
}

export function useStatusPanelWindowLifecycle(
  dependencies?: StatusPanelWindowLifecycleDependencies,
): boolean {
  const [active, setActive] = useState(false);
  const lifecycle = useMemo(() => dependencies ?? defaultDependencies(), [dependencies]);

  useEffect(() => {
    let cancelled = false;

    async function refreshActiveState() {
      try {
        const visible = await lifecycle.isVisible();
        if (!cancelled) {
          setActive(statusPanelIsActive(Boolean(visible), lifecycle.hasFocus()));
        }
      } catch {
        if (!cancelled) {
          setActive(statusPanelIsActive(true, lifecycle.hasFocus()));
        }
      }
    }

    const dismissWhenBlurred = () => {
      setActive(false);
      void lifecycle.dismissOnBlur();
    };
    const dismissForEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") {
        return;
      }
      event.preventDefault();
      dismissWhenBlurred();
    };
    const markActive = () => {
      void refreshActiveState();
    };
    window.addEventListener("focus", markActive);
    window.addEventListener("blur", dismissWhenBlurred);
    window.addEventListener("keydown", dismissForEscape);
    void refreshActiveState();
    return () => {
      cancelled = true;
      window.removeEventListener("focus", markActive);
      window.removeEventListener("blur", dismissWhenBlurred);
      window.removeEventListener("keydown", dismissForEscape);
    };
  }, [lifecycle]);

  return active;
}
