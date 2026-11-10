import { modelUsageColor, modelUsageLabel } from "../modelUsagePresentation";
import { modelPresentationIdentity } from "../../domain/modelPresentationIdentity";
import { formatTokens } from "../../utils/format";
import {chartModelCacheText, chartModelCacheDetail, type ChartUsageSummary} from "./usageSnapshot";

export function ChartModelUsageList({summary}:{summary:ChartUsageSummary}) {
  return <div className="chart-model-usage-list chart-hover-row" role="list" aria-label="所选客户端模型用量与缓存命中率">
    {summary.models.map(row=> {
      const label=modelPresentationIdentity(row.model).label,client=modelUsageLabel("client:"+row.client);
      const share=summary.totalTokens>0?Math.round(row.totalTokens/summary.totalTokens*100):0;
      return <div key={row.id} role="listitem" data-client={row.client} data-model={row.model}
      aria-label={`${label} · ${client}，用量占比 ${share}%，${formatTokens(row.totalTokens)} Token，${chartModelCacheDetail(row)}`}
      title={`${client} · ${row.sourceModels.join(", ")} · ${chartModelCacheDetail(row)}`}>
      <i style={{background:modelUsageColor(row.model)}}/>
      <span className="chart-model-identity"><span>{label} {share}%</span><small>{client}</small></span>
      <span className="chart-model-metrics"><span>{formatTokens(row.totalTokens)}</span><small>缓存命中 {chartModelCacheText(row)}</small></span>
    </div>;})}
    {!summary.modelComplete&&<small>部分用量未报告模型</small>}
  </div>;
}
