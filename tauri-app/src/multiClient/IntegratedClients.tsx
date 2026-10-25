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
  ClientDashboardQuotaStrip,
} from "./ClientQuotaViews";
export {
  ClientScopeSelector,
  ScopedClientDashboard,
  ScopedSidebarUsage,
  ClientSidebarUsageRows,
} from "./ScopedClientDashboard";
