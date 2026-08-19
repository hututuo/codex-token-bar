import type { PreciseDashboardProgress } from "../../types/dashboard";

export const PRECISE_PROGRESS_REASSURANCE = "首次升级可能需要几分钟，可能短暂占用 CPU 和磁盘，原始数据不会丢失";

export type DashboardHeaderProgressStage =
  | "idle"
  | "structureUpgrade"
  | "historyModelBackfill"
  | "reconciliation"
  | "waiting"
  | "preparing"
  | "scanning"
  | "publishing"
  | "complete"
  | "failed";

export interface DashboardHeaderProgressPresentation {
  stage: DashboardHeaderProgressStage;
  phaseLabel: string;
  text: string;
  countLabel: string | null;
  fraction: number | null;
  showsProgress: boolean;
  showsReassurance: boolean;
  needsAttention: boolean;
  isReady: boolean;
  isVisible: boolean;
}

const phaseLabels: Record<DashboardHeaderProgressStage, string> = {
  idle: "本地统计",
  structureUpgrade: "索引升级",
  historyModelBackfill: "历史模型补全",
  reconciliation: "单文件对账",
  waiting: "等待精确统计",
  preparing: "准备精确统计",
  scanning: "扫描历史",
  publishing: "发布精确统计",
  complete: "已就绪",
  failed: "失败",
};

function normalizedMessage(message: string): string {
  return message.trim().toLocaleLowerCase();
}

function containsAny(message: string, terms: string[]): boolean {
  return terms.some((term) => message.includes(term));
}

function normalizedPhase(phase: string): string {
  return phase.trim().toLocaleLowerCase().replace(/[\s_-]/g, "");
}

/**
 * Resolve the backend phase into a stable header stage. In particular, older
 * Tauri owners put `model` or `reasoning` in the detail message while newer
 * Swift owners expose an explicit backfillingModel phase.
 */
export function dashboardHeaderProgressStage(
  progress: PreciseDashboardProgress,
): DashboardHeaderProgressStage {
  const phase = normalizedPhase(progress.phase);
  const message = normalizedMessage(progress.message);
  const modelBackfill = containsAny(message, [
    "model",
    "reasoning",
    "模型",
  ]);
  const reconciliation = containsAny(message, [
    "reconcil",
    "对账",
    "单文件",
    "单个文件",
  ]);

  switch (phase) {
    case "idle":
      return "idle";
    case "complete":
      return "complete";
    case "failed":
      return "failed";
    case "backfillingmodel":
    case "backfillmodel":
      return "historyModelBackfill";
    case "migrating":
    case "migration":
      return modelBackfill ? "historyModelBackfill" : "structureUpgrade";
    case "waiting":
      return reconciliation ? "reconciliation" : "waiting";
    case "preparing":
      return modelBackfill ? "historyModelBackfill" : "preparing";
    case "scanning":
      if (reconciliation) return "reconciliation";
      return modelBackfill ? "historyModelBackfill" : "scanning";
    case "publishing":
      return "publishing";
    default:
      // Unknown phases remain visible and textual rather than being mistaken
      // for a completed read. This preserves forward compatibility without
      // inventing a progress state.
      return "preparing";
  }
}

function displayText(
  stage: DashboardHeaderProgressStage,
  message: string,
): string {
  const trimmed = message.trim();
  if (stage === "idle") return trimmed || phaseLabels.idle;
  if (stage === "complete") return phaseLabels.complete;
  if (stage === "failed") {
    if (!trimmed) return "失败：精确统计失败";
    return trimmed.includes("失败") ? trimmed : `失败：${trimmed}`;
  }
  if (!trimmed) return phaseLabels[stage];
  if (trimmed.includes(phaseLabels[stage])) {
    return trimmed;
  }
  return `${phaseLabels[stage]}：${trimmed}`;
}

export function presentDashboardHeaderProgress(
  progress: PreciseDashboardProgress | null | undefined,
): DashboardHeaderProgressPresentation | null {
  if (!progress) return null;
  const stage = dashboardHeaderProgressStage(progress);
  const countLabel = progress.total === null
    ? null
    : `${progress.completed}/${progress.total}`;
  const showsProgress = !["idle", "complete", "failed"].includes(stage);
  return {
    stage,
    phaseLabel: phaseLabels[stage],
    text: displayText(stage, progress.message),
    countLabel,
    fraction: progress.fraction,
    showsProgress,
    showsReassurance: stage !== "idle" && stage !== "complete",
    needsAttention: stage === "failed",
    isReady: stage === "complete",
    isVisible: stage !== "idle",
  };
}
