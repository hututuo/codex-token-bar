export interface HeatmapKeyboardAction {
  handled: boolean;
  index: number;
  select: boolean;
}

export function heatmapKeyboardAction(
  key: string,
  currentIndex: number,
  dayCount: number,
): HeatmapKeyboardAction {
  if (dayCount <= 0) {
    return { handled: false, index: 0, select: false };
  }
  const lastIndex = dayCount - 1;
  const clampedCurrent = clampIndex(currentIndex, lastIndex);
  switch (key) {
    case "ArrowUp":
      return move(clampedCurrent - 1, lastIndex);
    case "ArrowDown":
      return move(clampedCurrent + 1, lastIndex);
    case "ArrowLeft":
      return move(clampedCurrent - 7, lastIndex);
    case "ArrowRight":
      return move(clampedCurrent + 7, lastIndex);
    case "Home":
      return move(0, lastIndex);
    case "End":
      return move(lastIndex, lastIndex);
    case "Enter":
    case " ":
    case "Spacebar":
      return { handled: true, index: clampedCurrent, select: true };
    default:
      return { handled: false, index: clampedCurrent, select: false };
  }
}

export function resolveHeatmapFocusDate(
  dates: string[],
  currentDate: string | null,
  hoveredDate: string | null,
  rangeStart: string | null,
): string | null {
  if (dates.length === 0) {
    return null;
  }
  const available = new Set(dates);
  if (currentDate !== null && available.has(currentDate)) {
    return currentDate;
  }
  if (hoveredDate !== null && available.has(hoveredDate)) {
    return hoveredDate;
  }
  if (rangeStart !== null && available.has(rangeStart)) {
    return rangeStart;
  }
  return dates.at(-1) ?? null;
}

export function selectHeatmapDate(date: string, onDateSelect: (date: string) => void) {
  onDateSelect(date);
}

function move(index: number, lastIndex: number): HeatmapKeyboardAction {
  return { handled: true, index: clampIndex(index, lastIndex), select: false };
}

function clampIndex(index: number, lastIndex: number) {
  return Math.min(Math.max(index, 0), lastIndex);
}
