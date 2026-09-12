import { useEffect, useMemo, useState } from "react";
import type { CodexHomeSourceToken, QuotaAttributionIdentity, QuotaCycle, QuotaCycleUsage } from "../../types/dashboard";
import { readQuotaCycles, readQuotaCycleUsage } from "../../api/dashboardClient";

export function quotaCycleScopeKey(identity: QuotaAttributionIdentity | null | undefined): string | null {
  return identity ? `${identity.scopeKey}|${identity.plan}|${identity.limit}` : null;
}
function cycleBoundaryKey(cycle: QuotaCycle | undefined): string {
  if (!cycle) return "";
  return JSON.stringify([cycle.id, cycle.startLowerUnix, cycle.startUpperUnix, cycle.firstObservedUnix,
    cycle.current, cycle.current ? null : cycle.endLowerUnix, cycle.current ? null : cycle.endUpperUnix]);
}
export function useQuotaCycleHistory(sourceToken: CodexHomeSourceToken | null, identity: QuotaAttributionIdentity | null,
  refreshKey: string, enabled: boolean) {
  const scope = quotaCycleScopeKey(identity);
  const key = useMemo(() => JSON.stringify([sourceToken, scope]), [sourceToken, scope]);
  const [list, setList] = useState<{key: string; cycles: QuotaCycle[]}>();
  const [selection, setSelection] = useState<{key: string; id: string}>();
  const [detail, setDetail] = useState<{key: string; signature: string; boundaryKey: string;
    end: number; refreshKey: string; usage: QuotaCycleUsage}>();
  const [error, setError] = useState<{key: string; message: string}>();
  const cycles = list?.key === key ? list.cycles : [];
  const selectedId = selection?.key === key ? selection.id : "current";
  const selected = (selectedId === "current" ? cycles[0] : cycles.find(c => c.id === selectedId)) ?? cycles[0];
  const signature = selected ? JSON.stringify(selected) : "";
  const boundaryKey = cycleBoundaryKey(selected);
  useEffect(() => {
    if (!sourceToken || !scope || !enabled) return;
    let cancelled = false;
    setError(undefined);
    readQuotaCycles(sourceToken, scope).then(cycles => {
      if (!cancelled) setList({key, cycles});
    }).catch(error => { if (!cancelled) setError({key, message: String(error)}); });
    return () => { cancelled = true; };
  }, [key, scope, refreshKey, enabled]);
  useEffect(() => {
    if (!sourceToken || !scope || !selected || !enabled) return;
    let cancelled = false;
    // Refreshes of the same period keep its last committed result visible.
    // Home/account/period boundary changes are fenced in the returned value.
    let retry: ReturnType<typeof setTimeout> | undefined;
    let attempts = 0;
    const read = () => {
      readQuotaCycleUsage(sourceToken, scope, selected.id).then(usage => {
        if (cancelled) return;
        if (usage.pendingReason) {
          setError({key, message: usage.pendingReason});
          // Only a declared pending state retries; real failures remain visible.
          // Reads stay SQLite-only, and changing source/selection cancels this.
          if (attempts < 24) retry = setTimeout(read, Math.min(1000 * 2 ** attempts++, 5000));
        } else {
          setDetail({key, signature, boundaryKey, end: selected.endLowerUnix, refreshKey, usage});
          setError(undefined);
        }
      }).catch(error => { if (!cancelled) {
        setDetail(undefined);
        setError({key, message: String(error)});
      } });
    };
    read();
    return () => { cancelled = true; if (retry !== undefined) clearTimeout(retry); };
  }, [key, scope, signature, boundaryKey, refreshKey, enabled]);
  const visibleDetail = detail?.key === key && detail.boundaryKey === boundaryKey
    && selected && selected.endLowerUnix >= detail.end ? detail : undefined;
  return { cycles, selected, select: (id: string) => setSelection({key,id}),
    usage: visibleDetail?.usage,
    refreshing: Boolean(visibleDetail && (visibleDetail.signature !== signature || visibleDetail.refreshKey !== refreshKey)),
    error: error?.key === key ? error.message : undefined };
}
