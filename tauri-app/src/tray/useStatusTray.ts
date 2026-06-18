import { useEffect, useMemo, useRef } from "react";
import { desktopPlatform } from "../platform/desktop";
import { useCompactPanelData } from "../surfaces/useCompactPanelData";
import type { FloatingPanelSnapshot, PlatformCapabilities } from "../types/dashboard";

export function useStatusTray(
  platform: PlatformCapabilities | null,
  liveTextEnabled: boolean,
) {
  const lastReadout = useRef<{ title: string; tooltip: string } | null>(null);
  const liveTextAvailable =
    liveTextEnabled &&
    platform !== null &&
    platform.statusTray.available &&
    platform.statusTrayLiveText.available;
  const { snapshot } = useCompactPanelData({
    active: liveTextAvailable,
    snapshotIntervalMs: 1_000,
    quotaEnabled: false,
  });
  const readout = useMemo(
    () =>
      liveTextAvailable
        ? {
            title: formatTrayTitle(snapshot),
            tooltip: `Codex Token Bar · ${snapshot.tokensPerSecond.toFixed(1)} tok/s`,
          }
        : {
            title: "CTB",
            tooltip: "Codex Token Bar",
          },
    [liveTextAvailable, snapshot],
  );

  useEffect(() => {
    if (platform !== null && !platform.statusTray.available) {
      return;
    }

    if (
      lastReadout.current !== null &&
      lastReadout.current.title === readout.title &&
      lastReadout.current.tooltip === readout.tooltip
    ) {
      return;
    }

    lastReadout.current = readout;
    void desktopPlatform.setStatusTrayReadout(readout.title, readout.tooltip);
  }, [platform, readout]);
}

function formatTrayTitle(snapshot: FloatingPanelSnapshot): string {
  if (snapshot.tokensPerSecond >= 100) {
    return `${Math.round(snapshot.tokensPerSecond)}/s`;
  }

  return `${snapshot.tokensPerSecond.toFixed(1)}/s`;
}
