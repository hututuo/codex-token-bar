import { useEffect, useRef, useState } from "react";
import { readCodexRadarState, subscribeCodexRadarState } from "../api/codexRadarClient";
import type { CodexRadarSnapshot } from "../domain/codexRadar/model";
import {
  nextCodexCrowdRadarRecoveryDelayMs,
  readCodexCrowdRadarSnapshot,
  type CodexCrowdRadarSnapshot,
} from "../api/codexCrowdRadarClient";

const FLOATING_RADAR_REFRESH_INTERVAL_MS = 600_000;

type RadarReader = typeof readCodexRadarState;
type RadarSubscriber = typeof subscribeCodexRadarState;
type CrowdRadarReader = typeof readCodexCrowdRadarSnapshot;

interface FloatingCrowdRadarOptions {
  clearOnError?: boolean;
  readCrowdRadar?: CrowdRadarReader;
}

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

export function useFloatingCrowdRadar(
  active: boolean,
  {
    clearOnError = false,
    readCrowdRadar = readCodexCrowdRadarSnapshot,
  }: FloatingCrowdRadarOptions = {},
): CodexCrowdRadarSnapshot | null {
  const [snapshot, setSnapshot] = useState<CodexCrowdRadarSnapshot | null>(null);
  const snapshotRef = useRef<CodexCrowdRadarSnapshot | null>(null);
  useEffect(() => {
    if (!active) return;
    let cancelled = false;
    let refreshing = false;
    let recoveryAttempt = 0;
    let recoveryTimer: number | null = null;
    const scheduleRecovery = () => {
      if (cancelled || snapshotRef.current || recoveryTimer !== null) return;
      const delay = nextCodexCrowdRadarRecoveryDelayMs(recoveryAttempt);
      if (delay === null) return;
      recoveryAttempt += 1;
      recoveryTimer = window.setTimeout(() => {
        recoveryTimer = null;
        refresh();
      }, delay);
    };
    const refresh = () => {
      if (cancelled || refreshing) return;
      refreshing = true;
      void readCrowdRadar()
        .then((next) => {
          if (cancelled) return;
          snapshotRef.current = next;
          recoveryAttempt = 0;
          if (recoveryTimer !== null) {
            window.clearTimeout(recoveryTimer);
            recoveryTimer = null;
          }
          setSnapshot(next);
        })
        .catch(() => {
          if (cancelled) return;
          if (clearOnError) {
            snapshotRef.current = null;
            setSnapshot(null);
          }
          scheduleRecovery();
        })
        .finally(() => { refreshing = false; });
    };
    refresh();
    const timer = window.setInterval(() => {
      if (!snapshotRef.current) recoveryAttempt = 0;
      refresh();
    }, FLOATING_RADAR_REFRESH_INTERVAL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
      if (recoveryTimer !== null) window.clearTimeout(recoveryTimer);
    };
  }, [active, clearOnError, readCrowdRadar]);
  return snapshot;
}
