import { startTransition, useEffect, useState } from "react";
import type { CodexRadarSnapshot } from "../domain/codexRadar/model";
import { subscribeCodexRadarState } from "./codexRadarClient";

/**
 * Observes the process-wide Radar client without initiating a second read.
 * CodexRadarStrip remains the single refresh owner and publishes into this subscription.
 */
export function useSubscribedCodexRadarSnapshot(): CodexRadarSnapshot | null {
  const [snapshot, setSnapshot] = useState<CodexRadarSnapshot | null>(null);

  useEffect(() => subscribeCodexRadarState((state) => {
    startTransition(() => setSnapshot(state.snapshot));
  }), []);

  return snapshot;
}
