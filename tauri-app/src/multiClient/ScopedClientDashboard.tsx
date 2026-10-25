import { clientMoney } from "./clientMoney";
import {
  floatingTodayModelUsageItems,
  floatingModelUsageKnownCostUSD,
} from "../floating/floatingModelUsage";
import { ScopedClientCacheView } from "./ScopedClientCacheView";
import { useMemo, useState, type ReactNode } from "react";
import { useClientScope, clientTitle, amount, value } from "./useClientScope";
import { ClientDashboardQuotaStrip } from "./ClientQuotaViews";
import { useClientQuotaItems } from "./useClientScope";
import { MultiClientDiscoveryNotice } from "./MultiClientUsage";
import { clientBrand, projectClientDays } from "./integratedClientModel";
import { TokenActivitySection } from "../components/TokenActivitySection";
import { referencePrice } from "./clientReferencePrice";
import { projectClientChart } from "./multiClientProduct";
import type {
  DashboardSnapshot,
  CodexHomeSourceToken,
} from "../types/dashboard";
export function ClientScopeSelector() {
  const { raw, setScope, available } = useClientScope();
  return (
    <div className="integrated-scope">
      <nav aria-label="统计客户端范围">
        {["codex", ...available, "all"].map((id) => (
          <button
            type="button"
            key={id}
            aria-pressed={raw === id}
            onClick={() => setScope(id)}
          >
            {id !== "all" && <i style={{ background: clientBrand[id] }} />}
            {clientTitle(id)}
          </button>
        ))}
      </nav>
      <MultiClientDiscoveryNotice />
    </div>
  );
}

