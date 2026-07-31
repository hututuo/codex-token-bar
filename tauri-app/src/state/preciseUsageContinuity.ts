const STORAGE_PREFIX = "sharedAccountAttributionPreciseContinuity:v2";
const LEGACY_STORAGE_PREFIX = "sharedAccountAttributionPreciseContinuity:v1";
const OBSERVER_STORAGE_PREFIX = "sharedAccountAttributionPreciseObserver:v1";

type ContinuityStorage = Pick<Storage, "getItem"> & Partial<Pick<Storage, "setItem" | "removeItem">>;

export interface PreciseUsageContinuityGap {
  id: string;
  generation: number;
  detectedAtUnix: number;
}

export interface PreciseUsageContinuityState {
  healthy: boolean;
  gap: PreciseUsageContinuityGap | null;
}

export interface PreciseUsageObserverEpoch {
  epoch: string;
  startedAtUnixMicros: number;
  sequence: number;
}

export interface PreciseUsageObserverState {
  healthy: boolean;
  observer: PreciseUsageObserverEpoch | null;
}

export type PreciseUsageObserverTransition =
  | "current"
  | "initialize"
  | "restart"
  | "superseded"
  | "conflict"
  | "unavailable";

export interface PreciseUsageObserverReconcileResult {
  healthy: boolean;
  changed: boolean;
  gapCreated: boolean;
  transition: PreciseUsageObserverTransition;
}

export function preciseUsageContinuityStorageKey(sourceHomeIdentity: string): string {
  return `${STORAGE_PREFIX}:${stableIdentityHash(sourceHomeIdentity)}`;
}

export function preciseUsageObserverStorageKey(sourceHomeIdentity: string): string {
  return `${OBSERVER_STORAGE_PREFIX}:${stableIdentityHash(sourceHomeIdentity)}`;
}

export function readPreciseUsageObserverState(
  sourceHomeIdentity: string,
  storage?: ContinuityStorage | null,
): PreciseUsageObserverState {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target || !sourceHomeIdentity.trim()) return { healthy: true, observer: null };
  try {
    const raw = target.getItem(preciseUsageObserverStorageKey(sourceHomeIdentity));
    if (raw === null) return { healthy: true, observer: null };
    const observer = normalizeObserver(JSON.parse(raw));
    return observer === null
      ? { healthy: false, observer: null }
      : { healthy: true, observer };
  } catch {
    return { healthy: false, observer: null };
  }
}

export function preciseUsageObserverTransition(
  stored: PreciseUsageObserverState,
  current: PreciseUsageObserverEpoch | null,
): PreciseUsageObserverTransition {
  if (!stored.healthy || !current || !normalizeObserver(current)) return "unavailable";
  if (!stored.observer) return "initialize";
  if (stored.observer.epoch === current.epoch
    && stored.observer.startedAtUnixMicros === current.startedAtUnixMicros
    && stored.observer.sequence === current.sequence) return "current";
  if (current.startedAtUnixMicros > stored.observer.startedAtUnixMicros) return "restart";
  if (current.startedAtUnixMicros < stored.observer.startedAtUnixMicros) return "superseded";
  if (current.sequence > stored.observer.sequence) return "restart";
  if (current.sequence < stored.observer.sequence) return "superseded";
  return "conflict";
}

/**
 * Publishes a newer native observer only after its continuity gap is durable.
 * A late window from an older process is ordered by native start time and can
 * never overwrite the newer observer marker.
 */
export function reconcilePreciseUsageObserverEpoch(
  sourceHomeIdentity: string,
  current: PreciseUsageObserverEpoch,
  requireGap: boolean,
  detectedAtUnix: number,
  storage?: ContinuityStorage | null,
): PreciseUsageObserverReconcileResult {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target || !target.setItem || !sourceHomeIdentity.trim()) {
    return { healthy: false, changed: false, gapCreated: false, transition: "unavailable" };
  }
  const before = readPreciseUsageObserverState(sourceHomeIdentity, target);
  const transition = preciseUsageObserverTransition(before, current);
  if (transition === "current") {
    return { healthy: true, changed: false, gapCreated: false, transition };
  }
  if (transition === "unavailable" || transition === "superseded" || transition === "conflict") {
    return { healthy: false, changed: false, gapCreated: false, transition };
  }
  let gapCreated = false;
  if (requireGap) {
    const gap = markPreciseUsageContinuityGap(sourceHomeIdentity, detectedAtUnix, target);
    if (!gap) return { healthy: false, changed: false, gapCreated: false, transition };
    gapCreated = true;
  }
  try {
    // Re-read immediately before writing. Another window may already have
    // published this same process epoch while we were persisting the gap.
    const latest = readPreciseUsageObserverState(sourceHomeIdentity, target);
    const latestTransition = preciseUsageObserverTransition(latest, current);
    if (latestTransition === "current") {
      return { healthy: true, changed: gapCreated, gapCreated, transition };
    }
    if (latestTransition !== "initialize" && latestTransition !== "restart") {
      return { healthy: false, changed: gapCreated, gapCreated, transition: latestTransition };
    }
    const key = preciseUsageObserverStorageKey(sourceHomeIdentity);
    target.setItem(key, JSON.stringify(current));
    const verified = readPreciseUsageObserverState(sourceHomeIdentity, target);
    const healthy = preciseUsageObserverTransition(verified, current) === "current";
    return { healthy, changed: true, gapCreated, transition };
  } catch {
    return { healthy: false, changed: gapCreated, gapCreated, transition };
  }
}

