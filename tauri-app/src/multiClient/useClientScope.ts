import { createContext, createElement, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { emitPlatformEvent, listenToEvent } from "../platform/desktopBridge";
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
// Persisted keys predate native synchronization and contain dots, which Tauri
// event names reject. Keep storage compatibility and use separate IPC channels.
const sharedChoiceEvents = {
  dashboard: "multi-client-display-scope-changed",
  sidebar: "multi-client-sidebar-display-scope-changed",
  quota: "multi-client-quota-selection-changed",
} as const;

function useSharedChoice(key: string, fallback: string, eventName: string) {
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
      void listenToEvent<string>(eventName, (payload) => {
        if (typeof payload === "string") {
          localStorage.setItem(key, payload);
          setRaw(payload);
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
  }, [key, eventName]);
  return [
    raw,
    (next: string) => {
      localStorage.setItem(key, next);
      setRaw(next);
      window.dispatchEvent(new Event(key));
      if (isTauriRuntimeAvailable()) void emitPlatformEvent(eventName, `emit:${eventName}`, next);
    },
  ] as const;
}

const ClientScopeSurface = createContext<"dashboard" | "sidebar">("dashboard");
export function ClientScopeBoundary({surface,children}:{surface:"dashboard"|"sidebar";children:ReactNode}) {
  return createElement(ClientScopeSurface.Provider,{value:surface},children);
}
export const sidebarScopeKey = "multiClient.sidebarDisplayScope.v1";

export function useClientScope() {
  const surface = useContext(ClientScopeSurface);
  const { snapshot } = useMultiClientUsage();
  const [raw, setScope] = useSharedChoice(
    surface === "sidebar" ? sidebarScopeKey : scopeKey,
    surface === "sidebar" ? "all" : "codex",
    sharedChoiceEvents[surface],
  );
  const available = useMemo(() => snapshot.preferences
      .filter(
        (p) =>
          p.enabled || snapshot.summaries.some((s) => s.client === p.client) ||
          (p.client === "claudeCode" && snapshot.quotas?.some(q => q.client === "claudeCode" && q.state === "available" && q.windows.length > 0)),
      )
      .map((p) => p.client), [snapshot.preferences, snapshot.summaries, snapshot.quotas]);
  const allowed = useMemo(() => scopeClients(raw, available), [raw, available]);
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
  const [raw, save] = useSharedChoice(quotaSelectionKey, "", sharedChoiceEvents.quota);
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
    ) || selection.enabled.some((id) => id.startsWith("claudeCode:")) || claude.state === "available";
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
