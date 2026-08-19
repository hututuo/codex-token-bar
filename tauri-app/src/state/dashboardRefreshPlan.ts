export type DashboardRefreshTrigger = "manual" | "systemWake" | "quotaRetry";

export type DashboardRefreshAction =
  | "lightSummary"
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
  refreshLightSummary: () => void;
  refreshPreciseUsage: () => void;
  refreshQuota: () => void;
  refreshRadar: () => void;
  scanProviders: () => void;
}

export interface DashboardWakeRefreshContextInput {
  dashboardGeneratedAt: string | null;
  preciseCoveredAt?: string | null;
  preciseFresh?: boolean;
  eligibleBoundarySeconds?: number;
  dashboardVisible: boolean;
  nowMs: number;
  visibleRefreshIntervalMs: number;
}

export interface ManualDashboardRefreshInput {
  providerRepairVisible: boolean;
  dispatchers: DashboardRefreshDispatchers;
}

export function makeDashboardWakeRefreshContext({
  dashboardGeneratedAt,
  preciseCoveredAt,
  preciseFresh,
  eligibleBoundarySeconds,
  dashboardVisible,
  nowMs,
  visibleRefreshIntervalMs,
}: DashboardWakeRefreshContextInput): DashboardRefreshContext {
  const preciseCoveredSeconds = preciseCoveredAt ? Date.parse(preciseCoveredAt) / 1_000 : Number.NaN;
  const generatedAtMs = dashboardGeneratedAt ? Date.parse(dashboardGeneratedAt) : 0;
  const usageStale = preciseFresh === false || (Number.isFinite(eligibleBoundarySeconds)
    ? !Number.isFinite(preciseCoveredSeconds)
      || preciseCoveredSeconds < (eligibleBoundarySeconds ?? 0)
    : generatedAtMs === 0 || nowMs - generatedAtMs >= visibleRefreshIntervalMs);

  return {
    providerVisible: false,
    dashboardVisible,
    usageStale,
    radarVisible: dashboardVisible,
    radarStale: false,
  };
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
  actions.push("lightSummary");
  if (context.usageStale === true) {
    actions.push("preciseUsage");
  }
  actions.push("forceQuota");
  if (context.radarVisible === true || context.radarStale === true) {
    actions.push("radar");
  }
  return actions;
}

export function applyManualDashboardRefresh({
  providerRepairVisible,
  dispatchers,
}: ManualDashboardRefreshInput) {
  const plan = makeDashboardRefreshPlan("manual", {
    providerVisible: providerRepairVisible,
  });
  applyDashboardRefreshPlan(plan, dispatchers);
}

export function applyDashboardRefreshPlan(
  actions: DashboardRefreshAction[],
  dispatchers: DashboardRefreshDispatchers,
) {
  actions.forEach((action) => {
    if (action === "lightSummary") {
      dispatchers.refreshLightSummary();
    }
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
