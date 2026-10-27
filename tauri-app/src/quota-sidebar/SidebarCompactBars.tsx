import { Fragment, type CSSProperties, type ReactNode } from "react";
import { clientBrand, quotaFill, type QuotaItem, type QuotaSelection } from "../multiClient/integratedClientModel";
import { modelRateGradient } from "../components/liveRate/modelRatePresentation";
import type { ModelRateContribution } from "../types/live";
import type { RunningThreadSummaryStatus } from "../types/threadActivity";
import { compactSidebarIDs, fixedSidebarRailLayout, quotaWindowsForClient, sidebarUsesCompactDot, sidebarItemTitle } from "./sidebarLayoutPresentation";

export function SidebarCompactBars({ items, quotas, selection, ratePercent, modelRates = [], models = [],
  expected = {}, visible = true, preview = false, indicator, rateLabel = "全会话实时速率（估算）",
  taskStatus, taskLabel }: {
  items: readonly string[]; quotas: readonly QuotaItem[]; selection: QuotaSelection;
  ratePercent: number | null; modelRates?: ModelRateContribution[];
  models?: readonly { key: string; share: number; color: string }[];
  expected?: Record<string, number | null>; visible?: boolean; preview?: boolean; rateLabel?: string; indicator?: ReactNode;
  taskStatus: RunningThreadSummaryStatus; taskLabel: string;
}) {
  const layout = fixedSidebarRailLayout(compactSidebarIDs(items, quotas).length,
    preview ? 100000 : typeof window === "undefined" ? 900 : window.innerHeight || 900, items.filter(sidebarUsesCompactDot).length);
  return <div className={`qs-bars${preview ? " qs-bars-preview" : ""}`}
    style={{ gap: layout.gap, overflowY: "auto", "--integrated-bar-height": `${layout.barHeight}px`, ...(preview ? { height: layout.height } : {}) } as CSSProperties}
    data-visible={visible} aria-hidden={!visible} aria-label={preview ? "一级收起外观预览" : "悬停查看额度"}>
    {indicator}
    {items.map(id => <Fragment key={id}>
      {sidebarUsesCompactDot(id) && <span data-sidebar-item={id} role="img" aria-label={sidebarItemTitle(id, x => x)} title={sidebarItemTitle(id, x => x)} style={{ width: 6, height: 6, minHeight: 6, borderRadius: "50%", background: "#b6ef75", opacity: .8 }} />}
      {id === "speed" && <span className="qs-bar qs-rate-bar" data-sidebar-item={id} style={{ height: layout.barHeight }} data-known={ratePercent !== null} aria-label={rateLabel} title={rateLabel}>
        <i style={{ height: `${ratePercent ?? 0}%`, background: modelRateGradient(modelRates, "0deg") }} />
      </span>}
      {id === "tasks" && <span role="img" className="qs-bar qs-task-state-bar" data-sidebar-item={id}
        data-task-state={taskStatus} style={{ height: layout.barHeight, background: "rgba(239,192,119,.5)" }}
        aria-label={taskLabel} title={taskLabel} />}
      {id.startsWith("quota:") && quotaWindowsForClient(quotas, id.slice(6)).map(item =>
        <span key={item.id} data-sidebar-item={id} data-quota-id={item.id} className="integrated-quota-track" style={{ height: layout.barHeight }} title={`${item.client} · ${item.window} ${item.remaining === null ? item.status : Math.round(item.remaining) + "%"}`}>
          <i className="integrated-client-cap" data-window={item.window} aria-hidden="true" style={{ background: `color-mix(in srgb, ${clientBrand[item.client] ?? "#888"} 80%, white)` }} />
          <span className="integrated-quota-value-track" style={{ height: layout.barHeight }}>
            <span className={`qs-bar ${item.remaining === null ? "qs-unknown" : ""}`}>
              <i style={{ height: `${item.remaining ?? 0}%`, background: selection.colors[item.id] ?? quotaFill(item) }} />
              {expected[item.id] != null && <b className="qs-pace-mark" style={{ bottom: `${expected[item.id]! * 100}%` }} />}
            </span>
          </span>
        </span>)}
      {id === "models" && <div data-sidebar-item={id} className="qs-model-strip qs-model-strip-vertical" style={{ height: layout.barHeight }} aria-label="今日模型 Token 占比">
        {models.map(item => <i key={item.key} style={{ flexGrow: item.share, background: item.color }} />)}
      </div>}
    </Fragment>)}
  </div>;
}
