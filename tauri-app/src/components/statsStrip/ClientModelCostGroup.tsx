import {useId, useState, type CSSProperties} from "react";
import {costModelColumns, type CostModelGroup} from "../../domain/modelCostOrder";
import {modelPresentationDetail} from "../../domain/modelPresentationIdentity";
import {floatingModelUsageMoneyText, floatingModelUsageValue, isReferenceOnlyModelUsage} from "../../floating/floatingModelUsage";
import {formatTokens} from "../../utils/format";
import {dashboardModelUsageColor, floatingModelUsageKey} from "../modelUsagePresentation";
import type {ColorEditTarget} from "../liveRate/ModelColorEditor";

/** Folding is a view concern: the shared group retains every row for totals and details. */
export function ClientModelCostGroup({group,onEditColor}:{group:CostModelGroup;onEditColor:(target:ColorEditTarget)=>void}) {
  const [expanded,setExpanded]=useState(false),gridID=useId();
  const limit=group.visibleLimit??group.items.length,hidden=Math.max(0,group.items.length-limit);
  const items=expanded?group.items:group.items.slice(0,limit),primary=!group.isSecondary;
  return <div className="stats-model-cost-group" data-cost-group={group.id}>
    <div className="stats-model-cost-group-label"><span>{group.label}</span>
      {hidden>0 && <button type="button" className="stats-model-cost-expand" aria-expanded={expanded} aria-controls={gridID}
        aria-label={expanded?`收起${group.label}其他模型`:`展开${group.label}其余${hidden}个模型`}
        onClick={()=>setExpanded(!expanded)}>{expanded?"收起":`另${hidden}项`}</button>}
    </div>
    <div id={gridID} className={primary?"stats-model-cost-primary-grid":"stats-model-cost-secondary-grid"}
      style={{gridTemplateColumns:`repeat(${costModelColumns}, minmax(0, 1fr))`}}>
      {items.map(item=>{
        const color=dashboardModelUsageColor(item.key,primary),referenceOnly=isReferenceOnlyModelUsage(item);
        const label=item.label.replace(/^GPT[- ]*/i,""),qualifiedLabel=label.match(/^(.*?)(（[^）]*）)$/);
        const amount=referenceOnly?(item.referenceCostUSD===null?"—":(item.key==="unknown-models"?"参考 ":"")+floatingModelUsageMoneyText(item.referenceCostUSD)):floatingModelUsageValue(item,"cost");
        const detail=`${referenceOnly?"参考 · ":""}${formatTokens(item.tokens)} · ${floatingModelUsageValue(item,"share")}`;
        const description=`${item.label} · ${floatingModelUsageValue(item,"cost")} · ${detail}`;
        const edit=(x:number,y:number)=>onEditColor({model:floatingModelUsageKey(item.key.split("|").at(-1)),x,y,grayDefault:!primary});
        return <span className={primary?"stats-model-cost-primary-card":"stats-model-cost-secondary-chip"} key={item.key} style={{"--model-color":color} as CSSProperties}
          aria-label={description} title={`${description}${item.key.includes("|")?" · 来源："+item.key.split("|")[0]:""}${item.sourceModels?.length?" · 原始标识："+item.sourceModels.map(modelPresentationDetail).join("、"):""} · 双击修改该模型颜色`}
          role="button" tabIndex={0} onDoubleClick={event=>edit(event.clientX,event.clientY)}
          onKeyDown={event=>{if(event.key==="Enter"||event.key===" "){event.preventDefault();const rect=event.currentTarget.getBoundingClientRect();edit(rect.left,rect.bottom);}}}>
          <i style={{backgroundColor:color}}/><em><span className="model-cost-name">{qualifiedLabel?qualifiedLabel[1]:label}</span>{qualifiedLabel&&<span className="model-cost-name-suffix">{qualifiedLabel[2]}</span>}</em>
          <small className="model-cost-tokens">{formatTokens(item.tokens)}</small><small className="model-cost-share">{floatingModelUsageValue(item,"share")}</small><b>{amount}</b>
        </span>;
      })}
    </div>
  </div>;
}
