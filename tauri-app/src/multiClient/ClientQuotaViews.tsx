import {
  useClientQuotaItems,
  useClientQuotaSelection,
  clientTitle,
  value,
} from "./useClientScope";
import {
  clientBrand,
  quotaFill,
  quotaWindowTitle,
  clientSidebarMetrics,
  compactQuotaValue,
  type QuotaItem,
  type QuotaSelection,
} from "./integratedClientModel";
import { claudeQuotaSetup } from "./multiClientProduct";
import type { QuotaSnapshot } from "../types/dashboard";
export function ClientQuotaSettings({ codex, colorsOnly = false }: { codex?: QuotaSnapshot; colorsOnly?: boolean }) {
  const { catalog } = useClientQuotaItems(codex), { selection, save } = useClientQuotaSelection();
  return <section className="integrated-quota-settings">
    <div className="integrated-quota-heading"><h4>额度填充颜色</h4><button onClick={() => save({ ...selection, colors: {} })}>恢复默认颜色</button></div>
    {catalog.map(i => <div className="integrated-quota-option" key={i.id}>
      <i style={{ background: clientBrand[i.client] }}/>
      <label>{!colorsOnly && <input type="checkbox"
        checked={!selection.hidden.includes(i.id)}
        onChange={event => save({ ...selection,
          hidden: event.target.checked ? selection.hidden.filter(id => id !== i.id) : [...new Set([...selection.hidden, i.id])],
          enabled: event.target.checked ? [...new Set([...selection.enabled, i.id])] : selection.enabled.filter(id => id !== i.id),
        })}/>}
        {clientTitle(i.client)} · {i.window}
      </label>
      <input type="color" aria-label={clientTitle(i.client) + " " + i.window + "填充颜色"}
        value={selection.colors[i.id] ?? quotaFill(i)}
        onChange={event => save({ ...selection, colors: { ...selection.colors, [i.id]: event.target.value } })}/>
    </div>)}
    <p>各额度窗口独立。显示与顺序在侧栏设置中调整。</p>
  </section>;
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
    <g transform={`rotate(${rotate} 30 30)`} data-sidebar-stroke-source="" data-stroke-inset={4 / 60}
      data-stroke-spec={JSON.stringify([{id:i.id,half:rotate > 0 ? -1 : 1,fraction:i.remaining === null ? null : i.remaining / 100,expected:expected[i.id],color:colors[i.id] ?? quotaFill(i),trackColor:"#343a35",trackOpacity:1,width:4.6 * clientSidebarMetrics.ringSize / 60}])}>
      <circle
        cx="30"
        cy="30"
        r="26"
        fill="none"
        stroke="#343a35"
        strokeWidth="4.6"
        strokeDasharray="80 163.36"
      />
      <circle
        cx="30"
        cy="30"
        r="26"
        fill="none"
        stroke={colors[i.id] ?? quotaFill(i)}
        strokeWidth="4.6"
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
  const clientLegend = (i: QuotaItem, ids = [i.id]) => (
    <span className="integrated-ring-legend" title={clientTitle(i.client)}>
      <i data-quota-marker-end={ids.join(" ")} style={{ background: clientBrand[i.client] }} />
      {clientTitle(i.client)}
    </span>
  );
  const windowLegend = (i: QuotaItem) => (
    <span style={{color:colors[i.id] ?? quotaFill(i)}} title={`${clientTitle(i.client)} ${i.window} · ${i.resetsAt ? "重置 " + new Date(i.resetsAt).toLocaleString() : "重置时间未知"}${i.remaining === null ? " · " + i.status : ""}`}>{quotaWindowTitle(i.window)}</span>
  );
  return (
    <div
      className="integrated-paired-ring"
      role="img"
      data-mode={right ? "paired" : "single"}
      title={[left,...(right?[right]:[])].map(item=>`${clientTitle(item.client)} ${item.window} · ${item.remaining===null?item.status:value(item)}\n${item.source??""}`).join("\n")}
      aria-label={
        right
          ? `左侧 ${clientTitle(left.client)} ${left.window} ${left.remaining===null?left.status:value(left)}；右侧 ${clientTitle(right.client)} ${right.window} ${right.remaining===null?right.status:value(right)}`
          : `${clientTitle(left.client)} ${left.window} ${left.remaining===null?left.status:"剩余 "+value(left)}，完整圆环`
      }
    >
      <div style={{ width: clientSidebarMetrics.ringSize, height: clientSidebarMetrics.ringSize }}>
        <svg viewBox="0 0 60 60" aria-hidden="true">
          {right ? (
            <>
              {half(left, 91)}
              {half(right, -89)}
            </>
          ) : (
            <g data-sidebar-stroke-source="" data-stroke-inset={4 / 60}
              data-stroke-spec={JSON.stringify([{id:left.id,fraction:left.remaining === null ? null : left.remaining / 100,expected:expected[left.id],color:colors[left.id] ?? quotaFill(left),trackColor:"#343a35",trackOpacity:1,width:4.6 * clientSidebarMetrics.ringSize / 60}])}>
              <circle
                cx="30"
                cy="30"
                r="26"
                fill="none"
                stroke="#343a35"
                strokeWidth="4.6"
              />
              <circle
                cx="30"
                cy="30"
                r="26"
                fill="none"
                stroke={colors[left.id] ?? quotaFill(left)}
                strokeWidth="4.6"
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
            </g>
          )}
        </svg>
        <strong>
          {right ? <><span data-digits={compactQuotaValue(left).length}>{compactQuotaValue(left)}</span><b aria-hidden="true"/><span data-digits={compactQuotaValue(right).length}>{compactQuotaValue(right)}</span></> : left.remaining===null?compactQuotaValue(left):value(left)}
        </strong>
      </div>
      <div className="integrated-ring-captions">
        <div className="integrated-ring-windows">{windowLegend(left)}{right && windowLegend(right)}</div>
        <div className="integrated-ring-clients">{clientLegend(left, right && right.client === left.client ? [left.id, right.id] : [left.id])}{right && right.client !== left.client && clientLegend(right)}</div>
      </div>
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
                <ClientQuotaDetailCard
                  key={i.id} item={i} fill={selection.colors[i.id] ?? quotaFill(i)} expected={expected[i.id]}
                  id={`qs-section-${i.id === "codex:5h" ? "five" : i.id === "codex:7d" ? "seven" : i.id.replace("codex:", "").replaceAll(" ", "-")}`}
                />
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
      {items.length === 0 && <p>所选客户端暂无本地额度读数</p>}
      <small>各窗口独立，不合计额度</small>
    </div>
  );
}

