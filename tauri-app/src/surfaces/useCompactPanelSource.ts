import { useCallback, useEffect, useRef, useState } from "react";
import { getCodexHome } from "../api/dashboardClient";
import { desktopPlatform } from "../platform/desktop";
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
  subscribe: (
    handler: (envelope: CodexHomeSourceEnvelope) => void,
  ) => Promise<() => void>;
}

const DEFAULT_SOURCE_DEPENDENCIES: CompactPanelSourceDependencies = {
  readCurrentSource: getCodexHome,
  subscribe: desktopPlatform.onCodexHomeSourceChanged,
};

export function useCompactPanelSource(
  dependencies: CompactPanelSourceDependencies = DEFAULT_SOURCE_DEPENDENCIES,
): CodexHomeSourceToken | null {
  const transitionRef = useRef<DashboardSourceTransition>(createDashboardSourceTransition());
  const [sourceToken, setSourceToken] = useState<CodexHomeSourceToken | null>(null);

  const acceptEnvelope = useCallback((envelope: CodexHomeSourceEnvelope) => {
    const result = acceptDashboardSourceEnvelope(transitionRef.current, envelope);
    if (!result.accepted) {
      return;
    }
    transitionRef.current = result.transition;
    const acceptedToken = result.transition.sourceToken;
    setSourceToken((current) => sameCodexHomeSourceToken(current, acceptedToken)
      ? current
      : acceptedToken);
  }, []);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;

    void (async () => {
      const listener = await dependencies.subscribe((envelope) => {
        if (!disposed) {
          acceptEnvelope(envelope);
        }
      });
      if (disposed) {
        listener();
        return;
      }
      unlisten = listener;

      const envelope = await dependencies.readCurrentSource();
      if (!disposed && envelope !== null) {
        acceptEnvelope(envelope);
      }
    })();

    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [acceptEnvelope, dependencies]);

  return sourceToken;
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
