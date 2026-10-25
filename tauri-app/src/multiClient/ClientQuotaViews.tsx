import {
  useClientQuotaItems,
  useClientQuotaSelection,
  clientTitle,
  value,
} from "./useClientScope";
import {
  clientBrand,
  type QuotaItem,
  type QuotaSelection,
} from "./integratedClientModel";
import { claudeQuotaSetup } from "./multiClientProduct";
import type { QuotaSnapshot } from "../types/dashboard";
export function ClientQuotaSettings({ codex }: { codex?: QuotaSnapshot }) {
  const { catalog } = useClientQuotaItems(codex),
    { selection, save } = useClientQuotaSelection();
  function move(index: number, by: number) {
    const order = catalog.map((i) => i.id);
    [order[index], order[index + by]] = [order[index + by], order[index]];
    save({ ...selection, order });
  }
  return (
    <section className="integrated-quota-settings">
      <h4>额度项目</h4>
      <label>
        竖条长度{" "}
        <select
          value={selection.length}
          onChange={(e) =>
            save({
              ...selection,
              length: e.target.value as QuotaSelection["length"],
            })
          }
        >
          <option value="auto">自动</option>
          <option value="long">长条</option>
          <option value="short">短条</option>
        </select>
      </label>
      <p>自动：超出原推荐高度 25% 时用短条，保留全部项目。</p>
      <label>
        <input
          type="checkbox"
          checked={selection.pairAcrossClients}
          onChange={(e) =>
            save({ ...selection, pairAcrossClients: e.target.checked })
          }
        />
        将不同客户端的额度合在一个环内
      </label>
      <p>默认按客户端配对：一项用整环，两项用左右半环。</p>
      {catalog.map((i, index) => {
        const checked =
          !selection.hidden.includes(i.id) &&
          (i.client === "codex" ||
            i.client === "claudeCode" ||
            selection.enabled.includes(i.id));
        return (
          <div className="integrated-quota-option" key={i.id}>
            <i style={{ background: clientBrand[i.client] }} />
            <label>
              <input
                type="checkbox"
                checked={checked}
                onChange={(e) =>
                  save({
                    ...selection,
                    hidden: e.target.checked
                      ? selection.hidden.filter((id) => id !== i.id)
                      : [...new Set([...selection.hidden, i.id])],
                    enabled: e.target.checked
                      ? [...new Set([...selection.enabled, i.id])]
                      : selection.enabled.filter((id) => id !== i.id),
                  })
                }
              />
              {clientTitle(i.client)} · {i.window}
            </label>
            <input
              type="color"
              aria-label={`${clientTitle(i.client)} ${i.window}填充颜色`}
              value={selection.colors[i.id] ?? clientBrand[i.client]}
              onChange={(e) =>
                save({
                  ...selection,
                  colors: { ...selection.colors, [i.id]: e.target.value },
                })
              }
            />
            <button
              disabled={!index}
              onClick={() => move(index, -1)}
              aria-label={`上移 ${i.window}`}
            >
              ↑
            </button>
            <button
              disabled={index === catalog.length - 1}
              onClick={() => move(index, 1)}
              aria-label={`下移 ${i.window}`}
            >
              ↓
            </button>
          </div>
        );
      })}
      <p>范围跟随主页面；各窗口独立。Claude 联网额度关闭。</p>
    </section>
  );
}

export function PairedQuotaRing({
  left,
  right,
  expected = {},
  colors = {},
}: {
  left: QuotaItem;
  right?: QuotaItem;
  expected?: Record<string, number | null>;
  colors?: Record<string, string>;
}) {
  const half = (i: QuotaItem, rotate: number) => (
    <g transform={`rotate(${rotate} 30 30)`}>
      <circle
        cx="30"
        cy="30"
        r="26"
        fill="none"
        stroke="#343a35"
        strokeWidth="3"
        strokeDasharray="80 163.36"
      />
      <circle
        cx="30"
        cy="30"
        r="26"
        fill="none"
        stroke={colors[i.id] ?? clientBrand[i.client]}
        strokeWidth="3"
        strokeLinecap="round"
        strokeDasharray={`${(80 * (i.remaining ?? 0)) / 100} 163.36`}
        opacity={i.remaining === null ? 0 : 1}
      />
      {expected[i.id] != null && (
        <line
          className="integrated-half-pace"
          data-quota-id={i.id}
          x1="30"
          y1="1"
          x2="30"
          y2="7"
          stroke="white"
          strokeWidth="1.5"
          transform={`rotate(${90 + expected[i.id]! * 180} 30 30)`}
        />
      )}
    </g>
  );
  const legend = (i: QuotaItem) => (
    <span
      className="integrated-ring-legend"
      title={`${clientTitle(i.client)} ${i.window} · ${i.resetsAt ? "重置 " + new Date(i.resetsAt).toLocaleString() : "重置时间未知"}`}
    >
      <i style={{ background: clientBrand[i.client] }} />
      {clientTitle(i.client)} · {i.window}
      {i.remaining === null ? " · " + i.status : ""}
    </span>
  );
  return (
    <div
      className="integrated-paired-ring"
      role="img"
      data-mode={right ? "paired" : "single"}
      aria-label={
        right
          ? `左侧 ${clientTitle(left.client)} ${left.window} ${value(left)}；右侧 ${clientTitle(right.client)} ${right.window} ${value(right)}`
          : `${clientTitle(left.client)} ${left.window} 剩余 ${value(left)}，完整圆环`
      }
    >
      <div>
        <svg viewBox="0 0 60 60" aria-hidden="true">
          {right ? (
            <>
              {half(left, 91)}
              {half(right, -89)}
            </>
          ) : (
            <>
              <circle
                cx="30"
                cy="30"
                r="26"
                fill="none"
                stroke="#343a35"
                strokeWidth="3"
              />
              <circle
                cx="30"
                cy="30"
                r="26"
                fill="none"
                stroke={colors[left.id] ?? clientBrand[left.client]}
                strokeWidth="3"
                strokeLinecap="round"
                strokeDasharray="163.36"
                strokeDashoffset={163.36 * (1 - (left.remaining ?? 0) / 100)}
                transform="rotate(-90 30 30)"
                opacity={left.remaining === null ? 0 : 1}
              />
              {expected[left.id] != null && (
                <line
                  className="integrated-full-pace"
                  data-quota-id={left.id}
                  x1="30"
                  y1="1"
                  x2="30"
                  y2="7"
                  stroke="white"
                  strokeWidth="1.5"
                  transform={`rotate(${expected[left.id]! * 360} 30 30)`}
                />
              )}
            </>
          )}
        </svg>
        <strong>
          {value(left)}
          {right && (
            <>
              <b>|</b>
              {value(right)}
            </>
          )}
        </strong>
      </div>
      {legend(left)}
      {right && legend(right)}
    </div>
  );
}

