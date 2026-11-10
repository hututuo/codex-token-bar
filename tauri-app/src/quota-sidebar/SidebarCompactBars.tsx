import { Fragment, type CSSProperties, type ReactNode } from "react";
import { clientBrand, quotaFill, type QuotaItem, type QuotaSelection } from "../multiClient/integratedClientModel";
import { modelRateGradient } from "../components/liveRate/modelRatePresentation";
import type { ModelRateContribution } from "../types/live";
import { SidebarTaskCells, type SidebarTaskMeterPresentation } from "./SidebarTaskMeter";
import { SidebarModelShareStrip } from "./SidebarActivityStrokes";
import { compactSidebarIDs, fixedSidebarRailLayout, quotaWindowsForClient, sidebarUsesCompactDot, sidebarHasCompactRepresentation } from "./sidebarLayoutPresentation";

export function SidebarCompactBars({ items, quotas, selection, ratePercent, modelRates = [], models = [],
  expected = {}, visible = true, preview = false, indicator, rateLabel = "全会话实时速率（估算）",
  taskMeter }: {
  items: readonly string[]; quotas: readonly QuotaItem[]; selection: QuotaSelection;
  ratePercent: number | null; modelRates?: ModelRateContribution[];
  models?: readonly { key: string; share: number; color: string }[];
  expected?: Record<string, number | null>; visible?: boolean; preview?: boolean; rateLabel?: string; indicator?: ReactNode;
  taskMeter: SidebarTaskMeterPresentation;
}) {
  const layout = fixedSidebarRailLayout(compactSidebarIDs(items, quotas).length,
    preview ? 100000 : typeof window === "undefined" ? 900 : window.innerHeight || 900, items.filter(sidebarUsesCompactDot).length);
  return <div className={`qs-bars${preview ? " qs-bars-preview" : ""}`}
    style={{ gap: layout.gap, overflowY: "auto", "--integrated-bar-height": `${layout.barHeight}px`, ...(preview ? { height: layout.height } : {}) } as CSSProperties}
    data-visible={visible} aria-hidden={!visible} aria-label={preview ? "一级收起外观预览" : "悬停查看额度"}>
    {indicator}
    {items.filter(sidebarHasCompactRepresentation).map(id => <Fragment key={id}>

      {id === "speed" && <span className="qs-bar qs-rate-bar" data-sidebar-item={id} data-sidebar-stroke-target={id} style={{ height: layout.barHeight }} data-known={ratePercent !== null} aria-label={rateLabel} title={rateLabel}>
        <i style={{ height: `${ratePercent ?? 0}%`, background: modelRateGradient(modelRates, "0deg") }} />
      </span>}
      {id === "tasks" && <span role="img" className="qs-bar qs-task-state-bar" data-sidebar-item={id} data-sidebar-stroke-target={id}
        data-task-state={taskMeter.status} style={{ height: layout.barHeight }}
        aria-label={taskMeter.label} title={taskMeter.label}><SidebarTaskCells meter={taskMeter}/></span>}
      {id.startsWith("quota:") && quotaWindowsForClient(quotas, id.slice(6)).map(item =>
        <span key={item.id} data-sidebar-item={id} data-quota-id={item.id} className="integrated-quota-track" style={{ height: layout.barHeight }} title={`${item.client} · ${item.window} ${item.remaining === null ? item.status : Math.round(item.remaining) + "%"}\n${item.source??""}`}>
          <i className="integrated-client-cap" data-quota-marker-start={item.id} aria-hidden="true" style={{ background: clientBrand[item.client] ?? "#888" }} />
          <span className="integrated-quota-value-track" style={{ height: layout.barHeight - 2.5 }}>
            <span className={`qs-bar ${item.remaining === null ? "qs-unknown" : ""}`} data-sidebar-stroke-target={item.id}>
              <i style={{ height: `${item.remaining ?? 0}%`, background: selection.colors[item.id] ?? quotaFill(item) }} />
            </span>
          </span>
          {expected[item.id] != null && <b className="qs-pace-mark" data-sidebar-pace-target={item.id}
            style={{ top: 2.5 + (layout.barHeight - 2.5) * (1 - Math.min(1, Math.max(0, expected[item.id]!))) }} />}
        </span>)}
      {id === "models" && <SidebarModelShareStrip models={models} title="今日模型 Token 占比" vertical height={layout.barHeight}/>}
    </Fragment>)}
  </div>;
}
