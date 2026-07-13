import { useEffect, useRef, useState } from "react";
import { readCodexRadarState, subscribeCodexRadarState } from "../api/codexRadarClient";
import type { CodexRadarSnapshot } from "../domain/codexRadar/model";

const FLOATING_RADAR_REFRESH_INTERVAL_MS = 600_000;

type RadarReader = typeof readCodexRadarState;
type RadarSubscriber = typeof subscribeCodexRadarState;

export function useFloatingRadar(
  active: boolean,
  readRadar: RadarReader = readCodexRadarState,
  subscribeRadar: RadarSubscriber = subscribeCodexRadarState,
): CodexRadarSnapshot | null {
  const [snapshot, setSnapshot] = useState<CodexRadarSnapshot | null>(null);
  const snapshotRef = useRef<CodexRadarSnapshot | null>(null);

  useEffect(() => {
    if (!active) {
      return;
    }
    let cancelled = false;
    const unsubscribe = subscribeRadar((next) => {
      if (cancelled) {
        return;
      }
      snapshotRef.current = next.snapshot;
      setSnapshot(next.snapshot);
    });
    const refresh = async () => {
      const next = await readRadar(snapshotRef.current, { force: true });
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
      unsubscribe();
      window.clearInterval(timer);
    };
  }, [active, readRadar, subscribeRadar]);

  return snapshot;
}
