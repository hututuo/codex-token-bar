import { useEffect, useRef, useState } from "react";
import { readCodexRadarState, subscribeCodexRadarState } from "../api/codexRadarClient";
import type { CodexRadarSnapshot } from "../domain/codexRadar/model";
import {
  nextCodexCrowdRadarRecoveryDelayMs,
  readCodexCrowdRadarSnapshot,
  type CodexCrowdRadarSnapshot,
} from "../api/codexCrowdRadarClient";

const FLOATING_RADAR_REFRESH_INTERVAL_MS = 300_000;

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
    let refreshing = false;
    let recoveryAttempt = 0;
    let recoveryTimer: number | null = null;
    const refresh = async () => {
      if (cancelled || refreshing) return;
      refreshing = true;
      if (recoveryTimer !== null) { window.clearTimeout(recoveryTimer); recoveryTimer = null; }
      let failed = false;
      try {
        const next = await readRadar(snapshotRef.current, { force: true });
        if (cancelled) return;
        snapshotRef.current = next.snapshot;
        setSnapshot(next.snapshot);
        failed = !next.snapshot || next.snapshot.staleDataDisplayed;
      } catch { failed = true; }
      finally { refreshing = false; }
      if (!failed) recoveryAttempt = 0;
      else if (!cancelled && recoveryAttempt < 3) {
        recoveryTimer = window.setTimeout(() => { recoveryTimer = null; void refresh(); }, 30_000 * 2 ** recoveryAttempt++);
      }
    };
    const online = () => { recoveryAttempt = 0; void refresh(); };
    window.addEventListener("online", online);

    void refresh();
    const timer = window.setInterval(() => {
      void refresh();
    }, FLOATING_RADAR_REFRESH_INTERVAL_MS);
    return () => {
      cancelled = true;
      unsubscribe();
      window.removeEventListener("online", online);
      if (recoveryTimer !== null) window.clearTimeout(recoveryTimer);
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
      if (cancelled || recoveryTimer !== null) return;
      const delay = nextCodexCrowdRadarRecoveryDelayMs(recoveryAttempt);
      if (delay === null) return;
      recoveryAttempt += 1;
      recoveryTimer = window.setTimeout(() => {
        recoveryTimer = null;
        refresh();
      }, delay);
    };
    const refresh = (force = false) => {
      if (cancelled || refreshing) return;
      refreshing = true;
      void readCrowdRadar({ force })
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
    const online = () => { recoveryAttempt = 0; refresh(true); };
    window.addEventListener("online", online);
    refresh();
    const timer = window.setInterval(() => {
      if (!snapshotRef.current) recoveryAttempt = 0;
      refresh();
    }, FLOATING_RADAR_REFRESH_INTERVAL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
      if (recoveryTimer !== null) window.clearTimeout(recoveryTimer);
      window.removeEventListener("online", online);
    };
  }, [active, clearOnError, readCrowdRadar]);
  return snapshot;
}
