import { useEffect, useRef } from "react";
import type { DashboardDataSource } from "../data/dashboardDataSource";
import type { LiveThreadOption } from "../types/dashboard";

interface LiveThreadOptionsLoadOptions {
  active: boolean;
  dashboardReady: boolean;
  loading: boolean;
  generation: number;
  source: Pick<DashboardDataSource, "readLiveThreadOptions">;
  onLiveThreadOptions: (options: LiveThreadOption[]) => void;
}

export function useLiveThreadOptionsLoad({
  active,
  dashboardReady,
  loading,
  generation,
  source,
  onLiveThreadOptions,
}: LiveThreadOptionsLoadOptions) {
  const liveThreadOptionsGeneration = useRef<number | null>(null);

  useEffect(() => {
    if (
      !active ||
      !dashboardReady ||
      loading ||
      liveThreadOptionsGeneration.current === generation
    ) {
      return;
    }

    let cancelled = false;
    liveThreadOptionsGeneration.current = generation;

    async function loadThreadOptions() {
      const liveThreadOptions = await source.readLiveThreadOptions();
      if (!cancelled) {
        onLiveThreadOptions(liveThreadOptions);
      }
    }

    void loadThreadOptions();

    return () => {
      cancelled = true;
    };
  }, [active, dashboardReady, generation, loading, onLiveThreadOptions, source]);
}
