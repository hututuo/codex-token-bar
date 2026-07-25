import type {
  ProviderRepairActionResult,
  ProviderRepairSnapshot,
} from "../../types/providerRepair";

export const fallbackProviderRepairSnapshot: ProviderRepairSnapshot = {
  detectedProvider: "待读取",
  providerSource: "本地扫描",
  sessionFilesFound: 0,
  inconsistentCount: 0,
  migrationCandidateCount: 0,
  invalidSessionFiles: 0,
  ambiguousThreadCount: 0,
  status: "会话修复状态待读取。",
  steps: [
    { label: "扫描", status: "未扫描", done: false, healthy: true },
    { label: "备份", status: "未备份", done: false, healthy: true },
    { label: "修复", status: "未进行修复", done: false, healthy: true },
    { label: "验证", status: "未验证", done: false, healthy: true },
  ],
};

export const fallbackProviderRepairActionResult: ProviderRepairActionResult = {
  snapshot: fallbackProviderRepairSnapshot,
  message: "本地操作未完成，请稍后重试。",
  backup: null,
  backups: [],
};