export function ScopedClientDashboard({
  codex,
  codexSpeed,
  sourceToken,
}: {
  codex: DashboardSnapshot;
  sourceToken?: CodexHomeSourceToken | null;
  codexSpeed?: ReactNode;
}) {
  const { allowed, snapshot } = useClientScope(),
    { items } = useClientQuotaItems(codex.quota),
    [days, setDays] = useState(1),
    [split, setSplit] = useState(false),
    [hover, setHover] = useState<number | null>(null);
  const rows = snapshot.summaries.filter((s) => allowed.includes(s.client)),
    includesCodex = allowed.includes("codex");
  const total =
      rows.reduce((n, s) => n + s.inputTokens + s.outputTokens, 0) +
      (includesCodex ? codex.stats.totalTokens : 0),
    input =
      rows.reduce((n, s) => n + s.inputTokens, 0) +
      (includesCodex ? (codex.stats.totalInputTokens ?? 0) : 0),
    output =
      rows.reduce((n, s) => n + s.outputTokens, 0) +
      (includesCodex ? (codex.stats.totalOutputTokens ?? 0) : 0),
    now = Date.now() / 1000;
  const points = useMemo(
    () =>
      projectClientChart(
        codex.recentUsage24h,
        snapshot.trendBuckets ?? [],
        days,
        now,
        allowed,
      ),
    [
      codex,
      snapshot.trendBuckets,
      days,
      Math.floor(now / 60),
      allowed.join(","),
    ],
  );
  const times = [...new Set(points.map((p) => p.startUnix))],
    series = split ? allowed : ["all"],
    byTime = new Map<number, number>();
  points.forEach((p) =>
    byTime.set(p.startUnix, (byTime.get(p.startUnix) ?? 0) + p.tokens),
  );
  const maximum = Math.max(
    1,
    ...points.map((p) => p.tokens),
    ...byTime.values(),
  );
  const path = (client: string) => {
    const values =
      client === "all"
        ? times.map((t) => ({ startUnix: t, tokens: byTime.get(t) ?? 0 }))
        : points.filter((p) => p.client === client);
    return values
      .map(
        (p, i) =>
          `${i ? "L" : "M"}${40 + (i * 840) / Math.max(1, times.length - 1)},${225 - (p.tokens / maximum) * 195}`,
      )
      .join(" ");
  };
  const codexCost = (
    row: NonNullable<typeof codex.stats.modelBreakdowns>[number],
  ) =>
    row.model
      ? floatingModelUsageKnownCostUSD(
          floatingTodayModelUsageItems([row], "gpt56Sol", {
            showPlaceholders: false,
          }),
        )
      : null;
  const knownCosts = [
    ...rows.flatMap((row) =>
      typeof row.apiCostUSD === "number" ? [row.apiCostUSD] : [],
    ),
    ...(includesCodex
      ? (codex.stats.modelBreakdowns ?? []).flatMap((row) => {
          const cost = codexCost(row);
          return cost === null ? [] : [cost];
        })
      : []),
  ];
  const unpricedRequests = rows.reduce(
    (total, row) =>
      total +
      (row.unpricedRequests ?? (row.apiCostUSD == null ? row.requests : 0)),
    0,
  );
  return (
    <>
      <ClientDashboardQuotaStrip items={items} />
      <section className="stats-overview-card integrated-stats">
        <div className="integrated-stat-metrics">
          {[
            ["累计 Token 数", total],
            ["输入 Token", input],
            ["输出 Token", output],
          ].map(([label, n]) => (
            <div key={label}>
              <strong>{amount(Number(n))}</strong>
              <small>{label}</small>
            </div>
          ))}
          <div>
            <strong>部分</strong>
            <small>本地已记录</small>
          </div>
        </div>
        <h3>
          模型 / API 等值 · 累计已记录{" "}
          <small>
            已知小计{" "}
            {clientMoney(
              knownCosts.length
                ? knownCosts.reduce((sum, cost) => sum + cost, 0)
                : null,
            )}
          </small>
        </h3>
        <table>
          <thead>
            <tr>
              <th>客户端 · 模型</th>
              <th>Token</th>
              <th>缓存读 / 写</th>
              <th>标准 API 等值</th>
            </tr>
          </thead>
          <tbody>
            {includesCodex &&
              codex.stats.modelBreakdowns?.map((row, index) => (
                <tr key={`codex:${index}`}>
                  <td>Codex · {row.model ?? "未知模型"}</td>
                  <td>{amount(row.breakdown.totalTokens)}</td>
                  <td>{amount(row.breakdown.cachedInputTokens)} / —</td>
                  <td
                    title={`参考单价（输入/输出，每百万 Token） ${referencePrice(row.model ?? "")}`}
                  >
                    {clientMoney(codexCost(row))}
                  </td>
                </tr>
              ))}
            {rows.map((row) => (
              <tr key={`${row.client}:${row.model}`}>
                <td>
                  {clientTitle(row.client)} · {row.model}
                </td>
                <td>{amount(row.inputTokens + row.outputTokens)}</td>
                <td>
                  {row.cacheReadTokens === null
                    ? "—"
                    : amount(row.cacheReadTokens)}{" "}
                  /{" "}
                  {row.cacheWriteTokens === null
                    ? "—"
                    : amount(row.cacheWriteTokens)}
                </td>
                <td
                  title={`参考单价（输入/输出，每百万 Token） ${referencePrice(row.model)}`}
                >
                  {clientMoney(row.apiCostUSD)}
                  {(row.unpricedRequests ?? 0) > 0 && <small>部分未计价</small>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <small>
          标准 API 价估算 · 缓存与思考不重复累加 · 不是订阅扣费记录。
          {unpricedRequests > 0 &&
            ` ${unpricedRequests} 次请求因价目规则或用量字段不足，未计入金额。`}
        </small>
      </section>
      {codexSpeed ? (
        <>
          <small>Codex · 当前正文与活动速率采样范围</small>
          {codexSpeed}
        </>
      ) : (
        <section className="live-card integrated-speed">
          <h2>正文 TPS</h2>
          <p>
            此范围暂无可用正文样本；Agent Speed 请求均速独立显示，不混入正文
            TPS。
          </p>
        </section>
      )}
      <TokenActivitySection
        days={projectClientDays(
          codex.activityDays,
          snapshot.dailyBuckets ?? [],
          allowed,
        )}
        modelCostDataAvailable={false}
        tokensOnly
      />
      <section className="recent-usage-chart integrated-trend">
        <div className="section-title-row">
          <h2>近期 Token 用量</h2>
          <div>
            {allowed.length > 1 && (
              <label>
                <input
                  type="checkbox"
                  checked={split}
                  onChange={(e) => setSplit(e.target.checked)}
                />
                按客户端
              </label>
            )}
            {[1, 7, 30].map((d) => (
              <button
                key={d}
                aria-pressed={days === d}
                onClick={() => setDays(d)}
              >
                {d === 1 ? "24小时" : `${d}天`}
              </button>
            ))}
          </div>
        </div>
        <svg
          viewBox="0 0 920 260"
          role="img"
          aria-label="Token 用量趋势"
          onPointerMove={(e) => {
            const r = e.currentTarget.getBoundingClientRect();
            setHover(
              Math.max(
                0,
                Math.min(
                  times.length - 1,
                  Math.round(
                    ((((e.clientX - r.left) / r.width) * 920 - 40) / 840) *
                      (times.length - 1),
                  ),
                ),
              ),
            );
          }}
          onPointerLeave={() => setHover(null)}
        >
          {[0, 0.5, 1].map((f) => (
            <g key={f}>
              <line
                x1="40"
                x2="880"
                y1={225 - f * 195}
                y2={225 - f * 195}
                stroke="currentColor"
                opacity=".1"
              />
              <text
                x="35"
                y={229 - f * 195}
                fontSize="10"
                fill="currentColor"
                textAnchor="end"
              >
                {amount(maximum * f)}
              </text>
            </g>
          ))}
          {series.map((client) => (
            <path
              key={client}
              d={path(client)}
              fill="none"
              stroke={clientBrand[client] ?? "#83b84f"}
              strokeWidth="2"
            />
          ))}
          {hover !== null && (
            <line
              x1={40 + (hover * 840) / Math.max(1, times.length - 1)}
              x2={40 + (hover * 840) / Math.max(1, times.length - 1)}
              y1="20"
              y2="225"
              stroke="currentColor"
              opacity=".5"
            />
          )}
          {[0, Math.floor(times.length / 2), times.length - 1].map((i, k) => (
            <text
              key={k}
              x={40 + (i * 840) / Math.max(1, times.length - 1)}
              y="250"
              textAnchor="middle"
              fontSize="11"
              fill="currentColor"
            >
              {new Date(times[i] * 1000).toLocaleString(undefined, {
                month: "2-digit",
                day: "2-digit",
                hour: "2-digit",
                minute: "2-digit",
              })}
            </text>
          ))}
        </svg>
        {hover !== null && (
          <p>
            {new Date(times[hover] * 1000).toLocaleString()} ·{" "}
            {points
              .filter((p) => p.startUnix === times[hover])
              .map(
                (p) => `${clientTitle(p.client)} ${p.tokens.toLocaleString()}`,
              )
              .join(" · ")}
          </p>
        )}
        <small>
          {days === 1 ? "5 分钟" : days === 7 ? "1 小时" : "6 小时"}桶 ·
          本地已记录，缺失日志不补推
        </small>
      </section>
      <ScopedClientCacheView codex={codex} sourceToken={sourceToken} />
    </>
  );
}

export function ScopedSidebarUsage() {
  const { allowed, snapshot } = useClientScope();
  const rows = snapshot.summaries.filter((row) => allowed.includes(row.client));
  return (
    <section className="qs-usage">
      <h3>本地已记录 Token</h3>
      {rows.map((row) => (
        <div key={`${row.client}:${row.model}`}>
          <span>
            {clientTitle(row.client)} · {row.model}
          </span>
          <strong>{amount(row.inputTokens + row.outputTokens)}</strong>
        </div>
      ))}
      {!rows.length && <p>暂无该来源的本地用量记录</p>}
      <small>
        正文 TPS 尚无可用样本；Codex 账本保留，汇总详情请在主页面查看。
      </small>
    </section>
  );
}

export function ClientSidebarUsageRows({ onOpen }: { onOpen: () => void }) {
  const { allowed, snapshot } = useClientScope();
  return (
    <>
      {snapshot.preferences
        .filter((p) => p.showSidebar && allowed.includes(p.client))
        .map((p) => {
          const rows = snapshot.summaries.filter(
            (row) => row.client === p.client,
          );
          return (
            <button
              className="integrated-client-usage"
              key={p.client}
              onClick={onOpen}
              style={{ color: p.color }}
            >
              <span>{clientTitle(p.client)}</span>
              <strong>
                {rows.length
                  ? amount(
                      rows.reduce(
                        (total, row) =>
                          total + row.inputTokens + row.outputTokens,
                        0,
                      ),
                    )
                  : "—"}
              </strong>
              {p.style === "detailed" && <small>累计 Token</small>}
            </button>
          );
        })}
    </>
  );
}
