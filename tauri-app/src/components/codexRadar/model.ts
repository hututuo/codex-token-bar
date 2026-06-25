export interface CodexRadarSnapshot {
  schemaVersion: string;
  service: string;
  monitoredAt: string;
  timezone: string;
  windowOpen: boolean;
  status: string;
  recommendedAction: string;
  window: CodexRadarWindow;
  prediction: CodexRadarPrediction;
  tiboPresence?: CodexRadarTiboPresence | null;
  recentWindows: CodexRadarRecentWindow[];
  links: CodexRadarLinks;
  modelIq: CodexRadarModelIQ;
  codexEnvironment: CodexRadarEnvironment;
}

export interface CodexRadarWindow {
  open: boolean;
  status: string;
  action: string;
  message: string;
  title: string;
  scope: string;
  openedAt?: string | null;
  closedAt?: string | null;
  sourceUrl?: string | null;
}

export interface CodexRadarPrediction {
  level: string;
  probability24H?: number;
  probability48H?: number;
  probability24h?: number;
  probability48h?: number;
  expectedWindow: string;
  summary: string;
  summaryEn?: string | null;
  positiveSignals: string[];
  negativeSignals: string[];
  updatedAt: string;
}

export interface CodexRadarTiboPresence {
  locationLabelZh?: string | null;
  locationLabelEn?: string | null;
  probability?: number;
  confidence?: string | null;
  safetyNoteZh?: string | null;
  shouldDisplay?: boolean;
  observationsConsidered?: number;
}

export interface CodexRadarRecentWindow {
  title?: string | null;
  status?: string | null;
  openedAt?: string | null;
  closedAt?: string | null;
  sourceUrl?: string | null;
}

export interface CodexRadarLinks {
  html: string;
  rss: string;
}

export interface CodexRadarModelIQ {
  latest: CodexRadarModelIQPoint;
  recentDays: CodexRadarModelIQPoint[];
  comparisons: Record<string, CodexRadarModelIQComparison>;
  quotaCalibration?: CodexRadarQuotaCalibration | null;
  quotaRadar?: CodexRadarQuotaRadar | null;
  quotaCheck?: CodexRadarQuotaCheck | null;
}

export interface CodexRadarModelIQComparison {
  label: string;
  model: string;
  reasoningEffort: string;
  latest: CodexRadarModelIQPoint;
  recentDays: CodexRadarModelIQPoint[];
}

export interface CodexRadarModelIQPoint {
  date: string;
  score: number;
  status: string;
  passed: number;
  tasks: number;
  invalid: number;
  validTasks: number;
  totalTokens: number;
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
  wallSeconds: number;
  wallTimeHuman: string;
  model?: string | null;
  reasoningEffort?: string | null;
  costUsd?: number | null;
}

export interface CodexRadarModelIQComparisonRow {
  label: string;
  point: CodexRadarModelIQPoint;
}

export interface CodexRadarChartSeries {
  id: string;
  label: string;
  points: CodexRadarChartPoint[];
}

export interface CodexRadarChartPoint {
  rawLabel: string;
  xLabel: string;
  value: number;
}

export type CodexRadarQuotaWindow = "fiveHour" | "sevenDay";

export interface CodexRadarQuotaRadar {
  date: string;
  source: string;
  updatedAt: string;
  basisDate: string;
  costUsd: number;
  totalTokens: number;
  basisWindow: string;
  basisWindowLabel: string;
  adjustedDelta: number;
  rawDelta: number;
  offset: number;
  rate: number;
  rows: CodexRadarQuotaRow[];
  trend: CodexRadarQuotaTrendPoint[];
}

export interface CodexRadarQuotaRow {
  tier: string;
  basis: string;
  fiveH: number;
  sevenD: number;
}

export interface CodexRadarQuotaCalibration {
  date: string;
  source: string;
  status: string;
  primaryWindow?: string | null;
  globalConcurrency?: number;
  checkedAtBefore?: string | null;
  checkedAtAfter?: string | null;
  tasks?: number;
  validTasks?: number;
  costUsd?: number;
  totalTokens?: number;
}

