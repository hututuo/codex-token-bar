export interface SidebarContentMeasurement { contentHeight: number; speedRowHeight: number }

/** Fit current content in both directions; the native coordinator animates each changed target. */
export function createSidebarHeightBudget() {
  let content = 0;
  let height: number | undefined;
  return {
    update(measurement: SidebarContentMeasurement | undefined, _expanded: boolean, _rebase = false) {
      if (measurement && Number.isFinite(measurement.contentHeight) && measurement.contentHeight > 0) content = Math.ceil(measurement.contentHeight);
      if (content <= 0) return height;
      height = Math.max(90, content + 24);
      return height;
    },
  };
}
