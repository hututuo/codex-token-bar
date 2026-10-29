import {memo,useId,useMemo,useState} from 'react';
import {activityLivePaths,liveChartCeiling,ACTIVITY_LIVE_SECONDS,type ActivityLiveSeries} from './activityLiveHistory';
import {activityRateText,activityRateValue,type ActivityRateUnit} from '../components/liveRate/activityRatePresentation';
import {modelUsageColor} from '../components/modelUsagePresentation';
const title=(client:string)=>({codex:'Codex',claudeCode:'Claude CLI',claudeDesktop:'Claude Desktop',gemini:'Gemini CLI',opencode:'OpenCode',deepseek:'DeepSeek'} as Record<string,string>)[client]??client;

/** Small rolling view: memory only; no history query or persisted chart points. */
export const ActivitySpeedLivePlot=memo(function ActivitySpeedLivePlot({rows,asOf,compact=false,unit='tok/s',fx=7.2,modeLabel="Agent Speed"}:{rows:readonly ActivityLiveSeries[];asOf:number;compact?:boolean;unit?:ActivityRateUnit;fx?:number;modeLabel?:string}){
  const id=useId(),[selectedClient,setSelectedClient]=useState<string|null>(null),[hoverTime,setHoverTime]=useState<number|null>(null);
  const selection=selectedClient&&rows.some(r=>r.client===selectedClient)?selectedClient:null;
  const width=compact?220:660,height=compact?84:176,left=compact?3:38,right=width-5,top=8,bottom=height-(compact?14:24),start=asOf-ACTIVITY_LIVE_SECONDS;
  const prepared=useMemo(()=>rows.filter(row=>selection===null||row.client===selection).map(row=>({...row,points:row.points.filter(p=>p.time>=start&&p.time<=asOf).map(p=>({...p,value:activityRateValue(p.rate,p.modelRates,unit,fx)}))})),[rows,selection,start,asOf,unit,fx]);
  const maximum=useMemo(()=>unit==='tok/s'?liveChartCeiling(Math.max(0,...prepared.flatMap(row=>row.points.map(p=>p.value??0)))):Math.max(.0001,...prepared.flatMap(row=>row.points.map(p=>(p.value??0)*1.12))),[prepared,unit]);
  const x=(time:number)=>left+(time-start)/ACTIVITY_LIVE_SECONDS*(right-left),y=(value:number)=>bottom-value/maximum*(bottom-top);
  const curves=useMemo(()=>prepared.map(row=>{
    const valid=row.points.map(p=>({time:p.time,value:p.value??NaN}));
    const color=modelUsageColor('client:'+row.client),last=row.points.at(-1);
    return <g key={row.client} data-live-client={row.client} data-live-point-count={row.points.length}>
      {activityLivePaths(valid,x,y,bottom).map((path,index)=><path key={index} d={path.line} fill="none" stroke={color} strokeWidth={compact?1.3:1.6} strokeLinecap="round" strokeLinejoin="round"/>)}
      {last?.value!=null&&<><circle cx={x(last.time)} cy={y(last.value)} r={compact?3:5} fill={color} opacity=".17"/><circle cx={x(last.time)} cy={y(last.value)} r={compact?1.5:2.5} fill={color}/></>}
    </g>;
  }),[prepared,id,start,maximum,unit,compact,width]);
  const selected=hoverTime===null?[]:prepared.flatMap(row=>{
    const nearest=row.points.reduce<typeof row.points[number]|undefined>((best,p)=>!best||Math.abs(p.time-hoverTime)<Math.abs(best.time-hoverTime)?p:best,undefined);
    return nearest&&Math.abs(nearest.time-hoverTime)<=2&&nearest.value!==null?[{client:row.client,...nearest}]:[];
  });
  if(compact&&rows.length===0)return null;
  return <div className={compact?'activity-live-chart is-compact':'activity-live-chart'}>
    <div className="activity-live-heading"><strong>{compact?'速度':'活动速率'}</strong><span>近3分钟</span>{!compact&&<small>{modeLabel}</small>}</div>
    {rows.length>0&&<div className="activity-live-clients" role="group" aria-label="速度客户端">{rows.length>1&&<button aria-pressed={selection===null} onClick={()=>setSelectedClient(null)}>全部</button>}{rows.map(row=><button key={row.client} style={{color:modelUsageColor('client:'+row.client)}} aria-pressed={selection===row.client||rows.length===1} onClick={()=>setSelectedClient(row.client)}>{title(row.client)}</button>)}</div>}
    <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label="最近3分钟活动速率" onPointerLeave={()=>setHoverTime(null)} onPointerMove={event=>{const box=event.currentTarget.getBoundingClientRect(),position=(event.clientX-box.left)/box.width*width;const next=position<left||position>right?null:Math.round(start+(position-left)/(right-left)*ACTIVITY_LIVE_SECONDS);setHoverTime(old=>old===next?old:next);}}>
      <defs><clipPath id={id+'clip'}><rect x={left} y={top} width={right-left} height={bottom-top+2}/></clipPath></defs>
      {[0,.5,1].map(f=><g key={f}><line x1={left} x2={right} y1={y(maximum*f)} y2={y(maximum*f)} stroke="currentColor" opacity=".1" strokeDasharray={f?'1 3':undefined}/>{!compact&&<text x={left-7} y={y(maximum*f)+3} textAnchor="end" fontSize="9" fill="currentColor" opacity=".6">{activityRateText(maximum*f,unit)}</text>}</g>)}
      <g clipPath={`url(#${id+'clip'})`}>{curves}{hoverTime!==null&&selected.length>0&&<line x1={x(hoverTime)} x2={x(hoverTime)} y1={top} y2={bottom} stroke="currentColor" opacity=".5"/>}</g>
      {rows.length===0&&<text x={(left+right)/2} y={(top+bottom)/2} textAnchor="middle" fill="currentColor" opacity=".55" fontSize={compact?9:11}>等待速度读数</text>}
      <text x={left} y={height-3} textAnchor="start" fill="currentColor" opacity=".5" fontSize="9">3分钟前</text><text x={right} y={height-3} textAnchor="end" fill="currentColor" opacity=".5" fontSize="9">现在</text>
    </svg>
    {!compact&&<div className="activity-live-inspection">{selected.length?selected.map(p=><span key={p.client}>{new Date(p.time*1000).toLocaleTimeString('zh-CN',{hour12:false})} · {title(p.client)} <b>{activityRateText(p.value,unit)} {unit}</b></span>):<span>移到曲线上查看速度</span>}</div>}
  </div>;
});
