import { modelUsageColor, modelUsageLabel } from "../modelUsagePresentation";
import { modelPresentationIdentity } from "../../domain/modelPresentationIdentity";
import { formatTokens } from "../../utils/format";
import type { ChartUsageSummary } from "./usageSnapshot";

export function ChartModelUsageList({summary}:{summary:ChartUsageSummary}) {
  return <div className="chart-model-usage-list chart-hover-row" aria-label="所选客户端模型用量">
    {summary.models.map(row=><div key={row.id} data-client={row.client} data-model={row.model}
      title={`${modelUsageLabel("client:"+row.client)} · ${row.sourceModels.join(", ")}`}>
      <i style={{background:modelUsageColor(row.model)}}/>
      <span>{modelPresentationIdentity(row.model).label} {summary.totalTokens>0?Math.round(row.totalTokens/summary.totalTokens*100):0}%</span>
      <small>{modelUsageLabel("client:"+row.client)}</small>
      <span>{formatTokens(row.totalTokens)}</span>
    </div>)}
    {!summary.modelComplete&&<small>部分用量未报告模型</small>}
  </div>;
}
