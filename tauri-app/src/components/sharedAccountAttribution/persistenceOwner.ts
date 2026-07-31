const OWNER_STORAGE_PREFIX = "sharedAccountAttributionOwner:v1";
const OWNER_INITIALIZED_STORAGE_PREFIX = "sharedAccountAttributionOwnerInitialized:v2";

type OwnerStorage = Pick<Storage, "getItem" | "setItem">;

interface AttributionLockManager {
  request(
    name: string,
    options: { mode: "exclusive"; signal?: AbortSignal },
    callback: () => Promise<void>,
  ): Promise<void>;
}

export interface AttributionPersistenceOwnerLease {
  ownerID: string;
  observationEpoch: string;
  sequence: number;
  leaseUntilUnixMs: number;
}

export interface AttributionPersistenceOwnerState {
  healthy: boolean;
  lease: AttributionPersistenceOwnerLease | null;
  initialized: boolean;
}

export type AttributionPersistenceOwnerTransition =
  | "initialize"
  | "current"
  | "observed"
  | "takeover"
  | "unavailable";

export interface AttributionPersistenceOwnerClaim {
  healthy: boolean;
  isOwner: boolean;
  transition: AttributionPersistenceOwnerTransition;
  lease: AttributionPersistenceOwnerLease | null;
}

export function attributionPersistenceOwnerStorageKey(sourceHomeIdentity: string): string {
  return `${OWNER_STORAGE_PREFIX}:${stableIdentityHash(sourceHomeIdentity)}`;
}

export function attributionPersistenceOwnerInitializedStorageKey(
  sourceHomeIdentity: string,
): string {
  return `${OWNER_INITIALIZED_STORAGE_PREFIX}:${stableIdentityHash(sourceHomeIdentity)}`;
}

export function createAttributionPersistenceOwnerID(): string {
  return createUUID();
}

export function attributionPersistenceLockName(sourceHomeIdentity: string): string {
  return `sharedAccountAttributionPersistence:v2:${stableIdentityHash(sourceHomeIdentity)}`;
}

export function readAttributionPersistenceOwnerState(
  sourceHomeIdentity: string,
  storage?: Pick<Storage, "getItem"> | null,
): AttributionPersistenceOwnerState {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target || !sourceHomeIdentity.trim()) {
    return { healthy: false, lease: null, initialized: false };
  }
  try {
    const initializedRaw = target.getItem(
      attributionPersistenceOwnerInitializedStorageKey(sourceHomeIdentity),
    );
    if (initializedRaw !== null && initializedRaw !== "1") {
      return { healthy: false, lease: null, initialized: false };
    }
    const initialized = initializedRaw === "1";
    const raw = target.getItem(attributionPersistenceOwnerStorageKey(sourceHomeIdentity));
    if (raw === null) return { healthy: true, lease: null, initialized };
    const lease = normalizeLease(JSON.parse(raw));
    return lease === null
      ? { healthy: false, lease: null, initialized }
      : { healthy: true, lease, initialized };
  } catch {
    return { healthy: false, lease: null, initialized: false };
  }
}

/**
 * Publish a fencing record while the caller holds the source-scoped exclusive
 * Web Lock. The storage row is evidence for every synchronous write; it is not
 * itself the lock and must never be used as a read/write CAS.
 */
export function publishAttributionPersistenceOwnerFence(
  sourceHomeIdentity: string,
  contenderID: string,
  nowUnixMs: number,
  leaseDurationMs: number,
  storage?: OwnerStorage | null,
): AttributionPersistenceOwnerClaim {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  if (!target
    || !sourceHomeIdentity.trim()
    || !validUUID(contenderID)
    || !Number.isSafeInteger(nowUnixMs)
    || nowUnixMs <= 0
    || !Number.isSafeInteger(leaseDurationMs)
    || leaseDurationMs <= 0) {
    return { healthy: false, isOwner: false, transition: "unavailable", lease: null };
  }
  const before = readAttributionPersistenceOwnerState(sourceHomeIdentity, target);
  if (!before.healthy) {
    return { healthy: false, isOwner: false, transition: "unavailable", lease: null };
  }
  if (before.lease
    && before.lease.sequence >= Number.MAX_SAFE_INTEGER) {
    return { healthy: false, isOwner: false, transition: "unavailable", lease: before.lease };
  }

  const transition: AttributionPersistenceOwnerTransition = before.lease === null
    && !before.initialized
    ? "initialize"
    : "takeover";
  const lease: AttributionPersistenceOwnerLease = {
    ownerID: contenderID,
    observationEpoch: createUUID(),
    sequence: (before.lease?.sequence ?? 0) + 1,
    leaseUntilUnixMs: nowUnixMs + leaseDurationMs,
  };
  try {
    const key = attributionPersistenceOwnerStorageKey(sourceHomeIdentity);
    target.setItem(key, JSON.stringify(lease));
    target.setItem(attributionPersistenceOwnerInitializedStorageKey(sourceHomeIdentity), "1");
    const verified = readAttributionPersistenceOwnerState(sourceHomeIdentity, target);
    const isOwner = verified.healthy
      && verified.initialized
      && verified.lease?.ownerID === contenderID
      && verified.lease.observationEpoch === lease.observationEpoch
      && verified.lease.sequence === lease.sequence
      && verified.lease.leaseUntilUnixMs === lease.leaseUntilUnixMs;
    return {
      healthy: verified.healthy && isOwner,
      isOwner,
      transition: isOwner ? transition : "unavailable",
      lease: isOwner ? lease : verified.lease,
    };
  } catch {
    return { healthy: false, isOwner: false, transition: "unavailable", lease: null };
  }
}

