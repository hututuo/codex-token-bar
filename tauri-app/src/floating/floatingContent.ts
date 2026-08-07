import type {
  FloatingContentGroup,
  FloatingContentPagePair,
  FloatingContentVisibility,
} from "../types/dashboard";

export const FLOATING_CONTENT_GROUPS: FloatingContentGroup[] = [
  "rateAndBar",
  "usageStatus",
  "metrics",
  "runningThreads",
  "todayModelShare",
  "todayModelCost",
  "radar",
  "crowdRadar",
  "quota",
];

export const FLOATING_PAGE_CAPABLE_GROUPS: FloatingContentGroup[] = [
  "metrics",
  "runningThreads",
  "todayModelShare",
  "todayModelCost",
  "radar",
  "crowdRadar",
  "quota",
];

export const DEFAULT_FLOATING_PAGE_PAIRS: FloatingContentPagePair[] = [
  ["todayModelShare", "todayModelCost"],
];

export const DEFAULT_FLOATING_CONTENT_VISIBILITY: FloatingContentVisibility = {
  showRateAndBar: true,
  showUsageStatus: true,
  showMetrics: true,
  showRunningThreads: true,
  showTodayModelShare: true,
  showTodayModelCost: true,
  showQuota: true,
  showRadar: true,
  showCrowdRadar: true,
  order: FLOATING_CONTENT_GROUPS,
  pagePairs: DEFAULT_FLOATING_PAGE_PAIRS,
};

export const FLOATING_CONTENT_LABELS: Record<FloatingContentGroup, { title: string; subtitle?: string }> = {
  rateAndBar: { title: "速率" },
  usageStatus: { title: "趣味话", subtitle: "靠近速率会吸附" },
  metrics: { title: "总今次" },
  runningThreads: { title: "运行线程", subtitle: "总数 / 主线程 / 子 Agent" },
  todayModelShare: { title: "今日模型占比", subtitle: "按今日 Token 统计" },
  todayModelCost: { title: "今日模型费用", subtitle: "真实模型与缓存价格" },
  radar: { title: "Radar" },
  crowdRadar: { title: "众测雷达" },
  quota: { title: "5h/7d" },
};

export function sanitizeFloatingContentVisibility(value: Partial<FloatingContentVisibility> | undefined): FloatingContentVisibility {
  return {
    showRateAndBar: value?.showRateAndBar ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showRateAndBar,
    showUsageStatus: value?.showUsageStatus ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showUsageStatus,
    showMetrics: value?.showMetrics ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showMetrics,
    showRunningThreads: value?.showRunningThreads ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showRunningThreads,
    showTodayModelShare: value?.showTodayModelShare ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showTodayModelShare,
    showTodayModelCost: value?.showTodayModelCost ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showTodayModelCost,
    showQuota: value?.showQuota ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showQuota,
    showRadar: value?.showRadar ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showRadar,
    showCrowdRadar: value?.showCrowdRadar ?? DEFAULT_FLOATING_CONTENT_VISIBILITY.showCrowdRadar,
    order: sanitizeContentOrder(value?.order),
    pagePairs: sanitizeFloatingPagePairs(value?.pagePairs),
  };
}

export interface FloatingContentLayoutRow {
  id: string;
  groups: FloatingContentGroup[];
  primaryGroup: FloatingContentGroup;
}

export function layoutFloatingContentRows(visibility: FloatingContentVisibility): FloatingContentLayoutRow[] {
  const groups = layoutFloatingContentGroups(visibility);
  const available = new Set(groups);
  const pairs = sanitizeFloatingPagePairs(visibility.pagePairs)
    .filter(([first, second]) => available.has(first) && available.has(second));
  const consumed = new Set<FloatingContentGroup>();
  const rows: FloatingContentLayoutRow[] = [];
  for (const group of groups) {
    if (consumed.has(group)) continue;
    const pair = pairs.find(([first, second]) => first === group || second === group);
    if (pair) {
      consumed.add(pair[0]);
      consumed.add(pair[1]);
      rows.push({ id: pair.join("|"), groups: [...pair], primaryGroup: pair[0] });
    } else {
      consumed.add(group);
      rows.push({ id: group, groups: [group], primaryGroup: group });
    }
  }
  return rows;
}

