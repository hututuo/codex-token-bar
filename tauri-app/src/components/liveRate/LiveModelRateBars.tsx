import { modelUsageColor } from "../modelUsagePresentation";
import { modelRateValueText, type LiveModelRateSnapshot } from "./modelRatePresentation";
import { useSpeedPalette } from "./useSpeedPalette";

/** Layout only: uses the exact snapshot sent by the sidebar rail. */
export function LiveModelRateBars({ snapshot }: { snapshot: LiveModelRateSnapshot }) {
  useSpeedPalette();
  return <section className="live-model-rate-bars" aria-label="实时模型速度" data-source-key={snapshot.sourceKey}>
    <header><strong>实时模型速度</strong><span>{snapshot.available ? modelRateValueText(snapshot.total) : "—"} tok/s</span></header>
    <small>{snapshot.mode === "bar" ? "Bar 模式" : "Agent Speed"} · {snapshot.status}</small>
    {snapshot.rows.map(row => <div className="live-model-rate-row" key={row.id} data-client={row.client} data-model={row.model}
      title={`${row.clientLabel} · ${row.rawModels.join(", ")} · ${modelRateValueText(row.tokensPerSecond)} tok/s`}>
      <i className="live-model-rate-dot" style={{ background: modelUsageColor(row.colorKey) }}/>
      <span className="live-model-rate-name">{row.label}<small>{row.clientLabel}</small></span>
      <span className="live-model-rate-track" style={{ background: modelUsageColor(row.colorKey) + "24" }}>
        <i style={{ width: `${row.barFraction * 100}%`, background: modelUsageColor(row.colorKey) }}/>
      </span>
      <span className="live-model-rate-value">{modelRateValueText(row.tokensPerSecond)} tok/s</span>
    </div>)}
    <small>{snapshot.rows.length ? "条长按当前最快模型缩放；颜色与侧栏圆圈一致" : snapshot.status}</small>
  </section>;
}
