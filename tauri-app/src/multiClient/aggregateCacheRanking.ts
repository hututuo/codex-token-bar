import { useEffect, useMemo, useState } from "react";
import { callCommandStrict } from "../api/command";
import { isTauriRuntimeAvailable } from "../platform/runtime";
import type { CacheRankingDisplayItem } from "../components/cacheHitRanking/model";
import { clientNames, type Snapshot, type UsageClient } from "./MultiClientUsage";

export interface LocalCacheSession {
  sessionID: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number | null;
  requests: number;
  lowHitRequests: number;
  zeroHitRequests: number;
  lastSeen: number;
}
export function aggregateClientCacheRows(client: string, sessions: LocalCacheSession[]): CacheRankingDisplayItem[] {
  return sessions.filter(row => row.inputTokens >= 1000 && row.requests > 0 && typeof row.cacheReadTokens === "number")
    .map(row => ({
      id: client + "|" + row.sessionID, client, localSessionID: row.sessionID,
      title: (clientNames[client as UsageClient] ?? client) + " · 会话 " + row.sessionID.slice(-12),
      subtitle: `${row.requests} 请求 · ${row.lowHitRequests} 次低命中 · ${row.zeroHitRequests} 次零命中`,
      context: "会话加权 · 缓存写入不算命中",
      sortDate: Number.isFinite(row.lastSeen) ? new Date(row.lastSeen * 1000).toISOString() : null,
      breakdown: {inputTokens: row.inputTokens, cachedInputTokens: row.cacheReadTokens!,
        outputTokens: row.outputTokens, totalTokens: row.inputTokens + row.outputTokens, calls: row.requests},
    }));
}

/** Read only clients with recorded usage. An installed client alone never creates a block or query. */
export function useAggregateClientCacheRows(snapshot: Snapshot | undefined, allowed: readonly string[]) {
  const selected = [...new Set(allowed.filter(client => client !== "codex"
    && snapshot?.summaries.some(row => row.client === client && row.requests > 0)))].sort();
  const key = selected.join(",") + "|" + (snapshot?.updatedAt ?? "");
  const [result, setResult] = useState<{key: string; rows: CacheRankingDisplayItem[]; issue: string}>({key: "", rows: [], issue: ""});
  useEffect(() => {
    if (!selected.length || !isTauriRuntimeAvailable()) return;
    let active = true;
    void Promise.allSettled(selected.map(async client => {
      const projection = await callCommandStrict<{sessions: LocalCacheSession[]}>("read_multi_client_cache_rankings", {client, limit: 200});
      return aggregateClientCacheRows(client, projection.sessions);
    })).then(results => {
      if (!active) return;
      setResult({key, rows: results.flatMap(result => result.status === "fulfilled" ? result.value : []),
        issue: results.some(result => result.status === "rejected") ? "部分客户端的本地缓存排行暂不可用" : ""});
    });
    return () => { active = false; };
  }, [key]);
  return useMemo(() => result.key === key ? result : {key, rows: [], issue: ""}, [key, result]);
}
