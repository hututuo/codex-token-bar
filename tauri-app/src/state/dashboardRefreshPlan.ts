export type DashboardRefreshTrigger = "manual" | "systemWake" | "quotaRetry";

export type DashboardRefreshAction =
  | "preciseUsage"
  | "forceQuota"
  | "radar"
  | "providerScan";

export interface DashboardRefreshContext {
  providerVisible: boolean;
  dashboardVisible?: boolean;
  usageStale?: boolean;
  radarVisible?: boolean;
  radarStale?: boolean;
}

export interface DashboardRefreshDispatchers {
  refreshPreciseUsage: () => void;
  refreshQuota: () => void;
  refreshRadar: () => void;
  scanProviders: () => void;
}

export function makeDashboardRefreshPlan(
  trigger: DashboardRefreshTrigger,
  context: DashboardRefreshContext,
): DashboardRefreshAction[] {
  if (trigger === "quotaRetry") {
    return ["forceQuota"];
  }

  if (trigger === "manual") {
    const actions: DashboardRefreshAction[] = ["preciseUsage", "forceQuota", "radar"];
    if (context.providerVisible) {
      actions.push("providerScan");
    }
    return actions;
  }

  const actions: DashboardRefreshAction[] = [];
  if (context.dashboardVisible === true || context.usageStale === true) {
    actions.push("preciseUsage");
  }
  actions.push("forceQuota");
  if (context.radarVisible === true || context.radarStale === true) {
    actions.push("radar");
  }
  return actions;
}

export function applyDashboardRefreshPlan(
  actions: DashboardRefreshAction[],
  dispatchers: DashboardRefreshDispatchers,
) {
  actions.forEach((action) => {
    if (action === "preciseUsage") {
      dispatchers.refreshPreciseUsage();
    }
    if (action === "forceQuota") {
      dispatchers.refreshQuota();
    }
    if (action === "radar") {
      dispatchers.refreshRadar();
    }
    if (action === "providerScan") {
      dispatchers.scanProviders();
    }
  });
}
