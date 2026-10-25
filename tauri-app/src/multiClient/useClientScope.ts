import { useEffect, useMemo, useState } from "react";
import { emit, listen } from "@tauri-apps/api/event";
import {
  clientNames,
  useMultiClientUsage,
  type UsageClient,
} from "./MultiClientUsage";
import { unavailableQuota } from "./multiClientProduct";
import {
  scopeKey,
  scopeClients,
  decodeQuotaSelection,
  quotaSelectionKey,
  quotaItems,
  orderedQuotaItems,
  type QuotaItem,
  type QuotaSelection,
} from "./integratedClientModel";
import { isTauriRuntimeAvailable } from "../platform/runtime";
import type { QuotaSnapshot } from "../types/dashboard";
export const clientTitle = (id: string) =>
  id === "codex"
    ? "Codex"
    : id === "all"
      ? "汇总"
      : (clientNames[id as UsageClient] ?? id);
export const amount = (n: number) =>
  n.toLocaleString(undefined, {
    notation: "compact",
    maximumFractionDigits: 1,
  });
export const value = (i: QuotaItem) =>
  i.remaining === null ? "—" : `${Math.round(i.remaining)}%`;
function useSharedChoice(key: string, fallback: string) {
  const read = () => {
    try {
      return localStorage.getItem(key) ?? fallback;
    } catch {
      return fallback;
    }
  };
  const [raw, setRaw] = useState(read);
  useEffect(() => {
    const update = () => setRaw(read());
    window.addEventListener(key, update);
    window.addEventListener("storage", update);
    let disposed = false,
      unlisten: (() => void) | undefined;
    if (isTauriRuntimeAvailable())
      void listen<string>(key, (e) => {
        if (typeof e.payload === "string") {
          localStorage.setItem(key, e.payload);
          setRaw(e.payload);
        }
      }).then((fn) => {
        if (disposed) fn();
        else unlisten = fn;
      });
    return () => {
      disposed = true;
      unlisten?.();
      window.removeEventListener(key, update);
      window.removeEventListener("storage", update);
    };
  }, [key]);
  return [
    raw,
    (next: string) => {
      localStorage.setItem(key, next);
      setRaw(next);
      window.dispatchEvent(new Event(key));
      if (isTauriRuntimeAvailable()) void emit(key, next).catch(() => {});
    },
  ] as const;
}

export function useClientScope() {
  const { snapshot } = useMultiClientUsage(),
    [raw, setScope] = useSharedChoice(scopeKey, "codex");
  const available = snapshot.preferences
      .filter(
        (p) =>
          p.enabled || snapshot.summaries.some((s) => s.client === p.client),
      )
      .map((p) => p.client),
    allowed = scopeClients(raw, available);
  return {
    raw,
    setScope,
    available,
    allowed,
    codexOnly: allowed.length === 1 && allowed[0] === "codex",
    snapshot,
  };
}

export function useClientQuotaSelection() {
  const [raw, save] = useSharedChoice(quotaSelectionKey, "");
  return {
    selection: useMemo(() => decodeQuotaSelection(raw), [raw]),
    save: (next: QuotaSelection) => save(JSON.stringify(next)),
  };
}

export function useClientQuotaItems(codex?: QuotaSnapshot) {
  const { allowed, snapshot } = useClientScope(),
    { selection } = useClientQuotaSelection();
  const claude =
    snapshot.quotas?.find((q) => q.client === "claudeCode") ??
    unavailableQuota("claudeCode");
  const includeClaude =
    snapshot.preferences.some(
      (p) =>
        (p.client === "claudeCode" || p.client === "claudeDesktop") &&
        (p.enabled || snapshot.detections?.some((d) => d.client === p.client)),
    ) || selection.enabled.some((id) => id.startsWith("claudeCode:"));
  return {
    items: orderedQuotaItems(
      quotaItems(
        codex,
        claude,
        includeClaude,
        selection.enabled.includes("codex:5h"),
      ),
      selection,
      allowed,
    ),
    catalog: orderedQuotaItems(
      quotaItems(
        codex,
        claude,
        includeClaude,
        selection.enabled.includes("codex:5h"),
      ),
      selection,
      allowed,
      true,
    ),
    selection,
  };
}
