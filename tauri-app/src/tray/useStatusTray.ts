import { useEffect, useState } from "react";
import { desktopPlatform } from "../platform/desktop";
import type { LiveRateSnapshot, PlatformCapabilities } from "../types/dashboard";

export function useStatusTray(snapshot: LiveRateSnapshot | null, platform: PlatformCapabilities | null) {
  const [lastTitle, setLastTitle] = useState<string | null>(null);

  useEffect(() => {
    if (snapshot === null) {
      return;
    }
    if (platform !== null && !platform.statusTrayLiveText.available) {
      return;
    }

    const title = formatTrayTitle(snapshot);
    if (title === lastTitle) {
      return;
    }

    setLastTitle(title);
    void desktopPlatform.setStatusTrayReadout(
      title,
      `Codex Token Bar · ${snapshot.tokensPerSecond.toFixed(1)} tok/s`,
    );
  }, [lastTitle, platform, snapshot]);
}

function formatTrayTitle(snapshot: LiveRateSnapshot): string {
  if (snapshot.tokensPerSecond >= 100) {
    return `${Math.round(snapshot.tokensPerSecond)}/s`;
  }

  return `${snapshot.tokensPerSecond.toFixed(1)}/s`;
}
