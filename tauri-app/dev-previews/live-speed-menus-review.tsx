import React from 'react';
import {createRoot} from 'react-dom/client';
import {ActivitySpeedLivePlot} from '../src/multiClient/ActivitySpeedLivePlot';
import {SidebarActivityRing} from '../src/quota-sidebar/SidebarActivityStrokes';
import data from './live-speed.local.json';
import '../src/styles/global.css';
import '../src/quota-sidebar/QuotaSidebar.css';
const latest=data.rows.flatMap(r=>r.points.at(-1)?.modelRates??[]);
const total=latest.reduce((n,r)=>n+r.tokensPerSecond,0);
function Preview(){return <main style={{maxWidth:1000,margin:'32px auto',padding:'0 26px'}}>
 <p style={{fontSize:11,color:'var(--muted)'}}>跨平台实际组件预览 · 本机真实记录 {data.capturedAt} · 静态回放，不采集、不上报</p>
 <h1 style={{fontSize:23,margin:'18px 0 28px'}}>速度图移到菜单 · 最近3分钟</h1>
 <div style={{display:'grid',gridTemplateColumns:'138px minmax(0,1fr)',gap:32,alignItems:'start'}}>
  <section><p style={{fontSize:11,color:'var(--muted)',marginBottom:10}}>二级菜单 · 速度模块</p>
   <div style={{background:'#090d0b',color:'#f2f5f3',borderRadius:22,padding:'18px 12px',border:'1px solid #222925'}}>
    <button className="qs-quota-trigger qs-rate-trigger" style={{width:'100%',padding:0,marginBottom:8}}><SidebarActivityRing morphID="speed" label="t/s" percent={Math.min(100,total/2)} color="#78b7ff" modelRates={latest}/><strong style={{fontSize:14}}>{total.toFixed(1)}</strong></button>
    <ActivitySpeedLivePlot rows={data.rows} asOf={data.asOf} compact modeLabel="Bar 活动速率"/>
   </div>
  </section>
  <section><p style={{fontSize:11,color:'var(--muted)',marginBottom:10}}>三级菜单 · 完整速度图</p>
   <div style={{background:'#090d0b',color:'#f2f5f3',borderRadius:24,padding:'22px 24px',border:'1px solid #222925','--text':'#f2f5f3','--muted':'#98a49c'} as React.CSSProperties}>
    <header style={{display:'flex',alignItems:'baseline',gap:9,paddingBottom:18,marginBottom:17,borderBottom:'1px solid #29322c'}}><strong style={{fontSize:23}}>Codex</strong><span style={{fontSize:10,color:'#a3d785'}}>PROLITE</span><span style={{marginLeft:'auto',fontSize:11,color:'#98a49c'}}>测速</span></header>
    <ActivitySpeedLivePlot rows={data.rows} asOf={data.asOf} modeLabel="Bar 活动速率"/>
   </div>
   <p style={{fontSize:11,color:'var(--muted)',lineHeight:1.8,marginTop:17}}>主页移除活动速率图，正文 TPS 保持原样。<br/>保留原始采样点，只平缓连接；不做5秒／10秒平均。仅保留内存中的近3分钟。</p>
  </section>
 </div>
</main>};
createRoot(document.getElementById('root')!).render(<Preview/>);