/** Full-width window card shared by every detail scope, including Pro's 5h/7d. */
export function ClientQuotaDetailCard({item,fill,expected,id}: {
  item: QuotaItem; fill: string; expected?: number|null; id?: string;
}) {
  const api=item.id.endsWith(":api");
  return <div className="integrated-quota-card" id={id} data-quota-id={item.id}
    role="group" aria-label={`${clientTitle(item.client)} ${item.window} 剩余 ${value(item)}`}>
    {!api && <div className="integrated-full-ring" aria-hidden="true">
      <svg viewBox="0 0 100 100">
        <circle cx="50" cy="50" r="44" fill="none" stroke="currentColor" opacity=".12" strokeWidth="7.5"/>
        <circle cx="50" cy="50" r="44" fill="none" stroke={fill} strokeWidth="7.5" strokeLinecap="round"
          strokeDasharray="276.46" strokeDashoffset={276.46*(1-(item.remaining??0)/100)} transform="rotate(-90 50 50)"
          opacity={item.remaining===null?0:1}/>
        {expected!=null && <line className="integrated-full-pace" data-quota-id={item.id}
          x1="50" y1="2" x2="50" y2="14" stroke="currentColor" strokeWidth="2"
          transform={`rotate(${expected*360} 50 50)`}/>}
      </svg>
      <span><strong>{value(item)}</strong><small>{item.window}</small></span>
    </div>}
    <div className="integrated-quota-window-info">
      <strong>{api?"API 接入":`${quotaWindowTitle(item.window)}额度`}</strong>
      {!api && <small>{item.resetsAt ? `重置 ${new Date(item.resetsAt).toLocaleString(undefined,{month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",hour12:false})}` : "重置时间未知"}</small>}
      {item.status && <small>{item.status}</small>}
    </div>
  </div>;
}
