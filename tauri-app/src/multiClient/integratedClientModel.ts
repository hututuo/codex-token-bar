import type { ActivityDay } from "../types/usage";
import type { ClientTrendBucket } from "./multiClientProduct";
import { quotaWindowShortLabel } from "../utils/quota";
import type { ClientQuotaReading } from "./multiClientProduct";
import type { QuotaSnapshot } from "../types/quota";
export const clientBrand: Record<string, string> = {
  codex: "#3941FF",
  claudeCode: "#D97757",
  claudeDesktop: "#D97757",
  gemini: "#4796E4",
  deepseek: "#4D6BFE",
  opencode: "#B7B1B1",
};
// Match the existing Windows sidebar's 49px rate/task rings.
export const clientSidebarMetrics = { ringSize: 49, capWidth: 4, capHeight: 2, capGap: 0 } as const;
export function quotaFill(item: Pick<QuotaItem, "window">): string {
  return item.window === "5h" ? "#B6EF75" : item.window === "7d" ? "#B4ACFF" : "#78B7FF";
}
export function quotaWindowTitle(window: string): string {
  return window === "5h" ? "5小时" : window === "7d" ? "7天" : window;
}
export function quotaTrackHeight(total: number): number {
  return Math.max(2, total);
}
export const scopeKey = "multiClient.displayScope.v1";
export function scopeClients(raw: string, available: string[]): string[] {
  return raw === "all"
    ? [...new Set(["codex", ...available])]
    : raw === "codex" || Object.hasOwn(clientBrand, raw)
      ? [raw]
      : ["codex"];
}
export interface QuotaItem {
  id: string;
  client: string;
  window: string;
  remaining: number | null;
  resetsAt: string | null;
  source: string;
  status: string;
}
export function quotaItems(
  codex: QuotaSnapshot | undefined,
  claude: ClientQuotaReading,
  includeClaude: boolean,
  includeFive = false,
): QuotaItem[] {
  const items: QuotaItem[] = [];
  function add(
    id: string,
    window: string,
    v: QuotaSnapshot["sevenDay"] | undefined,
  ) {
    const remaining =
      v?.availability === "measured" &&
      typeof v.remainingPercent === "number" &&
      Number.isFinite(v.remainingPercent)
        ? Math.max(0, Math.min(100, v.remainingPercent * 100))
        : null;
    items.push({
      id: `codex:${id}`,
      client: "codex",
      window,
      remaining,
      resetsAt: v?.resetsAtUnix
        ? new Date(v.resetsAtUnix * 1000).toISOString()
        : v?.resetsAt && Number.isFinite(Date.parse(v.resetsAt))
          ? v.resetsAt
          : null,
      source: "Codex 现有额度观测",
      status: remaining === null ? "不可用" : "",
    });
  }
  if (
    codex?.fiveHour &&
    ((codex.fiveHour.availability === "measured" &&
      codex.fiveHour.remainingPercent !== null &&
      Number.isFinite(codex.fiveHour.remainingPercent)) ||
      (includeFive && codex.fiveHour.availability !== "absent"))
  )
    add("5h", "5h", codex.fiveHour);
  add("7d", "7d", codex?.sevenDay);
  codex?.reserveWindows?.forEach((w) =>
    add(w.label, quotaWindowShortLabel(w.label), w),
  );
  if (includeClaude && claude.state === "available")
    ["5h", "7d"].forEach((label) => {
      const w = claude.windows.find((w) => w.label === label),
        u = w?.usedPercent;
      if (typeof u !== "number" || !Number.isFinite(u) || u < 0 || u > 100) return;
      items.push({
        id: `claudeCode:${label}`,
        client: "claudeCode",
        window: label,
        remaining: 100 - u,
        resetsAt: w?.resetsAt ?? null,
        source: "本地缓存 · 未绑定账号",
        status: "",
      });
    });
  return items;
}
export interface QuotaSelection {
  order: string[];
  hidden: string[];
  enabled: string[];
  colors: Record<string, string>;
  pairAcrossClients: boolean;
  length: "long" | "short" | "auto";
}
export const quotaSelectionKey = "multiClient.quotaSelection.v1";
export const defaultQuotaSelection: QuotaSelection = {
  order: [],
  hidden: [],
  enabled: [],
  colors: {},
  pairAcrossClients: false,
  length: "auto",
};
export function decodeQuotaSelection(raw: string | null): QuotaSelection {
  try {
    const v = JSON.parse(raw ?? "null");
    if (!v || typeof v !== "object") return defaultQuotaSelection;
    const ids = (a: unknown) =>
      Array.isArray(a)
        ? [...new Set(a.filter((id): id is string => typeof id === "string"))]
        : [];
    return {
      order: ids(v.order),
      hidden: ids(v.hidden),
      enabled: ids(v.enabled),
      pairAcrossClients: v.pairAcrossClients === true,
      colors: Object.fromEntries(
        Object.entries(v.colors ?? {}).filter(
          (entry): entry is [string, string] =>
            typeof entry[1] === "string" && /^#[0-9a-f]{6}$/i.test(entry[1]),
        ),
      ),
      length: v.length === "long" || v.length === "short" ? v.length : "auto",
    };
  } catch {
    return defaultQuotaSelection;
  }
}
export function orderedQuotaItems(
  items: QuotaItem[],
  s: QuotaSelection,
  allowed: string[],
  all = false,
) {
  return items
    .filter(
      (i) =>
        all ||
        ((allowed.includes(i.client) ||
          (i.client === "claudeCode" && allowed.includes("claudeDesktop"))) &&
          !s.hidden.includes(i.id) &&
          (i.client === "codex" ||
            i.client === "claudeCode" ||
            s.enabled.includes(i.id))),
    )
    .sort((a, b) => {
      const rank = (i: QuotaItem) => {
        const n = s.order.indexOf(i.id);
        return n < 0 ? 1e9 : n;
      };
      return rank(a) - rank(b);
    });
}
export function railLayout(
  quotaCount: number,
  mode: string,
  hasFive: boolean,
  availableHeight: number,
) {
  const count = Math.max(0, quotaCount) + 2,
    baseline = quotaCount >= 2 ? 250 : 192;
  const longHeight = count * 46 + (count - 1) * 12 + 30,
    short =
      mode === "short" || (mode !== "long" && longHeight > baseline * 1.25),
    bar = short ? 24 : 46,
    gap = short ? 8 : 12,
    preferred = count * bar + (count - 1) * gap + 30;
  const available = Math.max(
      30,
      Number.isFinite(availableHeight) ? availableHeight : baseline,
    ),
    ratio = Math.min(
      1,
      Math.max(0, (available - 30) / Math.max(1, preferred - 30)),
    ),
    barHeight = Math.max(8, bar * ratio),
    actualGap = Math.max(3, gap * ratio);
  return {
    barHeight,
    gap: actualGap,
    height: Math.min(
      available,
      count * barHeight + (count - 1) * actualGap + 30,
    ),
    short,
  };
}

