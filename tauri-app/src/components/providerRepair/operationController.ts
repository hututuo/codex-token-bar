export type ProviderRepairOperationKind = "scan" | "verify" | "backup" | "sync" | "rollback";

export interface ProviderRepairOperation {
  id: number;
  kind: ProviderRepairOperationKind;
}

export type ProviderRepairOperationStart =
  | {
      started: true;
      operation: ProviderRepairOperation;
    }
  | {
      started: false;
      message: string;
    };

const BUSY_MESSAGE = "正在执行修复操作，请等待当前步骤完成。";

export interface ProviderRepairOperationController {
  activeKind: () => ProviderRepairOperationKind | null;
  finish: (operation: ProviderRepairOperation) => boolean;
  start: (kind: ProviderRepairOperationKind) => ProviderRepairOperationStart;
}

export function createProviderRepairOperationController(): ProviderRepairOperationController {
  let activeOperation: ProviderRepairOperation | null = null;
  let nextOperationId = 0;

  return {
    activeKind() {
      return activeOperation?.kind ?? null;
    },
    finish(operation) {
      if (activeOperation?.id !== operation.id) {
        return false;
      }
      activeOperation = null;
      return true;
    },
    start(kind) {
      if (activeOperation !== null && !canReplaceOperation(activeOperation.kind, kind)) {
        return {
          started: false,
          message: BUSY_MESSAGE,
        };
      }

      nextOperationId += 1;
      activeOperation = {
        id: nextOperationId,
        kind,
      };
      return {
        started: true,
        operation: activeOperation,
      };
    },
  };
}

function canReplaceOperation(activeKind: ProviderRepairOperationKind, nextKind: ProviderRepairOperationKind) {
  return !isDestructiveProviderRepairOperation(activeKind)
    && !isDestructiveProviderRepairOperation(nextKind);
}

function isDestructiveProviderRepairOperation(kind: ProviderRepairOperationKind) {
  return kind === "backup" || kind === "sync" || kind === "rollback";
}