export interface CodexRadarQuotaTrendPoint {
  date: string;
  source: string;
  updatedAt: string;
  fiveHour20x: number;
  sevenDay20x: number;
  fiveHour5x: number;
  fiveHourPlus: number;
  basisWindow: string;
  basisWindowLabel: string;
  rate: number;
  rawDelta: number;
  adjustedDelta: number;
  offset: number;
  costUsd: number;
  totalTokens: number;
}

export interface CodexRadarQuotaCheck {
  date?: string | null;
  source?: string | null;
  status?: string | null;
  checkedAt?: string | null;
  planType?: string | null;
  rateLimitResetCreditsAvailableCount?: number;
  limitReached?: boolean;
  allowed?: boolean;
}

export interface CodexRadarEnvironment {
  schemaVersion: string;
  type: string;
  updatedAt: string;
  statusIncidents24H?: number;
  statusIncidents24h?: number;
  officialUpdates24H?: number;
  officialUpdates24h?: number;
  communityMentions24H?: number;
  communityMentions24h?: number;
  issueOrLimitAnomalies24H?: number;
  issueOrLimitAnomalies24h?: number;
  complaintPressure: string;
  resetCard?: CodexRadarResetCard | null;
  officialNews: CodexRadarNewsItem[];
  statusIncidents: CodexRadarNewsItem[];
  complaintExamples: CodexRadarComplaintExample[];
  roleCounts: Record<string, number>;
}

export interface CodexRadarResetCard {
  probability24H?: number;
  probability48H?: number;
  probability24h?: number;
  probability48h?: number;
  level: string;
  status: string;
  note: string;
}

export interface CodexRadarNewsItem {
  titleZh?: string | null;
  summaryZh?: string | null;
  summaryEn?: string | null;
  source?: string | null;
  account?: string | null;
  createdAt?: string | null;
  semanticRole?: string | null;
  url: string;
  text?: string | null;
}

export interface CodexRadarComplaintExample {
  summaryZh: string;
  summaryEn?: string | null;
  account: string;
  createdAt: string;
  url: string;
  semanticRole: string;
  predictionRelevance?: number;
}

