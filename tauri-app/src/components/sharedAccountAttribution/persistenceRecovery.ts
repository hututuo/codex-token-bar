import {
  markPreciseUsageContinuityGap,
  preciseUsageContinuityStorageKey,
  readPreciseUsageContinuityState,
} from "../../state/preciseUsageContinuity.ts";

const QUARANTINE_STORAGE_PREFIX = "sharedAccountAttributionQuarantine:v1";

type RecoveryStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;

export interface AttributionPersistenceQuarantine {
  id: string;
  detectedAtUnix: number;
  entries: Array<{ key: string; raw: string | null }>;
}

export interface AttributionPersistenceRecoveryResult {
  healthy: boolean;
  quarantined: boolean;
  gapID: string | null;
  quarantineKey: string | null;
}

/**
 * Malformed/missing durable records are preserved verbatim in quarantine,
 * retired with compare-before-remove semantics, and replaced by a synthetic
 * continuity gap. This fails closed on storage I/O, but a readable corrupt row
 * no longer leaves attribution permanently unavailable.
 */
export function quarantineAndRebaselineAttributionPersistence(
  sourceHomeIdentity: string,
  corruptKeys: string[],
  detectedAtUnix: number,
  storage?: RecoveryStorage | null,
): AttributionPersistenceRecoveryResult {
  const target = storage ?? (typeof window === "undefined" ? null : window.localStorage);
  const keys = [...new Set(corruptKeys.filter((key) => key.trim()))].sort();
  if (!target
    || !sourceHomeIdentity.trim()
    || keys.length === 0
    || !Number.isFinite(detectedAtUnix)
    || detectedAtUnix <= 0) {
    return { healthy: false, quarantined: false, gapID: null, quarantineKey: null };
  }
  try {
    const entries = keys.map((key) => ({ key, raw: target.getItem(key) }));
    const quarantine: AttributionPersistenceQuarantine = {
      id: createUUID(),
      detectedAtUnix,
      entries,
    };
    const quarantineKey = [
      QUARANTINE_STORAGE_PREFIX,
      stableIdentityHash(sourceHomeIdentity),
      quarantine.id,
    ].join(":");
    target.setItem(quarantineKey, JSON.stringify(quarantine));
    const verified = normalizeQuarantine(JSON.parse(target.getItem(quarantineKey) ?? "null"));
    if (JSON.stringify(verified) !== JSON.stringify(quarantine)) {
      return { healthy: false, quarantined: false, gapID: null, quarantineKey };
    }
    for (const entry of entries) {
      if (target.getItem(entry.key) !== entry.raw) {
        return { healthy: false, quarantined: true, gapID: null, quarantineKey };
      }
    }
    // If the continuity row itself is corrupt, retire only that row first. All
    // other records (especially the owner lease) remain in place until the new
    // gap is durable, so another window cannot take over and write through a
    // gapless recovery interval.
    const continuityKey = preciseUsageContinuityStorageKey(sourceHomeIdentity);
    const corruptContinuity = entries.find((entry) => entry.key === continuityKey) ?? null;
    if (corruptContinuity !== null) {
      target.removeItem(continuityKey);
      if (target.getItem(continuityKey) !== null) {
        return { healthy: false, quarantined: true, gapID: null, quarantineKey };
      }
    }
    const gap = markPreciseUsageContinuityGap(sourceHomeIdentity, detectedAtUnix, target);
    const continuity = readPreciseUsageContinuityState(sourceHomeIdentity, target);
    if (gap === null
      || !continuity.healthy
      || continuity.gap?.id !== gap.id) {
      return { healthy: false, quarantined: true, gapID: null, quarantineKey };
    }
    for (const entry of entries) {
      if (entry.key === continuityKey) continue;
      target.removeItem(entry.key);
      if (target.getItem(entry.key) !== null) {
        return { healthy: false, quarantined: true, gapID: gap.id, quarantineKey };
      }
    }
    const healthy = readPreciseUsageContinuityState(sourceHomeIdentity, target).gap?.id === gap.id
      && continuity.healthy
      && gap !== null;
    return {
      healthy,
      quarantined: true,
      gapID: healthy ? gap.id : null,
      quarantineKey,
    };
  } catch {
    return { healthy: false, quarantined: false, gapID: null, quarantineKey: null };
  }
}

function normalizeQuarantine(value: unknown): AttributionPersistenceQuarantine | null {
  if (!value || typeof value !== "object") return null;
  const candidate = value as Partial<AttributionPersistenceQuarantine>;
  if (typeof candidate.id !== "string"
    || !validUUID(candidate.id)
    || typeof candidate.detectedAtUnix !== "number"
    || !Number.isFinite(candidate.detectedAtUnix)
    || candidate.detectedAtUnix <= 0
    || !Array.isArray(candidate.entries)) return null;
  const entries: AttributionPersistenceQuarantine["entries"] = [];
  for (const entry of candidate.entries) {
    if (!entry
      || typeof entry !== "object"
      || typeof (entry as { key?: unknown }).key !== "string"
      || ((entry as { raw?: unknown }).raw !== null
        && typeof (entry as { raw?: unknown }).raw !== "string")) return null;
    entries.push(entry as { key: string; raw: string | null });
  }
  return { id: candidate.id, detectedAtUnix: candidate.detectedAtUnix, entries };
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
