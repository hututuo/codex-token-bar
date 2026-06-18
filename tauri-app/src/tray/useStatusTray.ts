import { useEffect, useState } from "react";
import { setStatusTrayReadout } from "../api/client";
import type { LiveRateSnapshot } from "../types/dashboard";

export function useStatusTray(snapshot: LiveRateSnapshot | null) {
  const [lastTitle, setLastTitle] = useState<string | null>(null);

  useEffect(() => {
    if (snapshot === null) {
      return;
    }

    const title = formatTrayTitle(snapshot);
    if (title === lastTitle) {
      return;
    }

    setLastTitle(title);
    void setStatusTrayReadout(title, `Codex Token Bar · ${snapshot.tokensPerSecond.toFixed(1)} tok/s`);
  }, [lastTitle, snapshot]);
}

function formatTrayTitle(snapshot: LiveRateSnapshot): string {
  if (snapshot.tokensPerSecond >= 100) {
    return `${Math.round(snapshot.tokensPerSecond)}/s`;
  }

  return `${snapshot.tokensPerSecond.toFixed(1)}/s`;
}