export function normalizeCodexRadarSnapshot(raw: unknown): CodexRadarSnapshot {
  const source = asRecord(raw);
  const window = asRecord(read(source, "window"));
  const prediction = asRecord(read(source, "prediction"));
  const tiboPresence = asRecord(read(source, "tiboPresence", "tibo_presence"));
  const links = asRecord(read(source, "links"));
  const modelIq = asRecord(read(source, "modelIq", "model_iq"));
  const environment = asRecord(read(source, "codexEnvironment", "codex_environment"));

  return {
    schemaVersion: stringValue(read(source, "schemaVersion", "schema_version")),
    service: stringValue(read(source, "service")),
    monitoredAt: stringValue(read(source, "monitoredAt", "monitored_at")),
    timezone: stringValue(read(source, "timezone")),
    windowOpen: booleanValue(read(source, "windowOpen", "window_open")),
    status: stringValue(read(source, "status")),
    recommendedAction: stringValue(read(source, "recommendedAction", "recommended_action")),
    window: {
      open: booleanValue(read(window, "open")),
      status: stringValue(read(window, "status")),
      action: stringValue(read(window, "action")),
      message: stringValue(read(window, "message")),
      title: stringValue(read(window, "title")),
      scope: stringValue(read(window, "scope")),
      openedAt: nullableString(read(window, "openedAt", "opened_at")),
      closedAt: nullableString(read(window, "closedAt", "closed_at")),
      sourceUrl: nullableString(read(window, "sourceUrl", "source_url")),
    },
    prediction: {
      level: stringValue(read(prediction, "level")),
      probability24H: optionalNumber(read(prediction, "probability24H", "probability_24h")),
      probability48H: optionalNumber(read(prediction, "probability48H", "probability_48h")),
      probability24h: optionalNumber(read(prediction, "probability24h", "probability_24h")),
      probability48h: optionalNumber(read(prediction, "probability48h", "probability_48h")),
      expectedWindow: stringValue(read(prediction, "expectedWindow", "expected_window")),
      summary: stringValue(read(prediction, "summary")),
      summaryEn: nullableString(read(prediction, "summaryEn", "summary_en")),
      positiveSignals: stringArray(read(prediction, "positiveSignals", "positive_signals")),
      negativeSignals: stringArray(read(prediction, "negativeSignals", "negative_signals")),
      updatedAt: stringValue(read(prediction, "updatedAt", "updated_at")),
    },
    tiboPresence: Object.keys(tiboPresence).length > 0 ? {
      locationLabelZh: nullableString(read(tiboPresence, "locationLabelZh", "location_label_zh")),
      locationLabelEn: nullableString(read(tiboPresence, "locationLabelEn", "location_label_en")),
      probability: optionalNumber(read(tiboPresence, "probability")),
      confidence: nullableString(read(tiboPresence, "confidence")),
      safetyNoteZh: nullableString(read(tiboPresence, "safetyNoteZh", "safety_note_zh")),
      shouldDisplay: optionalBoolean(read(tiboPresence, "shouldDisplay", "should_display")),
      observationsConsidered: optionalNumber(read(tiboPresence, "observationsConsidered", "observations_considered")),
    } : null,
    recentWindows: arrayValue(read(source, "recentWindows", "recent_windows")).map(normalizeRecentWindow),
    links: {
      html: stringValue(read(links, "html"), "https://codexradar.com"),
      rss: stringValue(read(links, "rss"), "https://codexradar.com/feed.xml"),
    },
    modelIq: normalizeModelIq(modelIq),
    codexEnvironment: {
      schemaVersion: stringValue(read(environment, "schemaVersion", "schema_version")),
      type: stringValue(read(environment, "type")),
      updatedAt: stringValue(read(environment, "updatedAt", "updated_at")),
      statusIncidents24H: optionalNumber(read(environment, "statusIncidents24H", "status_incidents_24h")),
      statusIncidents24h: optionalNumber(read(environment, "statusIncidents24h", "status_incidents_24h")),
      officialUpdates24H: optionalNumber(read(environment, "officialUpdates24H", "official_updates_24h")),
      officialUpdates24h: optionalNumber(read(environment, "officialUpdates24h", "official_updates_24h")),
      communityMentions24H: optionalNumber(read(environment, "communityMentions24H", "community_mentions_24h")),
      communityMentions24h: optionalNumber(read(environment, "communityMentions24h", "community_mentions_24h")),
      issueOrLimitAnomalies24H: optionalNumber(read(environment, "issueOrLimitAnomalies24H", "issue_or_limit_anomalies_24h")),
      issueOrLimitAnomalies24h: optionalNumber(read(environment, "issueOrLimitAnomalies24h", "issue_or_limit_anomalies_24h")),
      complaintPressure: stringValue(read(environment, "complaintPressure", "complaint_pressure")),
      resetCard: normalizeResetCard(read(environment, "resetCard", "reset_card")),
      officialNews: arrayValue(read(environment, "officialNews", "official_news")).map(normalizeNewsItem),
      statusIncidents: arrayValue(read(environment, "statusIncidents", "status_incidents")).map(normalizeNewsItem),
      complaintExamples: arrayValue(read(environment, "complaintExamples", "complaint_examples")).map(normalizeComplaintExample),
      roleCounts: numberRecord(read(environment, "roleCounts", "role_counts")),
    },
  };
}

export function primaryModelRow(modelIq: CodexRadarModelIQ): CodexRadarModelIQComparisonRow {
  return [...allCurrentRows(modelIq)].sort(preferredModelOrder)[0] ?? {
    label: modelDisplayName(modelIq.latest),
    point: modelIq.latest,
  };
}

export function secondaryModelRows(modelIq: CodexRadarModelIQ): CodexRadarModelIQComparisonRow[] {
  const primary = primaryModelRow(modelIq);
  return allCurrentRows(modelIq)
    .filter((row) => modelSeriesID(row.point) !== modelSeriesID(primary.point))
    .sort(preferredModelOrder);
}

