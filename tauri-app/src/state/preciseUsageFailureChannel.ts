export interface PreciseUsageFailureSignal {
  id: string;
  sourceHomeIdentity: string;
  detectedAtUnix: number;
}

type FailureListener = (signal: PreciseUsageFailureSignal) => void;

const CHANNEL_NAME = "codex-token-bar-precise-usage-failure-v1";
const CHANNEL_STATE_KEY = "__codexTokenBarPreciseUsageFailureChannelV1";

interface FailureChannelState {
  listeners: Set<FailureListener>;
  latestBySource: Map<string, PreciseUsageFailureSignal>;
  broadcastChannel: BroadcastChannel | null | undefined;
}

export function publishPreciseUsageFailure(
  sourceHomeIdentity: string,
  detectedAtUnix: number,
): PreciseUsageFailureSignal | null {
  if (!sourceHomeIdentity.trim()
    || !Number.isFinite(detectedAtUnix)
    || detectedAtUnix <= 0) return null;
  const signal: PreciseUsageFailureSignal = {
    id: createUUID(),
    sourceHomeIdentity,
    detectedAtUnix,
  };
  const state = failureChannelState();
  state.latestBySource.set(sourceHomeIdentity, signal);
  for (const listener of state.listeners) listener(signal);
  failureBroadcastChannel()?.postMessage(signal);
  return signal;
}

export function subscribePreciseUsageFailures(
  sourceHomeIdentity: string,
  listener: FailureListener,
): () => void {
  if (!sourceHomeIdentity.trim()) return () => {};
  const scoped: FailureListener = (signal) => {
    if (signal.sourceHomeIdentity === sourceHomeIdentity) listener(signal);
  };
  const state = failureChannelState();
  state.listeners.add(scoped);
  const latest = state.latestBySource.get(sourceHomeIdentity);
  if (latest) queueMicrotask(() => {
    if (state.listeners.has(scoped)) scoped(latest);
  });
  failureBroadcastChannel();
  return () => state.listeners.delete(scoped);
}

export function acknowledgePreciseUsageFailure(
  sourceHomeIdentity: string,
  id: string,
): void {
  const state = failureChannelState();
  const current = state.latestBySource.get(sourceHomeIdentity);
  if (current?.id === id) state.latestBySource.delete(sourceHomeIdentity);
  failureBroadcastChannel()?.postMessage({
    type: "acknowledge",
    sourceHomeIdentity,
    id,
  });
}

function failureBroadcastChannel(): BroadcastChannel | null {
  const state = failureChannelState();
  if (state.broadcastChannel !== undefined) return state.broadcastChannel;
  if (!isTauriRuntime() || typeof BroadcastChannel !== "function") {
    state.broadcastChannel = null;
    return null;
  }
  state.broadcastChannel = new BroadcastChannel(CHANNEL_NAME);
  state.broadcastChannel.addEventListener("message", (event: MessageEvent<unknown>) => {
    const acknowledgement = normalizeAcknowledgement(event.data);
    if (acknowledgement !== null) {
      const current = state.latestBySource.get(acknowledgement.sourceHomeIdentity);
      if (current?.id === acknowledgement.id) {
        state.latestBySource.delete(acknowledgement.sourceHomeIdentity);
      }
      return;
    }
    const signal = normalizeSignal(event.data);
    if (signal === null) return;
    state.latestBySource.set(signal.sourceHomeIdentity, signal);
    for (const listener of state.listeners) listener(signal);
  });
  return state.broadcastChannel;
}

function failureChannelState(): FailureChannelState {
  const root = globalThis as unknown as Record<string, unknown>;
  const existing = root[CHANNEL_STATE_KEY] as FailureChannelState | undefined;
  if (existing?.listeners instanceof Set && existing.latestBySource instanceof Map) {
    return existing;
  }
  const created: FailureChannelState = {
    listeners: new Set(),
    latestBySource: new Map(),
    broadcastChannel: undefined,
  };
  root[CHANNEL_STATE_KEY] = created;
  return created;
}

function normalizeAcknowledgement(
  value: unknown,
): { sourceHomeIdentity: string; id: string } | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as {
    type?: unknown;
    sourceHomeIdentity?: unknown;
    id?: unknown;
  };
  return candidate.type === "acknowledge"
    && typeof candidate.sourceHomeIdentity === "string"
    && candidate.sourceHomeIdentity.trim().length > 0
    && typeof candidate.id === "string"
    && isUUID(candidate.id)
    ? { sourceHomeIdentity: candidate.sourceHomeIdentity, id: candidate.id }
    : null;
}

function normalizeSignal(value: unknown): PreciseUsageFailureSignal | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Partial<PreciseUsageFailureSignal>;
  return typeof candidate.id === "string"
    && isUUID(candidate.id)
    && typeof candidate.sourceHomeIdentity === "string"
    && candidate.sourceHomeIdentity.trim().length > 0
    && typeof candidate.detectedAtUnix === "number"
    && Number.isFinite(candidate.detectedAtUnix)
    && candidate.detectedAtUnix > 0
    ? candidate as PreciseUsageFailureSignal
    : null;
}

function createUUID(): string {
  if (typeof globalThis.crypto?.randomUUID === "function") return globalThis.crypto.randomUUID();
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (symbol) => {
    const random = Math.floor(Math.random() * 16);
    const value = symbol === "x" ? random : (random & 0x3) | 0x8;
    return value.toString(16);
  });
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function isTauriRuntime(): boolean {
  return typeof globalThis === "object"
    && "__TAURI_INTERNALS__" in (globalThis as Record<string, unknown>);
}
