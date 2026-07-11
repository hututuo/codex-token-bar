import type { UpdateAvailability } from "../api/updateClient";

export type UpdateUiPhase = "idle" | "checking" | "available" | "installing" | "error";

interface ReconcilerOptions {
  read: () => Promise<UpdateAvailability>;
  listen: (listener: (state: UpdateAvailability) => void) => Promise<() => void>;
  phase: () => UpdateUiPhase;
  publish: (state: UpdateAvailability) => void;
  schedule?: (callback: () => void, delayMs: number) => number;
  cancel?: (timer: number) => void;
  retryMs?: number;
}

export function shouldApplyRegistryState(phase: UpdateUiPhase, state: UpdateAvailability) {
  if (phase === "checking" || phase === "installing") return false;
  return state.status === "available" || state.status === "none";
}

export function mountUpdateStateReconciler({
  read,
  listen,
  phase,
  publish,
  schedule = (callback, delay) => Number(globalThis.setTimeout(callback, delay)),
  cancel = timer => globalThis.clearTimeout(timer),
  retryMs = 5 * 60_000,
}: ReconcilerOptions) {
  let stopped = false;
  let unlisten: (() => void) | null = null;
  let retryTimer: number | null = null;
  let latestRevision = -1;

  const apply = (state: UpdateAvailability) => {
    const revision = "revision" in state && typeof state.revision === "number" ? state.revision : latestRevision + 1;
    if (revision < latestRevision) return;
    latestRevision = revision;
    if (!stopped && shouldApplyRegistryState(phase(), state)) publish(state);
  };
  const reconcile = async () => {
    try { apply(await read()); } catch { /* Listener remains authoritative when reads fail. */ }
  };
  const scheduleRetry = () => {
    if (stopped) return;
    retryTimer = schedule(() => {
      retryTimer = null;
      void reconcile().finally(scheduleRetry);
    }, retryMs);
  };

  void listen(apply).then(
    async healthyUnlisten => {
      if (stopped) {
        healthyUnlisten();
        return;
      }
      unlisten = healthyUnlisten;
      await reconcile();
    },
    () => {
      void reconcile().finally(scheduleRetry);
    },
  );

  return () => {
    stopped = true;
    unlisten?.();
    if (retryTimer !== null) cancel(retryTimer);
  };
}
