import React,{useState} from 'react';
import {createRoot} from 'react-dom/client';
import {ActivitySpeedHistoryPlot} from '../src/multiClient/ActivitySpeedHistoryPlot';
import {SidebarBodyMedianContent} from '../src/quota-sidebar/SidebarBodyMedianCard';
import {sidebarBodyMedian} from '../src/quota-sidebar/sidebarBodyMedian';
import {ActivityRateUnitControl,useActivityRatePreferences} from '../src/components/liveRate/ActivityRateUnits';
import activity from './activity-history.local.json';
import body from './speed-history.local.json';
import '../src/styles/global.css';
import '../src/quota-sidebar/sidebarBodyMedian.css';
function Preview(){
 const [windowSeconds,setWindowSeconds]=useState(43200);
 const {unit,fx}=useActivityRatePreferences();
 return <main style={{maxWidth:1100,margin:'28px auto',padding:'0 24px'}}>
  <p style={{fontSize:11,color:'var(--muted)'}}>候选版真实组件 · 本机 Agent Speed 活动速率 · {activity.capturedAt} · 不启动采集、不上报、不修改正式版</p>
  <h1 style={{fontSize:24,margin:'18px 0'}}>Agent Speed 活动速率 · 主页／三级菜单</h1>
  <div style={{display:'grid',gridTemplateColumns:'104px minmax(0,1fr)',gap:24,alignItems:'start'}}>
   <aside style={{background:'#090d0b',color:'#fff',borderRadius:18,padding:'16px 8px'}}><SidebarBodyMedianContent snapshot={sidebarBodyMedian(body.points,body.now)} latest={body.latest} error={null} onOpen={()=>{}}/><small style={{fontSize:9,color:'#aaa'}}>二级 TPS 保持原样</small></aside>
   <section style={{background:'var(--panel)',padding:18,borderRadius:14,border:'1px solid var(--line)'}}>
    <header style={{display:'flex',justifyContent:'space-between',alignItems:'center'}}><strong>活动速率 · Codex · Agent Speed</strong><ActivityRateUnitControl/></header>
    <div className="activity-speed-history-ranges">{[43200,86400].map(seconds=><button key={seconds} aria-pressed={windowSeconds===seconds} onClick={()=>setWindowSeconds(seconds)}>{seconds===43200?'12小时':'24小时'}</button>)}</div>
    <ActivitySpeedHistoryPlot rows={activity.series.filter(s=>s.dimensions.displayMode==='agentSpeed')} asOf={activity.now} windowSeconds={windowSeconds} unit={unit} fx={fx}/>
    <small style={{color:'var(--muted)'}}>本次独立采集约{Math.round(activity.captureSeconds/60)}分钟 Agent Speed 读数，仅为短时采样；旧 Bar 未混入。每30秒平均，正文 TPS 保持原样。</small>
   </section>
  </div>
 </main>;
}
createRoot(document.getElementById('root')!).render(<Preview/>);
