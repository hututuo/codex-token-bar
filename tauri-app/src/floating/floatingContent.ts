import type { FloatingContentGroup, FloatingContentVisibility } from "../types/dashboard";

export const FLOATING_CONTENT_GROUPS: FloatingContentGroup[] = [
  "rateAndBar",
  "usageStatus",
  "metrics",
  "radar",
  "crowdRadar",
  "quota",
];

export const DEFAULT_FLOATING_CONTENT_VISIBILITY: FloatingContentVisibility = {
  showRateAndBar: true,
  showUsageStatus: true,
  showMetrics: true,
  showQuota: true,
  showRadar: true,
  showCrowdRadar: true,
  order: FLOATING_CONTENT_GROUPS,
};

export const FLOATING_CONTENT_LABELS: Record<FloatingContentGroup, { title: string; subtitle?: string }> = {
  rateAndBar: { title: "速率" },
  usageStatus: { title: "趣味话", subtitle: "靠近速率会吸附" },
  metrics: { title: "总今次" },
  radar: { title: "Radar" },
  crowdRadar: { title: "众测雷达" },
  quota: { title: "5h/7d" },
};

export function sanitizeFloatingContentVisibility(value: Partial<FloatingContentVisibility> | undefined): FloatingContentVisibility {
  return {
    showRateAndBar: value?.showRateAndBar ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showRateAndBar,
    showUsageStatus: value?.showUsageStatus ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showUsageStatus,
    showMetrics: value?.showMetrics ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showMetrics,
    showQuota: value?.showQuota ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showQuota,
    showRadar: value?.showRadar ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showRadar,
    showCrowdRadar: value?.showCrowdRadar ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showCrowdRadar,
    order: sanitizeContentOrder(value?.order),
  };
}

export function layoutFloatingContentGroups(visibility: FloatingContentVisibility): FloatingContentGroup[] {
  const visible = visibleFloatingContentGroups(visibility);
  if (!embedsUsageStatusInRateRow(visibility)) {
    return visible;
  }

  let appendedAttachedRateRow = false;
  return visible.flatMap((group) => {
    if (group !== "rateAndBar" && group !== "usageStatus") {
      return [group];
    }
    if (appendedAttachedRateRow) {
      return [];
    }
    appendedAttachedRateRow = true;
    return ["rateAndBar"];
  });
}

export function embedsUsageStatusInRateRow(visibility: FloatingContentVisibility): boolean {
  if (!visibility.showRateAndBar || !visibility.showUsageStatus) {
    return false;
  }
  const visible = visibleFloatingContentGroups(visibility);
  const rateIndex = visible.indexOf("rateAndBar");
  const usageIndex = visible.indexOf("usageStatus");
  return rateIndex >= 0 && usageIndex >= 0 && Math.abs(rateIndex - usageIndex) === 1;
}

export function reorderFloatingContent(
  order: FloatingContentGroup[],
  dragged: FloatingContentGroup,
  target: FloatingContentGroup,
): FloatingContentGroup[] {
  if (dragged === target) {
    return sanitizeContentOrder(order);
  }
  const current = sanitizeContentOrder(order).filter((group) => group !== dragged);
  const targetIndex = current.indexOf(target);
  if (targetIndex < 0) {
    return sanitizeContentOrder(order);
  }
  current.splice(targetIndex, 0, dragged);
  return sanitizeContentOrder(current);
}

export function moveFloatingContent(
  order: FloatingContentGroup[],
  group: FloatingContentGroup,
  delta: -1 | 1,
): FloatingContentGroup[] {
  const current = sanitizeContentOrder(order);
  const index = current.indexOf(group);
  const targetIndex = index + delta;
  if (index < 0 || targetIndex < 0 || targetIndex >= current.length) {
    return current;
  }
  const next = [...current];
  [next[index], next[targetIndex]] = [next[targetIndex], next[index]];
  return sanitizeContentOrder(next);
}

export function floatingContentGap(
  upperGroup: FloatingContentGroup,
  lowerGroup: FloatingContentGroup,
): number {
  return upperGroup === "radar" && lowerGroup === "crowdRadar" ? 2 : 4;
}

export function floatingContentHeight(visibility: FloatingContentVisibility): number {
  const groups = layoutFloatingContentGroups(visibility);
  if (groups.length === 0) {
    return 88;
  }

  const rows = groups.map((group) => {
    switch (group) {
      case "rateAndBar":
        return 30;
      case "usageStatus":
        return 11;
      case "metrics":
        return 13;
      case "radar":
        return 26;
      case "crowdRadar":
        return 20;
      case "quota":
        return 16.5;
    }
  });
  const verticalPadding = 14;
  const gaps = groups.slice(1).reduce(
    (sum, group, index) => sum + floatingContentGap(groups[index], group),
    0,
  );
  return Math.max(88, Math.ceil(verticalPadding + gaps + rows.reduce((sum, height) => sum + height, 0)));
}

function visibleFloatingContentGroups(visibility: FloatingContentVisibility): FloatingContentGroup[] {
  return sanitizeContentOrder(visibility.order).filter((group) => showsGroup(visibility, group));
}

function showsGroup(visibility: FloatingContentVisibility, group: FloatingContentGroup): boolean {
  switch (group) {
    case "rateAndBar":
      return visibility.showRateAndBar;
    case "usageStatus":
      return visibility.showUsageStatus;
    case "metrics":
      return visibility.showMetrics;
    case "quota":
      return visibility.showQuota;
    case "radar":
      return visibility.showRadar;
    case "crowdRadar":
      return visibility.showCrowdRadar;
  }
}

function sanitizeContentOrder(value: unknown): FloatingContentGroup[] {
  const input = Array.isArray(value) ? value : [];
  const seen = new Set<FloatingContentGroup>();
  const decoded = input.filter((item): item is FloatingContentGroup => {
    if (!FLOATING_CONTENT_GROUPS.includes(item as FloatingContentGroup) || seen.has(item as FloatingContentGroup)) {
      return false;
    }
    seen.add(item as FloatingContentGroup);
    return true;
  });
  const result = [...decoded];
  for (const group of FLOATING_CONTENT_GROUPS.filter((item) => !seen.has(item))) {
    if (group === "crowdRadar" && result.includes("radar")) {
      result.splice(result.indexOf("radar") + 1, 0, group);
    } else {
      result.push(group);
    }
  }
  return result;
}
