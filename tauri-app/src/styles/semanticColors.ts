interface SemanticRgb {
  red: number;
  green: number;
  blue: number;
}

interface RadarScorePoint {
  passed: number;
  tasks: number;
  score: number;
}

const METRIC_STOPS: Array<{ percent: number; color: SemanticRgb }> = [
  { percent: 0, color: { red: 202, green: 60, blue: 73 } },
  { percent: 35, color: { red: 204, green: 139, blue: 38 } },
  { percent: 70, color: { red: 31, green: 158, blue: 94 } },
  { percent: 100, color: { red: 20, green: 105, blue: 204 } },
];

const ACCENT_COLORS = {
  red: semanticMetricColor(0),
  amber: semanticMetricColor(35),
  green: semanticMetricColor(70),
  blue: semanticMetricColor(100),
};

export function semanticMetricRgb(percent: number): SemanticRgb {
  const value = Number.isFinite(percent) ? Math.min(100, Math.max(0, percent)) : 0;
  const upperIndex = METRIC_STOPS.findIndex((stop) => value <= stop.percent);
  if (upperIndex <= 0) {
    return { ...METRIC_STOPS[0].color };
  }
  const lower = METRIC_STOPS[upperIndex - 1];
  const upper = METRIC_STOPS[upperIndex];
  const progress = (value - lower.percent) / (upper.percent - lower.percent);
  return {
    red: interpolateChannel(lower.color.red, upper.color.red, progress),
    green: interpolateChannel(lower.color.green, upper.color.green, progress),
    blue: interpolateChannel(lower.color.blue, upper.color.blue, progress),
  };
}

export function semanticMetricColor(percent: number): string {
  const { red, green, blue } = semanticMetricRgb(percent);
  return `rgb(${red} ${green} ${blue})`;
}

export function radarScorePercent(point: RadarScorePoint): number {
  if (Number.isFinite(point.tasks) && point.tasks > 0 && Number.isFinite(point.passed)) {
    return Math.min(100, Math.max(0, (point.passed / point.tasks) * 100));
  }
  return Math.min(100, Math.max(0, (Number.isFinite(point.score) ? point.score : 0) / 1.5));
}

export function radarScoreAccent(point: RadarScorePoint): string {
  return semanticMetricColor(radarScorePercent(point) * 0.7);
}

export function radarActionAccent(action: string | null | undefined): string {
  switch ((action ?? "").trim().toLowerCase().replace(/[\-_]+/g, " ").replace(/\s+/g, " ")) {
    case "wait":
    case "waiting":
    case "hold":
    case "等待":
    case "暂缓":
      return ACCENT_COLORS.amber;
    case "run":
    case "go":
    case "open":
    case "运行":
    case "可运行":
    case "开放":
      return ACCENT_COLORS.green;
    case "closed":
    case "关闭":
    case "use window":
    case "use windows":
    case "usewindow":
    case "usewindows":
    case "use remaining tokens":
    case "速登窗口":
      return ACCENT_COLORS.red;
    default:
      return ACCENT_COLORS.blue;
  }
}

export function quotaPaceAccent(label: string | null | undefined): string {
  const value = label?.trim() ?? "";
  if (/太快|先省|省着|别梭哈|告急|紧张|余量低|很低|不够烧|掉太快/.test(value)) {
    return ACCENT_COLORS.red;
  }
  if (/偏快|稍快|用得快/.test(value)) {
    return ACCENT_COLORS.amber;
  }
  if (/稳定|节奏很好|节奏稳|贴线|稳稳收官/.test(value)) {
    return ACCENT_COLORS.green;
  }
  return ACCENT_COLORS.blue;
}

function interpolateChannel(lower: number, upper: number, progress: number): number {
  return Math.round(lower + (upper - lower) * progress);
}
