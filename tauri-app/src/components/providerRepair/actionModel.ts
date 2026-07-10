export type ProviderRepairActionKey = "scan" | "backup" | "sync" | "verify";

export interface ProviderRepairActionState {
  disabled: boolean;
  key: ProviderRepairActionKey;
  label: string;
  reason: string | null;
}

export interface ProviderRepairActionModel {
  scan: ProviderRepairActionState;
  backup: ProviderRepairActionState;
  sync: ProviderRepairActionState;
  verify: ProviderRepairActionState;
}

interface ProviderRepairActionModelInput {
  busy: boolean;
}

const BUSY_REASON = "正在执行修复操作，请等待当前步骤完成。";

export function buildProviderRepairActionModel({
  busy,
}: ProviderRepairActionModelInput): ProviderRepairActionModel {
  return {
    scan: actionState("scan", "1 扫描", busy, busy ? BUSY_REASON : null),
    backup: actionState("backup", "2 创建备份", busy, busy ? BUSY_REASON : null),
    sync: actionState("sync", "3 同步修复", busy, busy ? BUSY_REASON : null),
    verify: actionState("verify", "4 验证", busy, busy ? BUSY_REASON : null),
  };
}

function actionState(
  key: ProviderRepairActionKey,
  label: string,
  disabled: boolean,
  reason: string | null,
): ProviderRepairActionState {
  return {
    disabled,
    key,
    label,
    reason,
  };
}
