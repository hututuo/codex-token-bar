export interface SidebarContentMeasurement { contentHeight: number; speedRowHeight: number }

/** Arm one TPS row on closing/opening, spend it while open, then grow only as needed. */
export function createSidebarHeightBudget() {
  let content = 0, row = 40;
  let height: number | undefined;
  return {
    update(measurement: SidebarContentMeasurement | undefined, expanded: boolean, rebase = false) {
      if (rebase) height = undefined;
      if (measurement && Number.isFinite(measurement.contentHeight) && measurement.contentHeight > 0) content = Math.ceil(measurement.contentHeight);
      if (measurement && Number.isFinite(measurement.speedRowHeight) && measurement.speedRowHeight >= 0) row = Math.ceil(measurement.speedRowHeight);
      if (content <= 0) return height;
      const required = content + 24;
      if (!expanded || height === undefined) height = Math.max(192, required + row);
      else if (required > height) height = required;
      return height;
    },
  };
}
