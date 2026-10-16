import { callCommandStrict } from "./command";
import type { CodexHomeSourceToken } from "../types/dashboard";
import type { CacheRetentionPoint } from "../domain/cacheRetention/types";

export interface CacheRetentionSnapshot {
  points: CacheRetentionPoint[];
  models: string[];
  sourceCount: number;
  ownRoundCount: number;
  revision: number;
  failures: number;
  updatedAtMicroseconds: number;
}

export function readCacheRetentionSnapshot(sourceToken: CodexHomeSourceToken, days: number | null = null, model: string | null = null) {
  return callCommandStrict<CacheRetentionSnapshot>("read_cache_retention_snapshot", { sourceToken, days, model }, null);
}

export function refreshCacheRetentionSnapshot(sourceToken: CodexHomeSourceToken) {
  return callCommandStrict<CacheRetentionSnapshot>("refresh_cache_retention_snapshot", { sourceToken }, null);
}
