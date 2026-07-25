export type ProviderRepairActionKey = "scan" | "backup" | "sync" | "migrate" | "verify";

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
  migrate: ProviderRepairActionState;
  verify: ProviderRepairActionState;
}

interface ProviderRepairActionModelInput {
  busy: boolean;
  migrationCandidateCount: number;
}

const BUSY_REASON = "正在执行修复操作，请等待当前步骤完成。";

export function buildProviderRepairActionModel({
  busy,
  migrationCandidateCount,
}: ProviderRepairActionModelInput): ProviderRepairActionModel {
  const migrationDisabled = busy || migrationCandidateCount === 0;
  return {
    scan: actionState("scan", "1 扫描", busy, busy ? BUSY_REASON : null),
    backup: actionState("backup", "2 创建备份", busy, busy ? BUSY_REASON : null),
    sync: actionState("sync", "3 安全修复", busy, busy ? BUSY_REASON : null),
    migrate: actionState(
      "migrate",
      `4 迁移历史${migrationCandidateCount > 0 ? ` (${migrationCandidateCount})` : ""}`,
      migrationDisabled,
      busy
        ? BUSY_REASON
        : migrationCandidateCount === 0
          ? "当前没有需要迁移的历史会话。"
          : null,
    ),
    verify: actionState("verify", "5 验证", busy, busy ? BUSY_REASON : null),
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