export function modelIqChartSeries(modelIq: CodexRadarModelIQ): CodexRadarChartSeries[] {
  const latestSeries: CodexRadarChartSeries = {
    id: modelSeriesID(modelIq.latest),
    label: modelDisplayName(modelIq.latest),
    points: (modelIq.recentDays.length > 0 ? modelIq.recentDays : [modelIq.latest]).map(modelPointToChartPoint),
  };

  const preferredOrder = ["GPT-5.5 high", "GPT-5.5 medium", "GPT-5.4 xhigh"];
  const comparisonSeries = Object.values(modelIq.comparisons ?? {})
    .map((comparison) => ({
      id: `${comparison.model}-${comparison.reasoningEffort}`,
      label: comparison.label,
      points: (comparison.recentDays.length > 0 ? comparison.recentDays : [comparison.latest]).map(modelPointToChartPoint),
    }))
    .sort((lhs, rhs) => {
      const lhsIndex = preferredOrder.indexOf(lhs.label);
      const rhsIndex = preferredOrder.indexOf(rhs.label);
      const normalizedLhs = lhsIndex === -1 ? Number.MAX_SAFE_INTEGER : lhsIndex;
      const normalizedRhs = rhsIndex === -1 ? Number.MAX_SAFE_INTEGER : rhsIndex;
      return normalizedLhs === normalizedRhs ? lhs.label.localeCompare(rhs.label) : normalizedLhs - normalizedRhs;
    });

  return [latestSeries, ...comparisonSeries];
}

export function quotaChartSeries(quotaRadar: CodexRadarQuotaRadar, window: CodexRadarQuotaWindow): CodexRadarChartSeries[] {
  return [
    {
      id: "quota-plus",
      label: "Plus",
      points: quotaRadar.trend.map((point) => quotaPointToChartPoint(point, valueForQuotaTier(point, window, "plus"))),
    },
    {
      id: "quota-5x",
      label: "5x Pro",
      points: quotaRadar.trend.map((point) => quotaPointToChartPoint(point, valueForQuotaTier(point, window, "fiveX"))),
    },
    {
      id: "quota-20x",
      label: "20x Pro",
      points: quotaRadar.trend.map((point) => quotaPointToChartPoint(point, valueForQuotaTier(point, window, "twentyX"))),
    },
  ];
}

export function modelDisplayName(point: CodexRadarModelIQPoint): string {
  const model = point.model?.toUpperCase() ?? "MODEL";
  return point.reasoningEffort ? `${model} ${point.reasoningEffort}` : model;
}

export function shortDateLabel(raw: string): string {
  const trimmed = raw
    .replace("2026-06-", "6.")
    .replace("-am", " am")
    .replace("-pm", " pm");
  return trimmed.startsWith("2026-") ? trimmed.slice(5) : trimmed;
}

export function displayRadarNumber(value: number, fractionDigits = 1): string {
  return Number.isInteger(value) ? `${value}` : value.toFixed(fractionDigits);
}

export function percentText(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return "--";
  }
  return `${Math.round(value * 100)}%`;
}

export function environmentCount(
  environment: CodexRadarEnvironment | undefined,
  key: "statusIncidents" | "officialUpdates" | "communityMentions" | "issueOrLimitAnomalies",
): number {
  if (!environment) {
    return 0;
  }
  const upperKey = `${key}24H` as keyof CodexRadarEnvironment;
  const lowerKey = `${key}24h` as keyof CodexRadarEnvironment;
  const value = environment[upperKey] ?? environment[lowerKey];
  return typeof value === "number" ? value : 0;
}

function allCurrentRows(modelIq: CodexRadarModelIQ): CodexRadarModelIQComparisonRow[] {
  const rows: CodexRadarModelIQComparisonRow[] = [];
  if (modelIq.latest) {
    rows.push({ label: modelDisplayName(modelIq.latest), point: modelIq.latest });
  }
  rows.push(
    ...Object.values(modelIq.comparisons ?? {}).filter((comparison) => comparison.latest).map((comparison) => ({
      label: comparison.label,
      point: comparison.latest,
    })),
  );
  return rows;
}

function preferredModelOrder(lhs: CodexRadarModelIQComparisonRow, rhs: CodexRadarModelIQComparisonRow): number {
  if (lhs.point.score !== rhs.point.score) {
    return rhs.point.score - lhs.point.score;
  }

  const lhsCost = lhs.point.costUsd;
  const rhsCost = rhs.point.costUsd;
  if (lhsCost !== null && lhsCost !== undefined && rhsCost !== null && rhsCost !== undefined && lhsCost !== rhsCost) {
    return lhsCost - rhsCost;
  }
  if (lhsCost !== null && lhsCost !== undefined) {
    return -1;
  }
  if (rhsCost !== null && rhsCost !== undefined) {
    return 1;
  }

  const effortDelta = reasoningEffortCostRank(lhs.point.reasoningEffort) - reasoningEffortCostRank(rhs.point.reasoningEffort);
  return effortDelta !== 0 ? effortDelta : lhs.label.localeCompare(rhs.label);
}

