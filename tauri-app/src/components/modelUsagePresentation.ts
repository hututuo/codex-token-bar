import { detectedOfficialAPIPriceModel } from "../settings/quotaPriceModel.ts";

export interface ModelUsageRowLike {
  model: string | null;
  eventStartUnix?: number;
  breakdown: {
    inputTokens: number;
    cachedInputTokens?: number;
    outputTokens: number;
    totalTokens?: number;
    calls: number;
  };
}

export interface ModelUsageSlice {
  key: string;
  label: string;
  tokens: number;
  calls: number;
  share: number;
  color: string;
}

const FIXED_COLORS: Record<string, string> = {
  "gpt-5.6-sol": "#2e6bfa",
  "gpt-5.6-terra": "#9252e6",
  "gpt-5.6-luna": "#00a3ad",
  "gpt-5.6-generic": "#7a879e",
  "gpt-5.4": "#f28f14",
  "gpt-5.4-mini": "#2eb35c",
  "gpt-5.3-codex": "#db4575",
  "gpt-5.3-codex-spark": "#f5b022",
  "gpt-5.2-codex": "#3d7fe0",
  unknown: "#7a879e",
};

const FALLBACK_COLORS = ["#e85573", "#2694df", "#c76ed6", "#21ad8c", "#e67a29"];

export function modelUsageSlices(rows: ModelUsageRowLike[] | null | undefined): ModelUsageSlice[] {
  const grouped = new Map<string, { model: string | null; tokens: number; calls: number }>();
  for (const row of rows ?? []) {
    const tokens = Number.isFinite(row?.breakdown?.totalTokens)
      ? finiteNonnegative(row.breakdown.totalTokens)
      : finiteNonnegative(row?.breakdown?.inputTokens) + finiteNonnegative(row?.breakdown?.outputTokens);
    if (tokens <= 0) continue;
    const key = modelUsageKey(row.model, row.eventStartUnix);
    const current = grouped.get(key) ?? { model: row.model, tokens: 0, calls: 0 };
    current.tokens += tokens;
    current.calls += finiteNonnegative(row?.breakdown?.calls);
    grouped.set(key, current);
  }
  const total = [...grouped.values()].reduce((sum, row) => sum + row.tokens, 0);
  if (total <= 0) return [];
  return [...grouped.entries()]
    .map(([key, row]) => ({
      key,
      label: modelUsageLabel(key),
      tokens: row.tokens,
      calls: row.calls,
      share: row.tokens / total,
      color: modelUsageColor(key),
    }))
    .sort((left, right) => right.tokens - left.tokens || left.label.localeCompare(right.label));
}

export function modelUsageCompactText(
  rows: ModelUsageRowLike[] | null | undefined,
  limit = 3,
): string | null {
  const slices = modelUsageSlices(rows);
  if (slices.length === 0) return null;
  const visible = slices.slice(0, Math.max(limit, 1));
  const suffix = slices.length > visible.length ? ` · +${slices.length - visible.length}` : "";
  return visible.map((slice) => `${slice.label} ${Math.round(slice.share * 100)}%`).join(" · ") + suffix;
}

export function dominantModelColor(rows: ModelUsageRowLike[] | null | undefined): string | null {
  return modelUsageSlices(rows)[0]?.color ?? null;
}

export function modelUsageKey(model: string | null | undefined, eventStartUnix?: number): string {
  const normalized = (model ?? "").trim().toLowerCase().replaceAll("_", "-");
  if (!normalized) return "unknown";
  const compact = normalized.replace(/[^a-z0-9]/g, "");
  if (compact === "gpt53codexspark") return "gpt-5.3-codex-spark";
  if (compact === "codexautoreview") {
    return detectedOfficialAPIPriceModel(model, eventStartUnix) === "gpt54Legacy"
      ? "gpt-5.4"
      : "gpt-5.6-luna";
  }
  if (compact === "gpt53codex") return "gpt-5.3-codex";
  if (compact === "gpt52codex") return "gpt-5.2-codex";
  // A bare GPT-5.6 slug does not identify the Sol/Terra/Luna lane. Keep it
  // visible as a generic model instead of silently attributing it to Sol.
  if (normalized === "gpt-5.6" || normalized === "gpt-5.6-generic") return "gpt-5.6-generic";
  if (normalized.includes("gpt-5.6")) {
    if (normalized.includes("luna")) return "gpt-5.6-luna";
    if (normalized.includes("terra")) return "gpt-5.6-terra";
    return "gpt-5.6-sol";
  }
  if (normalized.includes("gpt-5.4-mini")) return "gpt-5.4-mini";
  if (normalized.includes("gpt-5.4")) return "gpt-5.4";
  return normalized;
}

export function modelUsageLabel(model: string | null | undefined): string {
  switch (modelUsageKey(model)) {
    case "gpt-5.6-sol": return "Sol";
    case "gpt-5.6-terra": return "Terra";
    case "gpt-5.6-luna": return "Luna";
    case "gpt-5.6-generic": return "5.6（未分型）";
    case "gpt-5.4-mini": return "5.4 m";
    case "gpt-5.4": return "5.4";
    case "gpt-5.3-codex": return "5.3";
    case "gpt-5.3-codex-spark": return "Spark";
    case "gpt-5.2-codex": return "5.2";
    case "unknown": return "未知模型";
    default: return model?.trim() || "未知模型";
  }
}

export function modelUsageColor(keyOrModel: string | null | undefined): string {
  const key = modelUsageKey(keyOrModel);
  const fixed = FIXED_COLORS[key];
  if (fixed) return fixed;
  let hash = 0x811c9dc5;
  for (const char of key) {
    hash ^= char.codePointAt(0) ?? 0;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return FALLBACK_COLORS[hash % FALLBACK_COLORS.length];
}

function finiteNonnegative(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? Math.max(value, 0) : 0;
}
