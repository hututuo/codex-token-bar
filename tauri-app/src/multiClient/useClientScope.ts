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
  compactQuotaValue,
  type QuotaItem,
  type QuotaSelection,
} from "./integratedClientModel";
import type { QuotaSnapshot } from "../types/dashboard";
import {quotaReadingIsPresent} from "./multiClientProduct";
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
  i.remaining === null ? "—" : `${compactQuotaValue(i)}%`;
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
          snapshot.quotas?.some(q => q.client === p.client && quotaReadingIsPresent(q, snapshot.detections?.some(d=>d.client===q.client))),
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
    quotaReadingIsPresent(q, snapshot.detections?.some(d=>d.client===q.client))
    || snapshot.preferences.some(p=>p.client===q.client && p.enabled)));
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