const clientNamesForDays: Record<string,string> = {claudeCode:"Claude CLI",claudeDesktop:"Claude Desktop",gemini:"Gemini CLI",opencode:"OpenCode",deepseek:"DeepSeek / DSH"};

export function projectClientDays(
  codex: ActivityDay[],
  others: ClientTrendBucket[],
  allowed: string[],
): ActivityDay[] {
  const byDate = new Map<string, ActivityDay>();
  if (allowed.includes("codex")) codex.forEach(day => {
    const models = day.modelBreakdowns ?? [];
    const inputs = models.reduce((n,row)=>n+row.breakdown.inputTokens,0);
    byDate.set(day.date, {...day,
      cacheInputTokens: inputs || undefined,
      cacheReadTokens: inputs ? models.reduce((n,row)=>n+row.breakdown.cachedInputTokens,0) : undefined,
    });
  });
  others.filter(row => allowed.includes(row.client)).forEach(row => {
    const d = new Date(row.startUnix * 1000);
    const date = `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`;
    const old = byDate.get(date);
    const input = (old?.cacheInputTokens ?? 0) + row.inputTokens;
    const cached = (old?.cacheReadTokens ?? 0) + (row.cacheReadTokens ?? 0);
    const known = old?.cacheHitRateKnown !== false
      && !(old && old.tokens > 0 && old.cacheInputTokens === undefined)
      && (row.inputTokens === 0 || row.cacheReadTokens !== null && row.cacheReadTokens !== undefined);
    byDate.set(date, {
      ...old, date, tokens: (old?.tokens ?? 0) + row.inputTokens + row.outputTokens,
      calls: (old?.calls ?? 0) + row.requests,
      cacheInputTokens: input, cacheReadTokens: cached, cacheHitRateKnown: known,
      cacheHitRate: known && input > 0 ? cached/input : 0,
      fiveHourRemainingPercent: old?.fiveHourRemainingPercent ?? null,
      sevenDayRemainingPercent: old?.sevenDayRemainingPercent ?? null,
      // A client/time bucket has no model identity. Explicitly mark those tokens
      // unknown rather than pricing them with the user's Codex fallback model.
      modelBreakdowns: [...(old?.modelBreakdowns ?? []), {
        model: (clientNamesForDays[row.client] ?? row.client) + " · 模型明细未提供",
        eventStartUnix: row.startUnix,
        breakdown: {inputTokens: row.inputTokens, cachedInputTokens: row.cacheReadTokens ?? 0,
          outputTokens: row.outputTokens, totalTokens: row.inputTokens+row.outputTokens, calls: row.requests},
      }],
    });
  });
  return [...byDate.values()].sort((a,b)=>a.date.localeCompare(b.date));
}

export function quotaRingGroups(
  items: QuotaItem[],
  acrossClients = false,
): { left: QuotaItem; right?: QuotaItem }[] {
  const groups = acrossClients
    ? [items]
    : [...new Set(items.map((i) => i.client))].map((client) =>
        items.filter((i) => i.client === client),
      );
  return groups.flatMap((group) =>
    Array.from({ length: Math.ceil(group.length / 2) }, (_, index) => ({
      left: group[index * 2],
      right: group[index * 2 + 1],
    })),
  );
}
