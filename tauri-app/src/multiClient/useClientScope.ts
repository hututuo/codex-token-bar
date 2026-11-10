import { createContext, createElement, useContext, useMemo, type ReactNode } from "react";
import { choiceEvents, useSharedChoice } from "./useSharedChoice";
import {
  clientNames,
  useMultiClientUsage,
  type UsageClient,
} from "./MultiClientUsage";
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
const ClientScopeSurface = createContext<"dashboard" | "sidebar">("dashboard");
export function ClientScopeBoundary({surface,children}:{surface:"dashboard"|"sidebar";children:ReactNode}) {
  return createElement(ClientScopeSurface.Provider,{value:surface},children);
}
export const sidebarScopeKey = "multiClient.sidebarDisplayScope.v1";

export function useClientScope() {
  const surface = useContext(ClientScopeSurface);
  const { snapshot } = useMultiClientUsage(),
    [raw, setScope] = useSharedChoice(
      surface === "sidebar" ? sidebarScopeKey : scopeKey,
      surface === "sidebar" ? choiceEvents.sidebar : choiceEvents.dashboard,
      surface === "sidebar" ? "all" : "codex",
    );
  const available = useMemo(() => snapshot.preferences
      .filter(
        (p) =>
          p.enabled || snapshot.summaries.some((s) => s.client === p.client) ||
          snapshot.quotas?.some(q => q.client === p.client && (q.windows.length > 0 || q.capturedAt)),
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
  const [raw, save] = useSharedChoice(quotaSelectionKey, choiceEvents.quota, "");
  return {
    selection: useMemo(() => decodeQuotaSelection(raw), [raw]),
    save: (next: QuotaSelection) => save(JSON.stringify(next)),
  };
}

export function useClientQuotaItems(codex?: QuotaSnapshot) {
  const { allowed, snapshot } = useClientScope(),
    { selection } = useClientQuotaSelection();
  const localReadings=(snapshot.quotas??[]).filter(q=>q.source!=="unsupported" && (
    q.windows.length>0 || q.capturedAt || snapshot.preferences.some(p=>p.client===q.client && p.enabled)
    || snapshot.detections?.some(d=>d.client===q.client)));
  const catalog=quotaItems(codex,localReadings,selection.enabled.includes("codex:5h"));
  return {
    items: orderedQuotaItems(
      catalog,
      selection,
      allowed,
    ),
    catalog: orderedQuotaItems(
      catalog,
      selection,
      allowed,
      true,
    ),
    selection,
  };
}