export function sanitizeFloatingPagePairs(value: unknown): FloatingContentPagePair[] {
  const input = Array.isArray(value) ? value : DEFAULT_FLOATING_PAGE_PAIRS;
  const used = new Set<FloatingContentGroup>();
  const result: FloatingContentPagePair[] = [];
  for (const candidate of input) {
    if (!Array.isArray(candidate) || candidate.length !== 2) continue;
    const [first, second] = candidate as FloatingContentGroup[];
    if (
      first === second
      || !FLOATING_PAGE_CAPABLE_GROUPS.includes(first)
      || !FLOATING_PAGE_CAPABLE_GROUPS.includes(second)
      || used.has(first)
      || used.has(second)
    ) continue;
    used.add(first);
    used.add(second);
    result.push([first, second]);
  }
  return result;
}

export function replaceFloatingPagePartner(
  pairs: FloatingContentPagePair[],
  group: FloatingContentGroup,
  partner: FloatingContentGroup | null,
): FloatingContentPagePair[] {
  const next = sanitizeFloatingPagePairs(pairs).filter(
    (pair) => !pair.includes(group) && (partner === null || !pair.includes(partner)),
  );
  if (
    partner !== null
    && partner !== group
    && FLOATING_PAGE_CAPABLE_GROUPS.includes(group)
    && FLOATING_PAGE_CAPABLE_GROUPS.includes(partner)
  ) next.push([group, partner]);
  return sanitizeFloatingPagePairs(next);
}

export function swapFloatingDefaultPage(
  pairs: FloatingContentPagePair[],
  group: FloatingContentGroup,
): FloatingContentPagePair[] {
  return sanitizeFloatingPagePairs(pairs).map(([first, second]) => (
    second === group ? [second, first] : [first, second]
  ));
}

export function layoutFloatingContentGroups(visibility: FloatingContentVisibility): FloatingContentGroup[] {
  let groups = visibleFloatingContentGroups(visibility);
  if (embedsUsageStatusInRateRow(visibility)) {
    groups = collapseAdjacentPair(groups, "rateAndBar", "usageStatus", "rateAndBar");
  }
  if (embedsRunningThreadsInMetricsRow(visibility)) {
    groups = collapseAdjacentPair(groups, "metrics", "runningThreads", "metrics");
  }
  return groups;
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

export function embedsRunningThreadsInMetricsRow(visibility: FloatingContentVisibility): boolean {
  if (!visibility.showMetrics || !visibility.showRunningThreads) {
    return false;
  }
  const visible = visibleFloatingContentGroups(visibility);
  const metricsIndex = visible.indexOf("metrics");
  const runningIndex = visible.indexOf("runningThreads");
  return metricsIndex >= 0 && runningIndex >= 0 && Math.abs(metricsIndex - runningIndex) === 1;
}

function collapseAdjacentPair(
  groups: FloatingContentGroup[],
  first: FloatingContentGroup,
  second: FloatingContentGroup,
  representative: FloatingContentGroup,
): FloatingContentGroup[] {
  let appendedRepresentative = false;
  return groups.flatMap((group) => {
    if (group !== first && group !== second) {
      return [group];
    }
    if (appendedRepresentative) {
      return [];
    }
    appendedRepresentative = true;
    return [representative];
  });
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
  const rows = layoutFloatingContentRows(visibility);
  if (rows.length === 0) {
    return 88;
  }

  const rowHeights = rows.map((row) => Math.max(...row.groups.map((group) => {
    switch (group) {
      case "rateAndBar":
        return 30;
      case "usageStatus":
        return 11;
      case "metrics":
        return 13;
      case "runningThreads":
        return 13;
      case "todayModelShare":
      case "todayModelCost":
        return 20;
      case "radar":
        return 26;
      case "crowdRadar":
        return 20;
      case "quota":
        return 16.5;
    }
  })));
  const verticalPadding = 14;
  const gaps = rows.slice(1).reduce(
    (sum, row, index) => sum + floatingContentGap(rows[index].primaryGroup, row.primaryGroup),
    0,
  );
  return Math.max(88, Math.ceil(verticalPadding + gaps + rowHeights.reduce((sum, height) => sum + height, 0)));
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
    case "runningThreads":
      return visibility.showRunningThreads;
    case "todayModelShare":
      return visibility.showTodayModelShare;
    case "todayModelCost":
      return visibility.showTodayModelCost;
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
    if (group === "runningThreads" && result.includes("metrics")) {
      result.splice(result.indexOf("metrics") + 1, 0, group);
    } else if (group === "todayModelShare" && result.includes("runningThreads")) {
      result.splice(result.indexOf("runningThreads") + 1, 0, group);
    } else if (group === "todayModelCost" && result.includes("todayModelShare")) {
      result.splice(result.indexOf("todayModelShare") + 1, 0, group);
    } else if (group === "crowdRadar" && result.includes("radar")) {
      result.splice(result.indexOf("radar") + 1, 0, group);
    } else {
      result.push(group);
    }
  }
  return result;
}