function reasoningEffortCostRank(effort: string | null | undefined): number {
  switch (effort?.toLowerCase()) {
    case "minimal":
      return 0;
    case "low":
      return 1;
    case "medium":
      return 2;
    case "high":
      return 3;
    case "xhigh":
      return 4;
    default:
      return Number.MAX_SAFE_INTEGER;
  }
}

function modelSeriesID(point: CodexRadarModelIQPoint): string {
  return `${point.model ?? "model"}-${point.reasoningEffort ?? "default"}`;
}

function modelPointToChartPoint(point: CodexRadarModelIQPoint): CodexRadarChartPoint {
  return {
    rawLabel: point.date,
    xLabel: shortDateLabel(point.date),
    value: point.score,
  };
}

function quotaPointToChartPoint(point: CodexRadarQuotaTrendPoint, value: number): CodexRadarChartPoint {
  return {
    rawLabel: point.date,
    xLabel: shortDateLabel(point.date),
    value,
  };
}

function valueForQuotaTier(point: CodexRadarQuotaTrendPoint, window: CodexRadarQuotaWindow, tier: "plus" | "fiveX" | "twentyX"): number {
  if (window === "fiveHour") {
    switch (tier) {
      case "plus":
        return point.fiveHourPlus;
      case "fiveX":
        return point.fiveHour5x;
      case "twentyX":
        return point.fiveHour20x;
    }
  }

  switch (tier) {
    case "plus":
      return point.sevenDay20x / 20;
    case "fiveX":
      return point.sevenDay20x / 4;
    case "twentyX":
      return point.sevenDay20x;
  }
}

function normalizeModelIq(modelIq: Record<string, unknown>): CodexRadarModelIQ {
  const comparisons = asRecord(read(modelIq, "comparisons"));
  return {
    latest: normalizeModelPoint(read(modelIq, "latest")),
    recentDays: arrayValue(read(modelIq, "recentDays", "recent_days")).map(normalizeModelPoint),
    comparisons: Object.fromEntries(
      Object.entries(comparisons).map(([key, value]) => {
        const comparison = asRecord(value);
        return [key, {
          label: stringValue(read(comparison, "label")),
          model: stringValue(read(comparison, "model")),
          reasoningEffort: stringValue(read(comparison, "reasoningEffort", "reasoning_effort")),
          latest: normalizeModelPoint(read(comparison, "latest")),
          recentDays: arrayValue(read(comparison, "recentDays", "recent_days")).map(normalizeModelPoint),
        } satisfies CodexRadarModelIQComparison];
      }),
    ),
    quotaCalibration: normalizeQuotaCalibration(read(modelIq, "quotaCalibration", "quota_calibration")),
    quotaRadar: normalizeQuotaRadar(read(modelIq, "quotaRadar", "quota_radar")),
    quotaCheck: normalizeQuotaCheck(read(modelIq, "quotaCheck", "quota_check")),
  };
}

function normalizeModelPoint(raw: unknown): CodexRadarModelIQPoint {
  const point = asRecord(raw);
  return {
    date: stringValue(read(point, "date")),
    score: numberValue(read(point, "score")),
    status: stringValue(read(point, "status")),
    passed: numberValue(read(point, "passed")),
    tasks: numberValue(read(point, "tasks")),
    invalid: numberValue(read(point, "invalid")),
    validTasks: numberValue(read(point, "validTasks", "valid_tasks")),
    totalTokens: numberValue(read(point, "totalTokens", "total_tokens")),
    inputTokens: numberValue(read(point, "inputTokens", "input_tokens")),
    cachedInputTokens: numberValue(read(point, "cachedInputTokens", "cached_input_tokens")),
    outputTokens: numberValue(read(point, "outputTokens", "output_tokens")),
    wallSeconds: numberValue(read(point, "wallSeconds", "wall_seconds")),
    wallTimeHuman: stringValue(read(point, "wallTimeHuman", "wall_time_human")),
    model: nullableString(read(point, "model")),
    reasoningEffort: nullableString(read(point, "reasoningEffort", "reasoning_effort")),
    costUsd: optionalNumber(read(point, "costUsd", "cost_usd")),
  };
}

