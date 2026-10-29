import React,{useRef,useState} from 'react';
import {createRoot} from 'react-dom/client';
import {PairedQuotaRing} from '../src/multiClient/ClientQuotaViews';
import {SidebarCompactBars} from '../src/quota-sidebar/SidebarCompactBars';
import {SidebarSummaryLayer} from '../src/quota-sidebar/SidebarSummaryLayer';
import {SidebarActivityRing,SidebarTaskRing,SidebarModelShareStrip} from '../src/quota-sidebar/SidebarActivityStrokes';
import {useQuotaMarkerMorph} from '../src/quota-sidebar/useQuotaMarkerMorph';
import {defaultQuotaSelection,type QuotaItem} from '../src/multiClient/integratedClientModel';
import {floatingTodayModelUsageItems} from '../src/floating/floatingModelUsage';
import local from './dashboard-header.local.json';
import '../src/styles/global.css';
import '../src/multiClient/integratedClients.css';
import '../src/quota-sidebar/QuotaSidebar.css';

const quotas:QuotaItem[]=[{id:'codex:7d',client:'codex',window:'7d',remaining:100-local.quota.seven_day_used_percent,resetsAt:null,source:'本地只读快照',status:''},
 {id:'claudeCode:5h',client:'claudeCode',window:'5h',remaining:62,resetsAt:null,source:'显示测试模拟',status:''},
 {id:'claudeCode:7d',client:'claudeCode',window:'7d',remaining:84,resetsAt:null,source:'显示测试模拟',status:''}];
const models=floatingTodayModelUsageItems(local.codexRows,'gpt56Sol',{showPlaceholders:false,mergeAutoReview:false}).filter(x=>x.share>0);
const rates=[{model:'gpt-6-astra',tokensPerSecond:40},{model:'gpt-6.1-sol',tokensPerSecond:60}];
function Review(){
 const [expanded,setExpanded]=useState(true),[paired,setPaired]=useState(true);
 const root=useRef<HTMLDivElement>(null);
 useQuotaMarkerMorph(root,expanded,true);
 const items=['modeltrace','speed','quota:codex',...(paired?['quota:claudeCode']:[]),'models','tasks','tps','credits'];
 const selected=paired?quotas:quotas.slice(0,1);
 return <main className="squeeze-review"><header><h1>规则椭圆压合，整环对应整条</h1><p>候选版实际组件 · 沿用原侧栏尺寸、字体与配色 · 本页不采集、不上报、不修改设置</p></header>
 <div className="review-layout"><div className="quota-sidebar-document"><div className={`qs-rail qs-left preview-rail ${expanded?'expanded':''}`} ref={root}>
  <SidebarCompactBars items={items} quotas={selected} selection={defaultQuotaSelection} ratePercent={65} modelRates={rates} models={models}
   taskStatus="ready" taskLabel="显示测试：2 个任务" visible={!expanded}/>
  <SidebarSummaryLayer visible={expanded} children={()=> <>
   <button className="qs-quota-trigger qs-rate-trigger"><SidebarActivityRing morphID="speed" label="t/s" percent={65} color="#63a6eb" modelRates={rates}/><strong>100</strong></button>
   <PairedQuotaRing left={quotas[0]}/>
   {paired&&<PairedQuotaRing left={quotas[1]} right={quotas[2]}/>}
   <button className="qs-model-trigger"><SidebarModelShareStrip models={models} title="本地模型占比快照"/><span>模型占比</span></button>
   <button className="qs-running-trigger"><SidebarTaskRing><strong>2</strong></SidebarTaskRing><span>显示测试</span></button>
  </>}/>
 </div></div><section className="review-controls"><span className="review-tag">生产组件 · 规则椭圆 v2</span><h2>{expanded?'二级菜单':'一级菜单'}</h2>
 <div className="review-buttons"><button onClick={()=>setExpanded(true)}>展开</button><button onClick={()=>setExpanded(false)}>收起</button><button onClick={()=>setExpanded(value=>!value)}>反向切换</button></div>
 <label><input type="checkbox" checked={paired} onChange={event=>setPaired(event.target.checked)}/>显示 Claude 双周期（模拟额度）</label>
 <p>圆环保持规则椭圆，只压窄和移动，不再拉扯弧线顶点；用量刻度沿完整轮廓变化，再并拢成直条。速度和任务复用这一变换；模型占比的横条对应竖条，颜色顺序和占比保留。</p>
 <p>Codex 额度与模型占比来自本地快照；Claude 额度、速度与任务数字仅用于动画测试。</p>
 <p className="review-note">展开与收起均为 440ms，可连续点“反向切换”检查中断恢复。没有循环播放；停止操作后不保留动画层。</p>
 </section></div></main>;
}
createRoot(document.getElementById('root')!).render(<Review/>);
