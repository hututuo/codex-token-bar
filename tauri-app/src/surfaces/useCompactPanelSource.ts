import { useCallback, useEffect, useRef, useState } from "react";
import { getCodexHome } from "../api/dashboardClient";
import { desktopPlatform } from "../platform/desktop";
import type { EventSubscriptionResult } from "../platform/desktopBridge";
import {
  acceptDashboardSourceEnvelope,
  createDashboardSourceTransition,
  type DashboardSourceTransition,
} from "../state/dashboardSourceTransition";
import type {
  CodexHomeSourceEnvelope,
  CodexHomeSourceToken,
} from "../types/dashboard";

interface CompactPanelSourceDependencies {
  readCurrentSource: () => Promise<CodexHomeSourceEnvelope | null>;
  scheduleReconcile?: (
    refresh: () => Promise<void>,
    intervalMs: number,
  ) => () => void;
  subscribe: (
    handler: (envelope: CodexHomeSourceEnvelope) => void,
  ) => Promise<EventSubscriptionResult>;
}

export interface CompactPanelSourceState {
  sourceReady: boolean;
  sourceToken: CodexHomeSourceToken | null;
}

export const COMPACT_SOURCE_RECONCILE_INTERVAL_MS = 30_000;

const DEFAULT_SOURCE_DEPENDENCIES: CompactPanelSourceDependencies = {
  readCurrentSource: getCodexHome,
  subscribe: desktopPlatform.onCodexHomeSourceChanged,
};

export function useCompactPanelSource(
  active: boolean,
  dependencies: CompactPanelSourceDependencies = DEFAULT_SOURCE_DEPENDENCIES,
): CompactPanelSourceState {
  const transitionRef = useRef<DashboardSourceTransition>(createDashboardSourceTransition());
  const [sourceToken, setSourceToken] = useState<CodexHomeSourceToken | null>(null);
  const [activeSourceVerified, setActiveSourceVerified] = useState(false);
  const activeRef = useRef(active);
  const cancelActivationRetryRef = useRef<(() => void) | null>(null);
  activeRef.current = active;

  const acceptEnvelope = useCallback((envelope: CodexHomeSourceEnvelope) => {
    const result = acceptDashboardSourceEnvelope(transitionRef.current, envelope);
    if (!result.accepted) {
      return false;
    }
    transitionRef.current = result.transition;
    const acceptedToken = result.transition.sourceToken;
    setSourceToken((current) => sameCodexHomeSourceToken(current, acceptedToken)
      ? current
      : acceptedToken);
    return true;
  }, []);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;
    let cancelReconcile: (() => void) | null = null;

    async function refreshCurrentSource() {
      const startedWhileActive = activeRef.current;
      let envelope: CodexHomeSourceEnvelope | null;
      try {
        envelope = await dependencies.readCurrentSource();
      } catch {
        return;
      }
      if (disposed) {
        return;
      }
      if (envelope === null || !acceptEnvelope(envelope)) {
        return;
      }
      if (startedWhileActive && activeRef.current) {
        setActiveSourceVerified(true);
      }
    }

    void (async () => {
      const subscription = await dependencies.subscribe((envelope) => {
        if (!disposed && acceptEnvelope(envelope) && activeRef.current) {
          setActiveSourceVerified(true);
          cancelActivationRetryRef.current?.();
          cancelActivationRetryRef.current = null;
        }
      });
      if (disposed) {
        if (subscription.ok) {
          subscription.unlisten();
        }
        return;
      }
      if (subscription.ok) {
        unlisten = subscription.unlisten;
      } else {
        const schedule = dependencies.scheduleReconcile ?? scheduleSourceReconcile;
        cancelReconcile = schedule(
          refreshCurrentSource,
          COMPACT_SOURCE_RECONCILE_INTERVAL_MS,
        );
      }
    })();

    return () => {
      disposed = true;
      unlisten?.();
      cancelReconcile?.();
    };
  }, [acceptEnvelope, dependencies]);

  useEffect(() => {
    if (!active) {
      setActiveSourceVerified(false);
      return;
    }

    let cancelled = false;
    let cancelRetry: (() => void) | null = null;
    setActiveSourceVerified(false);
    async function verifyActiveSource() {
      try {
        const envelope = await dependencies.readCurrentSource();
        if (cancelled || !activeRef.current) {
          return;
        }
        if (envelope !== null && acceptEnvelope(envelope)) {
          setActiveSourceVerified(true);
          cancelRetry?.();
          cancelRetry = null;
          cancelActivationRetryRef.current = null;
          return;
        }
      } catch {
        if (cancelled || !activeRef.current) {
          return;
        }
      }
      if (cancelRetry === null) {
        const schedule = dependencies.scheduleReconcile ?? scheduleSourceReconcile;
        const cancelScheduled = schedule(
          verifyActiveSource,
          COMPACT_SOURCE_RECONCILE_INTERVAL_MS,
        );
        let retryCancelled = false;
        cancelRetry = () => {
          if (!retryCancelled) {
            retryCancelled = true;
            cancelScheduled();
          }
        };
        cancelActivationRetryRef.current = cancelRetry;
      }
    }
    void verifyActiveSource();
    return () => {
      cancelled = true;
      cancelRetry?.();
      if (cancelActivationRetryRef.current === cancelRetry) {
        cancelActivationRetryRef.current = null;
      }
    };
  }, [acceptEnvelope, active, dependencies]);

  return {
    sourceReady: sourceToken !== null && (!active || activeSourceVerified),
    sourceToken,
  };
}

function scheduleSourceReconcile(
  refresh: () => Promise<void>,
  intervalMs: number,
): () => void {
  const timer = window.setInterval(() => {
    void refresh();
  }, intervalMs);
  return () => window.clearInterval(timer);
}

export function codexHomeSourceTokenKey(token: CodexHomeSourceToken | null): string | null {
  return token === null
    ? null
    : JSON.stringify([
        token.transitionGeneration,
        token.canonicalHomeKey,
        token.physicalHomeKey,
      ]);
}

export function sameCodexHomeSourceToken(
  left: CodexHomeSourceToken | null,
  right: CodexHomeSourceToken | null,
): boolean {
  return left === right || (
    left !== null
    && right !== null
    && left.transitionGeneration === right.transitionGeneration
    && left.canonicalHomeKey === right.canonicalHomeKey
    && left.physicalHomeKey === right.physicalHomeKey
  );
}