function normalizeQuotaRadar(raw: unknown): CodexRadarQuotaRadar | null {
  const radar = asRecord(raw);
  const rows = arrayValue(read(radar, "rows")).map((item) => {
    const row = asRecord(item);
    return {
      tier: stringValue(read(row, "tier")),
      basis: stringValue(read(row, "basis")),
      fiveH: numberValue(read(row, "fiveH", "five_h")),
      sevenD: numberValue(read(row, "sevenD", "seven_d")),
    };
  });
  return rows.length > 0 ? {
    date: stringValue(read(radar, "date")),
    source: stringValue(read(radar, "source")),
    updatedAt: stringValue(read(radar, "updatedAt", "updated_at")),
    basisDate: stringValue(read(radar, "basisDate", "basis_date")),
    costUsd: numberValue(read(radar, "costUsd", "cost_usd")),
    totalTokens: numberValue(read(radar, "totalTokens", "total_tokens")),
    basisWindow: stringValue(read(radar, "basisWindow", "basis_window")),
    basisWindowLabel: stringValue(read(radar, "basisWindowLabel", "basis_window_label")),
    adjustedDelta: numberValue(read(radar, "adjustedDelta", "adjusted_delta")),
    rawDelta: numberValue(read(radar, "rawDelta", "raw_delta")),
    offset: numberValue(read(radar, "offset")),
    rate: numberValue(read(radar, "rate")),
    rows,
    trend: arrayValue(read(radar, "trend")).map(normalizeQuotaTrendPoint),
  } : null;
}

function normalizeQuotaCalibration(raw: unknown): CodexRadarQuotaCalibration | null {
  const calibration = asRecord(raw);
  if (Object.keys(calibration).length === 0) {
    return null;
  }
  return {
    date: stringValue(read(calibration, "date")),
    source: stringValue(read(calibration, "source")),
    status: stringValue(read(calibration, "status")),
    primaryWindow: nullableString(read(calibration, "primaryWindow", "primary_window")),
    globalConcurrency: optionalNumber(read(calibration, "globalConcurrency", "global_concurrency")),
    checkedAtBefore: nullableString(read(calibration, "checkedAtBefore", "checked_at_before")),
    checkedAtAfter: nullableString(read(calibration, "checkedAtAfter", "checked_at_after")),
    tasks: optionalNumber(read(calibration, "tasks")),
    validTasks: optionalNumber(read(calibration, "validTasks", "valid_tasks")),
    costUsd: optionalNumber(read(calibration, "costUsd", "cost_usd")),
    totalTokens: optionalNumber(read(calibration, "totalTokens", "total_tokens")),
  };
}

function normalizeQuotaCheck(raw: unknown): CodexRadarQuotaCheck | null {
  const check = asRecord(raw);
  if (Object.keys(check).length === 0) {
    return null;
  }
  return {
    date: nullableString(read(check, "date")),
    source: nullableString(read(check, "source")),
    status: nullableString(read(check, "status")),
    checkedAt: nullableString(read(check, "checkedAt", "checked_at")),
    planType: nullableString(read(check, "planType", "plan_type")),
    rateLimitResetCreditsAvailableCount: optionalNumber(read(check, "rateLimitResetCreditsAvailableCount", "rate_limit_reset_credits_available_count")),
    limitReached: optionalBoolean(read(check, "limitReached", "limit_reached")),
    allowed: optionalBoolean(read(check, "allowed")),
  };
}

