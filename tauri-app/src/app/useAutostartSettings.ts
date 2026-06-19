import { useEffect, useState } from "react";
import {
  readAutostartStatus,
  recordStartupEvent,
  setAutostartEnabled,
} from "../api/client";
import { fallbackAutostartStatus } from "../api/fallback";
import type { AutostartStatus } from "../types/dashboard";

interface AutostartSettingsOptions {
  dashboardHydrated: boolean;
}

export interface AutostartSettingsState {
  autostartStatus: AutostartStatus;
  toggleAutostart: () => void;
}

export function useAutostartSettings({
  dashboardHydrated,
}: AutostartSettingsOptions): AutostartSettingsState {
  const [autostartStatus, setAutostartStatus] = useState<AutostartStatus>(fallbackAutostartStatus);
  const [autostartUpdating, setAutostartUpdating] = useState(false);

  useEffect(() => {
    if (!dashboardHydrated) {
      return;
    }

    let cancelled = false;
    const timeoutId = window.setTimeout(() => {
      void recordStartupEvent("autostart lazy read requested");
      void readAutostartStatus().then((status) => {
        if (!cancelled) {
          setAutostartStatus(status);
        }
      });
    }, 800);

    return () => {
      cancelled = true;
      window.clearTimeout(timeoutId);
    };
  }, [dashboardHydrated]);

  async function toggleAutostart() {
    if (autostartUpdating || !autostartStatus.available) {
      return;
    }

    setAutostartUpdating(true);
    try {
      const next = await setAutostartEnabled(!autostartStatus.enabled);
      setAutostartStatus(next);
    } catch {
      const refreshed = await readAutostartStatus();
      setAutostartStatus(refreshed);
    } finally {
      setAutostartUpdating(false);
    }
  }

  return {
    autostartStatus,
    toggleAutostart,
  };
}
