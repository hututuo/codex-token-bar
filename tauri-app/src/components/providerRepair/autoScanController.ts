export interface ProviderRepairAutoScanController {
  shouldStart: (autoScanOnMount: boolean) => boolean;
}

export function createProviderRepairAutoScanController(): ProviderRepairAutoScanController {
  let started = false;

  return {
    shouldStart(autoScanOnMount) {
      if (!autoScanOnMount || started) {
        return false;
      }
      started = true;
      return true;
    },
  };
}
