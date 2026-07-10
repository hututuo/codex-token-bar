import type { LiveRateStreamLease } from "../types/dashboard";

export interface LiveRateLeaseRequest {
  accept: (lease: LiveRateStreamLease) => boolean;
  cancel: () => void;
  ownerGeneration: number;
  ownerToken: string;
}

export interface LiveRateLeaseController {
  begin: () => LiveRateLeaseRequest;
}

export function createLiveRateLeaseController(
  releaseLease: (leaseId: string) => void,
  ownerToken = createLiveRateOwnerToken(),
): LiveRateLeaseController {
  let ownerGeneration = 0;

  return {
    begin() {
      ownerGeneration += 1;
      const requestGeneration = ownerGeneration;
      let cancelled = false;
      let acceptedLeaseId: string | null = null;

      return {
        ownerToken,
        ownerGeneration: requestGeneration,
        accept(lease) {
          if (cancelled || requestGeneration !== ownerGeneration) {
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

function createLiveRateOwnerToken(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return `live-rate-owner-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}
