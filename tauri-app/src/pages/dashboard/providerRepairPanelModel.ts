import type { ProviderRepairSnapshot } from "../../types/dashboard";

interface ProviderRepairPanelModelInput {
  closeBlocked: boolean;
  open: boolean;
  snapshot: ProviderRepairSnapshot;
}

export function buildProviderRepairPanelModel({ closeBlocked, open, snapshot }: ProviderRepairPanelModelInput) {
  return {
    autoScanOnMount: open && !closeBlocked && shouldAutoScanProviderRepair(snapshot),
    closeDisabled: closeBlocked,
    closeTitle: closeBlocked ? "正在执行修复操作，请等待当前步骤完成。" : "关闭会话消失修复",
  };
}

export function shouldAutoScanProviderRepair(snapshot: ProviderRepairSnapshot): boolean {
  if (snapshot.status.includes("尚未扫描") || snapshot.detectedProvider === "未扫描") {
    return true;
  }

  return snapshot.steps.some((step) => (
    step.label.includes("扫描")
    && !step.done
    && step.status.includes("未扫描")
  ));
}
