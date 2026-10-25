import { useState } from "react";
import { CacheHitRanking } from "../components/CacheHitRanking";
import type {
  DashboardSnapshot,
  CodexHomeSourceToken,
} from "../types/dashboard";
import { useClientScope, amount } from "./useClientScope";
export function cacheCoverage(
  codex: { inputTokens: number; cachedInputTokens: number } | undefined,
  rows: {
    client: string;
    inputTokens: number;
    cacheReadTokens: number | null;
    cacheReadComplete?: boolean;
  }[],
  allowed: string[],
) {
  let input = allowed.includes("codex") ? (codex?.inputTokens ?? 0) : 0,
    cached = allowed.includes("codex") ? (codex?.cachedInputTokens ?? 0) : 0,
    unknownInput = 0;
  for (const row of rows) {
    if (!allowed.includes(row.client)) continue;
    if (
      row.cacheReadComplete === true &&
      row.cacheReadTokens !== null &&
      row.cacheReadTokens >= 0 &&
      row.cacheReadTokens <= row.inputTokens
    ) {
      input += row.inputTokens;
      cached += row.cacheReadTokens;
    } else unknownInput += row.inputTokens;
  }
  return {
    input,
    cached,
    unknownInput,
    ratio: input > 0 ? cached / input : null,
  };
}
export function ScopedClientCacheView({
  codex,
  sourceToken,
}: {
  codex: DashboardSnapshot;
  sourceToken?: CodexHomeSourceToken | null;
}) {
  const { allowed, snapshot } = useClientScope(),
    [showCodex, setShowCodex] = useState(false);
  const coverage = cacheCoverage(
    typeof codex.stats.totalInputTokens === "number" &&
      typeof codex.stats.totalCachedInputTokens === "number"
      ? {
          inputTokens: codex.stats.totalInputTokens,
          cachedInputTokens: codex.stats.totalCachedInputTokens,
        }
      : undefined,
    snapshot.summaries,
    allowed,
  );
  return (
    <section className="cache-hit-ranking integrated-cache">
      <header>
        <h3>缓存命中排行</h3>
        <small>本地累计 · 可比较输入加权</small>
      </header>
      <p>
        <strong>
          {coverage.ratio === null
            ? "—"
            : `${(coverage.ratio * 100).toFixed(1)}%`}
        </strong>
        <span>已知输入 {amount(coverage.input)}</span>
        {coverage.unknownInput > 0 && (
          <span>未参与计算 {amount(coverage.unknownInput)}</span>
        )}
      </p>
      <small>
        其他客户端暂无可靠的整轮排行；未提供缓存读数的请求不按未命中计算。
      </small>
      {allowed.includes("codex") && (
        <>
          <button
            aria-expanded={showCodex}
            onClick={() => setShowCodex((v) => !v)}
          >
            Codex 单轮明细 {showCodex ? "▴" : "▾"}
          </button>
          {showCodex && (
            <CacheHitRanking
              sourceToken={sourceToken}
              cacheUsage={codex.cacheUsage}
              legacyItems={codex.cacheHitRanking}
            />
          )}
        </>
      )}
    </section>
  );
}
