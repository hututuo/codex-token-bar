import { useEffect, useMemo, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { desktopPlatform } from "../platform/desktop";
import { statusPanelIsActive } from "../surfaces/surfaceLifecycle";

export interface StatusPanelWindowLifecycleDependencies {
  dismissOnBlur(): Promise<boolean>;
  isVisible(): Promise<boolean>;
}

export interface StatusPanelWindowLifecycleState {
  active: boolean;
  visible: boolean;
}

function defaultDependencies(): StatusPanelWindowLifecycleDependencies {
  const appWindow = getCurrentWindow();
  return {
    dismissOnBlur: desktopPlatform.dismissStatusPanelOnBlur,
    isVisible: () => appWindow.isVisible(),
  };
}

export function useStatusPanelWindowLifecycle(
  backgroundActive = false,
  dependencies?: StatusPanelWindowLifecycleDependencies,
): boolean {
  return useStatusPanelWindowLifecycleState(backgroundActive, dependencies).active;
}

export function useStatusPanelWindowLifecycleState(
  backgroundActive = false,
  dependencies?: StatusPanelWindowLifecycleDependencies,
): StatusPanelWindowLifecycleState {
  const [active, setActive] = useState(false);
  const lifecycle = useMemo(() => dependencies ?? defaultDependencies(), [dependencies]);

  useEffect(() => {
    let cancelled = false;

    async function refreshActiveState() {
      try {
        const visible = await lifecycle.isVisible();
        if (!cancelled) {
          setActive(statusPanelIsActive(Boolean(visible)));
        }
      } catch {
        if (!cancelled) {
          setActive(statusPanelIsActive(true));
        }
      }
    }

    const dismissWhenBlurred = () => {
      void lifecycle.dismissOnBlur().finally(() => {
        void refreshActiveState();
      });
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
    const visibilityTimer = window.setInterval(() => {
      void refreshActiveState();
    }, 1_000);
    return () => {
      cancelled = true;
      window.clearInterval(visibilityTimer);
      window.removeEventListener("focus", markActive);
      window.removeEventListener("blur", dismissWhenBlurred);
      window.removeEventListener("keydown", dismissForEscape);
    };
  }, [lifecycle]);

  return {
    active: backgroundActive || active,
    visible: active,
  };
}
