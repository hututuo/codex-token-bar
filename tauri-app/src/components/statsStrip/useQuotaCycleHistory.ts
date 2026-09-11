import { useEffect, useMemo, useState } from "react";
import type { CodexHomeSourceToken, QuotaAttributionIdentity, QuotaCycle, QuotaCycleUsage } from "../../types/dashboard";
import { readQuotaCycles, readQuotaCycleUsage } from "../../api/dashboardClient";

export function quotaCycleScopeKey(identity: QuotaAttributionIdentity | null | undefined): string | null {
  return identity ? `${identity.scopeKey}|${identity.plan}|${identity.limit}` : null;
}
export function useQuotaCycleHistory(sourceToken: CodexHomeSourceToken | null, identity: QuotaAttributionIdentity | null,
  refreshKey: string, enabled: boolean) {
  const scope = quotaCycleScopeKey(identity);
  const key = useMemo(() => JSON.stringify([sourceToken, scope]), [sourceToken, scope]);
  const [list, setList] = useState<{key: string; cycles: QuotaCycle[]}>();
  const [selection, setSelection] = useState<{key: string; id: string}>();
  const [detail, setDetail] = useState<{key: string; signature: string; usage: QuotaCycleUsage}>();
  const [error, setError] = useState<{key: string; message: string}>();
  const cycles = list?.key === key ? list.cycles : [];
  const selectedId = selection?.key === key ? selection.id : "current";
  const selected = (selectedId === "current" ? cycles[0] : cycles.find(c => c.id === selectedId)) ?? cycles[0];
  const signature = selected ? JSON.stringify(selected) : "";
  useEffect(() => {
    if (!sourceToken || !scope || !enabled) return;
    let cancelled = false;
    setError(undefined);
    readQuotaCycles(sourceToken, scope).then(cycles => {
      if (!cancelled) setList({key, cycles});
    }).catch(error => { if (!cancelled) setError({key, message: String(error)}); });
    return () => { cancelled = true; };
  }, [key, sourceToken, scope, refreshKey, enabled]);
  useEffect(() => {
    if (!sourceToken || !scope || !selected || !enabled) return;
    let cancelled = false;
    setDetail(undefined);
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
        } else { setDetail({key, signature, usage}); setError(undefined); }
      }).catch(error => { if (!cancelled) setError({key, message: String(error)}); });
    };
    read();
    return () => { cancelled = true; if (retry !== undefined) clearTimeout(retry); };
  }, [key, sourceToken, scope, signature, refreshKey, enabled]);
  return { cycles, selected, select: (id: string) => setSelection({key,id}),
    usage: detail?.key === key && detail.signature === signature ? detail.usage : undefined,
    error: error?.key === key ? error.message : undefined };
}
