import { useEffect, useMemo, useRef } from "react";
import { formatLiveRateValue } from "../components/liveRate/rateDisplay";
import { desktopPlatform } from "../platform/desktop";
import type { LiveRateSnapshot, PlatformCapabilities } from "../types/dashboard";

export function useStatusTray(
  platform: PlatformCapabilities | null,
  liveTextEnabled: boolean,
  liveRate: LiveRateSnapshot,
) {
  const lastReadout = useRef<{ title: string; tooltip: string } | null>(null);
  const liveTextAvailable =
    liveTextEnabled &&
    platform !== null &&
    platform.statusTray.available &&
    platform.statusTrayLiveText.available;
  const readout = useMemo(
    () =>
      liveTextAvailable
        ? {
            title: formatTrayTitle(liveRate),
            tooltip: `Codex Token Bar · ${formatLiveRateValue(liveRate.tokensPerSecond)} tok/s`,
          }
        : {
            title: "CTB",
            tooltip: "Codex Token Bar",
          },
    [liveTextAvailable, liveRate],
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

function formatTrayTitle(snapshot: Pick<LiveRateSnapshot, "tokensPerSecond">): string {
  return `${formatLiveRateValue(snapshot.tokensPerSecond)}/s`;
}
