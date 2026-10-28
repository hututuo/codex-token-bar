import { useClientScope, clientTitle, amount } from "./useClientScope";
import { MultiClientDiscoveryNotice } from "./MultiClientUsage";
import { clientBrand } from "./integratedClientModel";
export function ClientScopeButtons({value,clients,onChange}:{value:string;clients:readonly string[];onChange:(value:string)=>void}) {
  return <nav aria-label="统计客户端范围">{["codex",...clients,"all"].map(id=><button type="button" key={id}
    aria-pressed={value===id} onClick={()=>onChange(id)}>{id!=="all"&&<i style={{background:clientBrand[id]}}/>}{clientTitle(id)}</button>)}</nav>;
}
export function ClientScopeSelector({showsDiscovery=true}:{showsDiscovery?:boolean}={}) {
  const {raw,setScope,available}=useClientScope();
  return <div className="integrated-scope"><ClientScopeButtons value={raw} clients={available} onChange={setScope}/>{showsDiscovery&&<MultiClientDiscoveryNotice/>}</div>;
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
