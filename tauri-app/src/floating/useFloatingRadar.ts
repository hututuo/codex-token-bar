import { useEffect, useRef, useState } from "react";
import { readCodexRadarState } from "../api/codexRadarClient";
import type { CodexRadarSnapshot } from "../components/codexRadar/model";

const FLOATING_RADAR_REFRESH_INTERVAL_MS = 600_000;

type RadarReader = typeof readCodexRadarState;

export function useFloatingRadar(
  active: boolean,
  readRadar: RadarReader = readCodexRadarState,
): CodexRadarSnapshot | null {
  const [snapshot, setSnapshot] = useState<CodexRadarSnapshot | null>(null);
  const snapshotRef = useRef<CodexRadarSnapshot | null>(null);

  useEffect(() => {
    if (!active) {
      return;
    }
    let cancelled = false;
    const refresh = async () => {
      const next = await readRadar(snapshotRef.current);
      if (cancelled) {
        return;
      }
      snapshotRef.current = next.snapshot;
      setSnapshot(next.snapshot);
    };

    void refresh();
    const timer = window.setInterval(() => {
      void refresh();
    }, FLOATING_RADAR_REFRESH_INTERVAL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [active, readRadar]);

  return snapshot;
}