export function ClientQuotaDetailRings({
  items,
  expected = {},
}: {
  items: QuotaItem[];
  expected?: Record<string, number | null>;
}) {
  const { selection } = useClientQuotaSelection();
  return (
    <div className="integrated-quota-details">
      {[...new Set(items.map((i) => i.client))].map((client) => (
        <section key={client}>
          <h4>
            <i style={{ background: clientBrand[client] }} />
            {clientTitle(client)}
          </h4>
          <div className="integrated-full-rings">
            {items
              .filter((i) => i.client === client)
              .map((i) => (
                <div
                  key={i.id}
                  id={`qs-section-${i.id === "codex:5h" ? "five" : i.id === "codex:7d" ? "seven" : i.id.replace("codex:", "").replaceAll(" ", "-")}`}
                >
                  <div className="integrated-full-ring">
                    <svg viewBox="0 0 100 100" aria-hidden="true">
                      <circle
                        cx="50"
                        cy="50"
                        r="44"
                        fill="none"
                        stroke="currentColor"
                        opacity=".12"
                        strokeWidth="6"
                      />
                      <circle
                        cx="50"
                        cy="50"
                        r="44"
                        fill="none"
                        stroke={selection.colors[i.id] ?? clientBrand[client]}
                        strokeWidth="6"
                        strokeLinecap="round"
                        strokeDasharray="276.46"
                        strokeDashoffset={
                          276.46 * (1 - (i.remaining ?? 0) / 100)
                        }
                        transform="rotate(-90 50 50)"
                        opacity={i.remaining === null ? 0 : 1}
                      />
                      {expected[i.id] != null && (
                        <line
                          className="integrated-full-pace"
                          data-quota-id={i.id}
                          x1="50"
                          y1="2"
                          x2="50"
                          y2="12"
                          stroke="currentColor"
                          strokeWidth="2"
                          transform={`rotate(${expected[i.id]! * 360} 50 50)`}
                        />
                      )}
                    </svg>
                    <span>
                      <strong>{value(i)}</strong>
                      <small>{i.window}</small>
                    </span>
                  </div>
                  <small>
                    {i.window === "5h"
                      ? "5 小时额度"
                      : i.window === "7d"
                        ? "7 天额度"
                        : i.window === "储备5h"
                          ? "Luna 储备 · 5小时"
                          : i.window === "储备7d"
                            ? "Luna 储备 · 7天"
                            : i.window}
                  </small>
                  <small>
                    {i.resetsAt
                      ? `重置 ${new Date(i.resetsAt).toLocaleString()}`
                      : "重置时间未知"}
                  </small>
                  {i.status && <small>{i.status}</small>}
                </div>
              ))}
          </div>
          <p>{items.find((i) => i.client === client)?.source}</p>
          {client === "claudeCode" &&
            items
              .filter((i) => i.client === client)
              .every((i) => i.remaining === null) && (
              <details>
                <summary>查看接入说明</summary>
                {claudeQuotaSetup}
              </details>
            )}
        </section>
      ))}
      <small>各窗口独立，不合计额度</small>
    </div>
  );
}

export function ClientDashboardQuotaStrip({ items }: { items: QuotaItem[] }) {
  const { selection } = useClientQuotaSelection();
  return (
    <section className="integrated-dashboard-quotas" aria-label="各客户端额度">
      {items.map((i) => (
        <div className="quota-bar" key={i.id}>
          <span className="quota-label">
            <i style={{ background: clientBrand[i.client] }} />
            {clientTitle(i.client)} · {i.window}
          </span>
          <div className="quota-track">
            <i
              className="quota-track-fill"
              style={{
                width: `${i.remaining ?? 0}%`,
                background: selection.colors[i.id] ?? clientBrand[i.client],
                opacity: i.remaining === null ? 0 : 1,
              }}
            />
          </div>
          <div className="quota-bar-meta">
            <b>{value(i)}</b>
            <em>
              {i.remaining === null
                ? i.status
                : i.resetsAt
                  ? new Date(i.resetsAt).toLocaleString()
                  : "重置时间未知"}
            </em>
          </div>
        </div>
      ))}
    </section>
  );
}
