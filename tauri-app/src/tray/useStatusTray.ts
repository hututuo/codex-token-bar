import { useEffect, useState } from "react";
import { desktopPlatform } from "../platform/desktop";
import type { LiveRateSnapshot, PlatformCapabilities } from "../types/dashboard";

export function useStatusTray(
  snapshot: LiveRateSnapshot | null,
  platform: PlatformCapabilities | null,
  liveTextEnabled: boolean,
) {
  const [lastTitle, setLastTitle] = useState<string | null>(null);

  useEffect(() => {
    if (platform !== null && !platform.statusTray.available) {
      return;
    }

    const title =
      liveTextEnabled && snapshot !== null && platform?.statusTrayLiveText.available !== false
        ? formatTrayTitle(snapshot)
        : "CTB";
    if (title === lastTitle) {
      return;
    }

    setLastTitle(title);
    void desktopPlatform.setStatusTrayReadout(
      title,
      liveTextEnabled && snapshot !== null
        ? `Codex Token Bar · ${snapshot.tokensPerSecond.toFixed(1)} tok/s`
        : "Codex Token Bar",
    );
  }, [lastTitle, liveTextEnabled, platform, snapshot]);
}

function formatTrayTitle(snapshot: LiveRateSnapshot): string {
  if (snapshot.tokensPerSecond >= 100) {
    return `${Math.round(snapshot.tokensPerSecond)}/s`;
  }

  return `${snapshot.tokensPerSecond.toFixed(1)}/s`;
}
