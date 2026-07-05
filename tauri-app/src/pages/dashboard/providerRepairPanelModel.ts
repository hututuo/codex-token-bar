interface ProviderRepairPanelModelInput {
  busy: boolean;
}

export function buildProviderRepairPanelModel({ busy }: ProviderRepairPanelModelInput) {
  return {
    closeDisabled: busy,
    closeTitle: busy ? "正在执行修复操作，请等待当前步骤完成。" : "关闭会话消失修复",
  };
}
