// Integration surface: one shared scope, quota components, and original dashboard slots.
export {
  useClientScope,
  useClientQuotaSelection,
  useClientQuotaItems,
  clientTitle,
} from "./useClientScope";
export {
  ClientQuotaSettings,
  PairedQuotaRing,
  ClientQuotaDetailRings,
} from "./ClientQuotaViews";
export {
  ClientScopeSelector,
  ScopedSidebarUsage,
  ClientSidebarUsageRows,
} from "./ClientScopeControls";
