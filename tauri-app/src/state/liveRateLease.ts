import type { LiveRateStreamLease } from "../types/dashboard";

export interface LiveRateLeaseRequest {
  accept: (lease: LiveRateStreamLease) => boolean;
  cancel: () => void;
  ownerGeneration: number;
  ownerSessionEpoch: number;
  ownerToken: string;
}

export interface LiveRateLeaseController {
  begin: () => LiveRateLeaseRequest;
}

export interface LiveRateOwnerSession {
  ownerSessionEpoch: number;
  ownerToken: string;
}

export interface LiveRateOwnerEpochStorage {
  getItem: (key: string) => string | null;
  setItem: (key: string, value: string) => void;
}

const OWNER_EPOCH_KEY_PREFIX = "codex-token-bar:live-rate-owner-epoch:";

export function createLiveRateOwnerSession(
  ownerToken: string,
  storage: LiveRateOwnerEpochStorage = window.localStorage,
): LiveRateOwnerSession {
  if (!ownerToken.trim()) {
    throw new Error("Live-rate owner token is required");
  }
  const key = `${OWNER_EPOCH_KEY_PREFIX}${ownerToken}`;
  const previous = Number.parseInt(storage.getItem(key) ?? "0", 10);
  const normalizedPrevious = Number.isSafeInteger(previous) && previous >= 0 ? previous : 0;
  if (normalizedPrevious >= Number.MAX_SAFE_INTEGER) {
    throw new Error("Live-rate owner session epoch overflow");
  }
  const ownerSessionEpoch = normalizedPrevious + 1;
  storage.setItem(key, String(ownerSessionEpoch));
  return { ownerToken, ownerSessionEpoch };
}

export function tryCreateLiveRateOwnerSession(ownerToken: string): LiveRateOwnerSession | null {
  try {
    return createLiveRateOwnerSession(ownerToken);
  } catch {
    return null;
  }
}

export function createLiveRateLeaseController(
  releaseLease: (leaseId: string) => void,
  ownerSession: LiveRateOwnerSession,
): LiveRateLeaseController {
  let ownerGeneration = 0;

  return {
    begin() {
      ownerGeneration += 1;
      const requestGeneration = ownerGeneration;
      let cancelled = false;
      let acceptedLeaseId: string | null = null;

      return {
        ownerToken: ownerSession.ownerToken,
        ownerSessionEpoch: ownerSession.ownerSessionEpoch,
        ownerGeneration: requestGeneration,
        accept(lease) {
          if (!lease.registered || cancelled || requestGeneration !== ownerGeneration) {
            releaseLease(lease.leaseId);
            return false;
          }
          acceptedLeaseId = lease.leaseId;
          return true;
        },
        cancel() {
          if (cancelled) {
            return;
          }
          cancelled = true;
          if (acceptedLeaseId !== null) {
            releaseLease(acceptedLeaseId);
            acceptedLeaseId = null;
          }
        },
      };
    },
  };
}
