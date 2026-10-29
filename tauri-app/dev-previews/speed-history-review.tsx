import React,{useState} from 'react';
import {createRoot} from 'react-dom/client';
import {SpeedTrendPlot,trendPlot} from '../src/components/liveRate/BodySpeedTrend';
import {SidebarBodyMedianContent} from '../src/quota-sidebar/SidebarBodyMedianCard';
import {sidebarBodyMedian} from '../src/quota-sidebar/sidebarBodyMedian';
import {modelUsageColor} from '../src/components/modelUsagePresentation';
import local from './speed-history.local.json';
import '../src/styles/global.css';
import '../src/components/liveRate/bodySpeedTrend.css';
import '../src/quota-sidebar/sidebarBodyMedian.css';
const models=[...new Set(local.points.map(p=>p.model))];
function Preview(){
 const [model,setModel]=useState<string|null>(models.find(m=>m.includes('6.1-sol'))??models[0]);
 const plot=trendPlot(local.points,local.now,86400,model);
 return <main style={{maxWidth:1100,margin:'28px auto',padding:'0 24px'}}>
  <p style={{fontSize:11,color:'var(--muted)'}}>候选版真实组件 · 本机已保存的24小时测速 · {new Date(local.capturedAt).toLocaleString()} · 本页不启动采集、不上报、不修改正式版</p>
  <h1 style={{fontSize:24,margin:'18px 0'}}>全天速度变化</h1>
  <div style={{display:'grid',gridTemplateColumns:'104px minmax(0,1fr)',gap:24,alignItems:'start'}}>
   <aside style={{background:'#090d0b',color:'#fff',borderRadius:18,padding:'16px 8px'}}><SidebarBodyMedianContent snapshot={sidebarBodyMedian(local.points,local.now)} latest={local.latest} error={null} onOpen={()=>document.querySelector('#day-speed')?.scrollIntoView({behavior:'smooth'})}/></aside>
   <section id="day-speed" className="body-speed-trend" style={{background:'var(--panel)',padding:18,borderRadius:14,border:'1px solid var(--line)'}}>
    <header><strong>速度变化</strong><span>每点为5分钟加权均速 · TPS</span><div><button aria-pressed>24小时</button></div></header>
    <div className="bst-models"><button aria-pressed={model===null} onClick={()=>setModel(null)}>全部</button>{models.map(m=><button key={m} aria-pressed={model===m} onClick={()=>setModel(m)}><i style={{background:modelUsageColor(m)}}/>{m.replace(/^gpt-/,'')}</button>)}</div>
    <SpeedTrendPlot points={plot.rows} minimum={plot.minimum} maximum={plot.maximum} asOf={local.now} windowSeconds={86400} days={1} resets={[]} clipId="real-speed-day"/>
    <small style={{color:'var(--muted)'}}>悬停查看时间、Token、耗时和正文段数；没有采样的时段保留空档。左侧是原版侧栏近3小时中位数小折线。</small>
   </section>
  </div>
 </main>;
}
createRoot(document.getElementById('root')!).render(<Preview/>);