export function readPreciseUsageContinuityState(
  sourceHomeIdentity: string,
  storage?: ContinuityStorage | null,
  allowLegacyMigration = true,
): PreciseUsageContinuityState {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target || !sourceHomeIdentity.trim()) return { healthy: true, gap: null };
  const identityHash = stableIdentityHash(sourceHomeIdentity);
  const key = `${STORAGE_PREFIX}:${identityHash}`;
  try {
    const raw = target.getItem(key);
    if (raw !== null) {
      const gap = normalizeGap(JSON.parse(raw));
      return gap ? { healthy: true, gap } : { healthy: false, gap: null };
    }

    const legacyKey = `${LEGACY_STORAGE_PREFIX}:${identityHash}`;
    const legacyRaw = target.getItem(legacyKey);
    if (legacyRaw === null) return { healthy: true, gap: null };
    if (!allowLegacyMigration) return { healthy: false, gap: null };
    const legacy = JSON.parse(legacyRaw) as { detectedAtUnix?: unknown } | null;
    if (!legacy
      || typeof legacy.detectedAtUnix !== "number"
      || !Number.isFinite(legacy.detectedAtUnix)
      || legacy.detectedAtUnix <= 0
      || !target.setItem
      || !target.removeItem) {
      return { healthy: false, gap: null };
    }
    const migrated: PreciseUsageContinuityGap = {
      id: createUUID(),
      generation: 1,
      detectedAtUnix: legacy.detectedAtUnix,
    };
    target.setItem(key, JSON.stringify(migrated));
    if (JSON.stringify(normalizeGap(JSON.parse(target.getItem(key) ?? "null")))
      !== JSON.stringify(migrated)) {
      return { healthy: false, gap: null };
    }
    target.removeItem(legacyKey);
    if (target.getItem(legacyKey) !== null) return { healthy: false, gap: null };
    return { healthy: true, gap: migrated };
  } catch {
    return { healthy: false, gap: null };
  }
}

export function readPreciseUsageContinuityGap(
  sourceHomeIdentity: string,
  storage?: ContinuityStorage | null,
): PreciseUsageContinuityGap | null {
  return readPreciseUsageContinuityState(sourceHomeIdentity, storage).gap;
}

/** Each settled failed exact-read generation replaces the previous gap identity. */
export function markPreciseUsageContinuityGap(
  sourceHomeIdentity: string,
  detectedAtUnix: number,
  storage?: ContinuityStorage | null,
): PreciseUsageContinuityGap | null {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target
    || !target.setItem
    || !sourceHomeIdentity.trim()
    || !Number.isFinite(detectedAtUnix)
    || detectedAtUnix <= 0) return null;
  const previous = readPreciseUsageContinuityState(sourceHomeIdentity, target);
  if (!previous.healthy) return null;
  const record: PreciseUsageContinuityGap = {
    id: createUUID(),
    generation: (previous.gap?.generation ?? 0) + 1,
    detectedAtUnix,
  };
  try {
    const key = preciseUsageContinuityStorageKey(sourceHomeIdentity);
    target.setItem(key, JSON.stringify(record));
    const verified = normalizeGap(JSON.parse(target.getItem(key) ?? "null"));
    return JSON.stringify(verified) === JSON.stringify(record) ? record : null;
  } catch {
    return null;
  }
}

export function clearPreciseUsageContinuityGap(
  sourceHomeIdentity: string,
  expectedID: string,
  storage?: ContinuityStorage | null,
): boolean {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target || !target.removeItem || !sourceHomeIdentity.trim()) return false;
  const state = readPreciseUsageContinuityState(sourceHomeIdentity, target);
  if (!state.healthy || state.gap?.id !== expectedID) return false;
  try {
    const key = preciseUsageContinuityStorageKey(sourceHomeIdentity);
    target.removeItem(key);
    return target.getItem(key) === null;
  } catch {
    return false;
  }
}

function normalizeGap(value: unknown): PreciseUsageContinuityGap | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Partial<PreciseUsageContinuityGap>;
  return typeof candidate.id === "string"
    && validUUID(candidate.id)
    && typeof candidate.generation === "number"
    && Number.isSafeInteger(candidate.generation)
    && candidate.generation > 0
    && typeof candidate.detectedAtUnix === "number"
    && Number.isFinite(candidate.detectedAtUnix)
    && candidate.detectedAtUnix > 0
    ? candidate as PreciseUsageContinuityGap
    : null;
}

function normalizeObserver(value: unknown): PreciseUsageObserverEpoch | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Partial<PreciseUsageObserverEpoch>;
  return typeof candidate.epoch === "string"
    && validUUID(candidate.epoch)
    && typeof candidate.startedAtUnixMicros === "number"
    && Number.isSafeInteger(candidate.startedAtUnixMicros)
    && candidate.startedAtUnixMicros > 0
    && typeof candidate.sequence === "number"
    && Number.isSafeInteger(candidate.sequence)
    && candidate.sequence >= 0
    ? candidate as PreciseUsageObserverEpoch
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

function validUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function stableIdentityHash(value: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}
