import React,{useRef,useState} from 'react';
import {createRoot} from 'react-dom/client';
import {ActivitySpeedLivePlot} from '../src/multiClient/ActivitySpeedLivePlot';
import {SidebarActivityRing} from '../src/quota-sidebar/SidebarActivityStrokes';
import {SidebarBodyMedianContent} from '../src/quota-sidebar/SidebarBodyMedianCard';
import {SidebarSummaryLayer} from '../src/quota-sidebar/SidebarSummaryLayer';
import data from './live-speed.local.json';
import '../src/styles/global.css';
import '../src/quota-sidebar/QuotaSidebar.css';
import '../src/quota-sidebar/sidebarBodyMedian.css';
const latest=data.rows.flatMap(r=>r.points.at(-1)?.modelRates??[]),total=latest.reduce((s,r)=>s+r.tokensPerSecond,0);
function Preview(){const [opened,setOpened]=useState(false);const detail=useRef<HTMLDivElement>(null);const open=()=>{setOpened(true);detail.current?.scrollIntoView({behavior:'smooth',block:'center'});};return <main style={{maxWidth:900,margin:'30px auto',padding:24}}>
 <h1 style={{fontSize:22}}>二级菜单：与中位图同宽、同边距</h1>
 <p style={{fontSize:12,color:'var(--muted)'}}>跨平台实际组件渲染 · 侧栏原尺寸88px · 原有本机速度记录回放（{data.capturedAt}）。下方中位图仅作排版参照，数值为布局样本。</p>
 <div style={{display:'grid',gridTemplateColumns:'150px minmax(0,1fr)',gap:32,alignItems:'start'}}>
  <section><p style={{fontSize:12}}>二级菜单 · 可点击</p><div className="quota-sidebar-document" style={{position:'relative',width:88,height:330}}>
   <aside className="qs-rail qs-right" style={{width:88,height:330,overflow:'hidden'}}>
    <SidebarSummaryLayer visible={true}>{()=> <div className="qs-module-stack">
     <div className="qs-linked-item"><button className="qs-quota-trigger qs-rate-trigger" onClick={open}><SidebarActivityRing morphID="speed" label="t/s" percent={Math.min(100,total/2)} color="#78b7ff" modelRates={latest}/><strong>{total.toFixed(1)}</strong></button><ActivitySpeedLivePlot rows={data.rows} asOf={data.asOf} compact onOpen={open}/></div>
     <div className="qs-linked-item"><SidebarBodyMedianContent snapshot={null} latest={[{model:'gpt-6.1-sol',tokensPerSecond:49.7,sampleCount:1,outputTokens:497,durationSeconds:10,lastMeasuredAt:data.asOf}]} error={null} onOpen={()=>{}}/></div>
    </div>}</SidebarSummaryLayer>
   </aside>
  </div><p style={{fontSize:11,lineHeight:1.7,color:'var(--muted)'}}>图面74px；左右各留7px。<br/>点小图直达右侧速度详情。</p></section>
  <section ref={detail} style={{background:'#0d100e',color:'#f0f3eb',border:'1px solid #272d26',borderRadius:24,padding:22,'--text':'#f0f3eb','--muted':'#98a49c'} as React.CSSProperties}>
   <h2 style={{fontSize:17,margin:'0 0 20px'}}>三级菜单 · 速度曲线{opened?' · 已进入':''}</h2><ActivitySpeedLivePlot rows={data.rows} asOf={data.asOf}/>
  </section>
 </div>
</main>};createRoot(document.getElementById('root')!).render(<Preview/>);