export function attributionPersistenceFenceIsCurrent(
  sourceHomeIdentity: string,
  expected: AttributionPersistenceOwnerLease | null,
  storage?: Pick<Storage, "getItem"> | null,
): boolean {
  if (expected === null) return false;
  const state = readAttributionPersistenceOwnerState(sourceHomeIdentity, storage);
  return state.healthy
    && state.initialized
    && state.lease?.ownerID === expected.ownerID
    && state.lease.observationEpoch === expected.observationEpoch
    && state.lease.sequence === expected.sequence
    && state.lease.leaseUntilUnixMs === expected.leaseUntilUnixMs;
}

/**
 * Hold one source-scoped exclusive lock for the lifetime of the callback.
 * Web Locks are the cross-window/process authority. The in-process fallback is
 * limited to browser previews/tests; a Tauri runtime without Web Locks fails
 * closed instead of silently returning to localStorage races.
 */
export function holdAttributionPersistenceLock(
  sourceHomeIdentity: string,
  signal: AbortSignal,
  callback: () => Promise<void>,
): Promise<void> {
  if (!sourceHomeIdentity.trim()) return Promise.reject(new Error("missing attribution source"));
  const locks = typeof navigator === "undefined"
    ? null
    : navigator.locks as unknown as Partial<AttributionLockManager>;
  if (typeof locks?.request === "function") {
    return locks.request(
      attributionPersistenceLockName(sourceHomeIdentity),
      { mode: "exclusive", signal },
      callback,
    );
  }
  if (isTauriRuntime()) {
    return Promise.reject(new Error("exclusive attribution persistence lock unavailable"));
  }
  return inProcessLockManager.request(
    attributionPersistenceLockName(sourceHomeIdentity),
    { mode: "exclusive", signal },
    callback,
  );
}

const inProcessLockTails = new Map<string, Promise<void>>();
const inProcessLockManager: AttributionLockManager = {
  async request(name, options, callback) {
    const previous = inProcessLockTails.get(name) ?? Promise.resolve();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const tail = previous.catch(() => undefined).then(() => gate);
    inProcessLockTails.set(name, tail);
    try {
      await waitForLockTurn(previous, options.signal);
      if (options.signal?.aborted) throw abortError();
      await callback();
    } finally {
      release();
      if (inProcessLockTails.get(name) === tail) {
        void tail.finally(() => {
          if (inProcessLockTails.get(name) === tail) inProcessLockTails.delete(name);
        });
      }
    }
  },
};

function waitForLockTurn(previous: Promise<void>, signal?: AbortSignal): Promise<void> {
  if (!signal) return previous;
  if (signal.aborted) return Promise.reject(abortError());
  return new Promise((resolve, reject) => {
    const aborted = () => reject(abortError());
    signal.addEventListener("abort", aborted, { once: true });
    void previous.then(resolve, reject).finally(() => {
      signal.removeEventListener("abort", aborted);
    });
  });
}

function abortError(): Error {
  const error = new Error("attribution persistence lock request aborted");
  error.name = "AbortError";
  return error;
}

function isTauriRuntime(): boolean {
  return typeof globalThis === "object"
    && "__TAURI_INTERNALS__" in (globalThis as Record<string, unknown>);
}

function normalizeLease(value: unknown): AttributionPersistenceOwnerLease | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Partial<AttributionPersistenceOwnerLease>;
  return typeof candidate.ownerID === "string"
    && validUUID(candidate.ownerID)
    && typeof candidate.observationEpoch === "string"
    && validUUID(candidate.observationEpoch)
    && typeof candidate.sequence === "number"
    && Number.isSafeInteger(candidate.sequence)
    && candidate.sequence > 0
    && typeof candidate.leaseUntilUnixMs === "number"
    && Number.isSafeInteger(candidate.leaseUntilUnixMs)
    && candidate.leaseUntilUnixMs > 0
    ? candidate as AttributionPersistenceOwnerLease
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