function normalizeQuotaTrendPoint(raw: unknown): CodexRadarQuotaTrendPoint {
  const point = asRecord(raw);
  return {
    date: stringValue(read(point, "date")),
    source: stringValue(read(point, "source")),
    updatedAt: stringValue(read(point, "updatedAt", "updated_at")),
    fiveHour20x: numberValue(read(point, "fiveHour20x", "fiveH20X", "five_h20x")),
    sevenDay20x: numberValue(read(point, "sevenDay20x", "sevenD20X", "seven_d20x")),
    fiveHour5x: numberValue(read(point, "fiveHour5x", "fiveH5X", "five_h5x")),
    fiveHourPlus: numberValue(read(point, "fiveHourPlus", "fiveHPlus", "five_h_plus")),
    basisWindow: stringValue(read(point, "basisWindow", "basis_window")),
    basisWindowLabel: stringValue(read(point, "basisWindowLabel", "basis_window_label")),
    rate: numberValue(read(point, "rate")),
    rawDelta: numberValue(read(point, "rawDelta", "raw_delta")),
    adjustedDelta: numberValue(read(point, "adjustedDelta", "adjusted_delta")),
    offset: numberValue(read(point, "offset")),
    costUsd: numberValue(read(point, "costUsd", "cost_usd")),
    totalTokens: numberValue(read(point, "totalTokens", "total_tokens")),
  };
}

function normalizeRecentWindow(raw: unknown): CodexRadarRecentWindow {
  const window = asRecord(raw);
  return {
    title: nullableString(read(window, "title")),
    status: nullableString(read(window, "status")),
    openedAt: nullableString(read(window, "openedAt", "opened_at")),
    closedAt: nullableString(read(window, "closedAt", "closed_at")),
    sourceUrl: nullableString(read(window, "sourceUrl", "source_url")),
  };
}

function normalizeResetCard(raw: unknown): CodexRadarResetCard | null {
  const card = asRecord(raw);
  if (Object.keys(card).length === 0) {
    return null;
  }
  return {
    probability24H: optionalNumber(read(card, "probability24H", "probability_24h")),
    probability48H: optionalNumber(read(card, "probability48H", "probability_48h")),
    probability24h: optionalNumber(read(card, "probability24h", "probability_24h")),
    probability48h: optionalNumber(read(card, "probability48h", "probability_48h")),
    level: stringValue(read(card, "level")),
    status: stringValue(read(card, "status")),
    note: stringValue(read(card, "note")),
  };
}

function normalizeNewsItem(raw: unknown): CodexRadarNewsItem {
  const item = asRecord(raw);
  return {
    titleZh: nullableString(read(item, "titleZh", "title_zh")),
    summaryZh: nullableString(read(item, "summaryZh", "summary_zh")),
    summaryEn: nullableString(read(item, "summaryEn", "summary_en")),
    source: nullableString(read(item, "source")),
    account: nullableString(read(item, "account")),
    createdAt: nullableString(read(item, "createdAt", "created_at")),
    semanticRole: nullableString(read(item, "semanticRole", "semantic_role")),
    url: stringValue(read(item, "url")),
    text: nullableString(read(item, "text")),
  };
}

function normalizeComplaintExample(raw: unknown): CodexRadarComplaintExample {
  const item = asRecord(raw);
  return {
    summaryZh: stringValue(read(item, "summaryZh", "summary_zh")),
    summaryEn: nullableString(read(item, "summaryEn", "summary_en")),
    account: stringValue(read(item, "account")),
    createdAt: stringValue(read(item, "createdAt", "created_at")),
    url: stringValue(read(item, "url")),
    semanticRole: stringValue(read(item, "semanticRole", "semantic_role")),
    predictionRelevance: optionalNumber(read(item, "predictionRelevance", "prediction_relevance")),
  };
}

function read(record: Record<string, unknown>, ...keys: string[]): unknown {
  for (const key of keys) {
    if (Object.prototype.hasOwnProperty.call(record, key)) {
      return record[key];
    }
  }
  return undefined;
}

function asRecord(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function stringArray(value: unknown): string[] {
  return arrayValue(value).filter((item): item is string => typeof item === "string");
}

function stringValue(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

function nullableString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function numberValue(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function optionalNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function booleanValue(value: unknown): boolean {
  return typeof value === "boolean" ? value : false;
}

function optionalBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function numberRecord(value: unknown): Record<string, number> {
  const record = asRecord(value);
  return Object.fromEntries(
    Object.entries(record).filter((entry): entry is [string, number] => typeof entry[1] === "number" && Number.isFinite(entry[1])),
  );
}
