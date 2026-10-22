import React,{useEffect,useRef,useState} from 'react';
import {createRoot} from 'react-dom/client';
import {SidebarRailContent,QuotaDetails,RunningDetails,ResetCreditDetails} from '../src/quota-sidebar/QuotaSidebarApp';
import {FloatingPanelSurface} from '../src/floating/FloatingPanelPreview';
import {DEFAULT_FLOATING_SETTINGS} from '../src/floating/floatingSettings';
import {resolveDockAnchor} from '../src/floating/floatingEdgeDock';
import {RecentUsageChart} from '../src/components/RecentUsageChart';
import {TokenActivitySection} from '../src/components/TokenActivitySection';
import {ObservedSpeedDetails} from '../src/components/liveRate/ObservedSpeedDetails';
import {data,days,recent,snapshot,threads,now} from './fixture';
import '../src/styles/global.css';
import '../src/quota-sidebar/QuotaSidebar.css';
import './demo.css';

function SurfaceDemo(){
  const [mode,setMode]=useState<'rest'|'hover'|'detail'>('hover');
  const [tab,setTab]=useState('quota');
  const [side,setSide]=useState('left');
  const [floating,setFloating]=useState(true);
  const [auto,setAuto]=useState(!matchMedia('(prefers-reduced-motion: reduce)').matches);
  const [step,setStep]=useState(0);
  const [pinned,setPinned]=useState(false);
  const [notice,setNotice]=useState('');
  const [dragging,setDragging]=useState(false);
  const desktop=useRef<HTMLDivElement>(null);
  const [pos,setPos]=useState({x:560,y:270});
  useEffect(()=>{if(!auto)return;const timer=setInterval(()=>setStep(v=>(v+1)%5),3000);return()=>clearInterval(timer);},[auto]);
  useEffect(()=>{if(auto){setMode((['rest','hover','detail','hover','hover'] as const)[step]);setSide(step===3?'right':'left');if(step===4)dock();if(step===0)setPos({x:560,y:270});}},[auto,step]);
  const dock=()=>{const width=desktop.current?.clientWidth??1000;const anchor=resolveDockAnchor({frame:{x:width-320,y:270,width:308,height:90},workArea:{x:0,y:0,width,height:510},scaleFactor:1});if(anchor)setPos({x:anchor.frame.x,y:anchor.frame.y});};
  const manual=(next:typeof mode)=>{setAuto(false);setMode(next);};
  const open=(next:string,section?:string)=>{setTab(section==='speeds'?'speed':next);manual('detail');};
  const startDrag=(event:React.PointerEvent<HTMLDivElement>)=>{
    if((event.target as HTMLElement).closest('button'))return;
    setAuto(false);setDragging(true);
    event.currentTarget.setPointerCapture(event.pointerId);
    const start={x:event.clientX,y:event.clientY,px:event.currentTarget.offsetLeft,py:event.currentTarget.offsetTop};
    const width=desktop.current?.clientWidth??1000,height=desktop.current?.clientHeight??510;
    let point={x:start.px,y:start.py};
    const move=(e:PointerEvent)=>{point={x:Math.min(width-308,Math.max(0,start.px+e.clientX-start.x)),y:Math.min(height-90,Math.max(0,start.py+e.clientY-start.y))};setPos(point);};
    const up=()=>{setDragging(false);const anchor=resolveDockAnchor({frame:{...point,width:308,height:90},workArea:{x:0,y:0,width,height},scaleFactor:1});if(anchor)setPos({x:anchor.frame.x,y:anchor.frame.y});window.removeEventListener('pointermove',move);window.removeEventListener('pointerup',up);};
    window.addEventListener('pointermove',move);window.addEventListener('pointerup',up);
  };
  return <div className="surface-demo">
    <div className="demo-toolbar"><div className="demo-tabs">{(['rest','hover','detail'] as const).map((v,i)=><button key={v} aria-pressed={mode===v} onClick={()=>manual(v)}>{['贴边色条','悬停速览','点击详情'][i]}</button>)}</div><div><button onClick={()=>{setAuto(false);setSide(s=>s==='left'?'right':'left');}}>左右停靠 ⇄</button><button onClick={()=>{setAuto(false);manual('hover');setFloating(true);dock();}}>演示吸附</button><button aria-pressed={floating} onClick={()=>setFloating(v=>!v)}>悬浮窗</button><button aria-pressed={auto} onClick={()=>setAuto(v=>!v)}>{auto?'暂停演示':'自动演示'}</button></div></div>
    <div ref={desktop} className="demo-desktop" data-side={side}>
      <div className="demo-work"><div className="demo-work-bar"><i/><i/><i/><span>你的工作区</span></div><div className="demo-editor"><div className="demo-editor-nav"><b>项目</b><span>优化设置面板</span><span>整理项目文档</span><span>检查窗口布局</span></div><div className="demo-editor-main"><small>专注手上的事</small><h2>额度和任务，<br/>放在余光看得到的地方。</h2><p>色条常驻 · 悬停速览 · 点击详情</p><div className="demo-code"><span>01</span> const focus = <em>"your work"</em>;<br/><span>02</span> const context = <em>"always in sight"</em>;</div></div></div></div>
      <div className={`demo-rail quota-sidebar-document qs-${side} demo-mode-${mode}`} onMouseEnter={()=>{if(mode==='rest')manual('hover');}} onClickCapture={event=>{const button=(event.target as HTMLElement).closest('button');if(button?.getAttribute('aria-label')==='打开主页面'){event.stopPropagation();window.parent.postMessage({type:'tokenbar-demo-navigate',anchor:'usage'},location.origin);setNotice('完整图表见下方「用量与额度」');}}}>
        <main className={`qs-rail qs-${side} qs-mode-${mode==='rest'?'rest':'hover'}`}><SidebarRailContent data={data} state={{mode:mode==='rest'?'rest':'hover',tab:'quota',section:'top',pinned,focusRevision:0} as any} onOpen={open} onPin={()=>setPinned(v=>!v)} onRefresh={()=>setNotice('演示快照已刷新；不连接真实账号')}/></main>
      </div>
      {mode==='detail'&&<aside className={`demo-detail quota-sidebar-document qs-detail qs-${side}`}><header><strong>Codex <small>Pro</small></strong><button aria-label="收起详情" onClick={()=>manual('hover')}>×</button></header><nav><button aria-selected={tab==='quota'} onClick={()=>setTab('quota')}>额度概览</button><button aria-selected={tab==='speed'} onClick={()=>setTab('speed')}>测速</button><button aria-selected={tab==='running'} onClick={()=>setTab('running')}>运行会话</button><button aria-selected={tab==='credits'} onClick={()=>setTab('credits')}>重置卡</button></nav><div className="qs-detail-content">{tab==='speed'?<ObservedSpeedDetails data={snapshot} threads={threads} surface="sidebar"/>:tab==='running'?<RunningDetails data={data}/>:tab==='credits'?<ResetCreditDetails data={data}/>:tab==='radar'?<p className="qs-muted">这是离线展示，不连接第三方雷达。正式应用可查看官方 Radar 和社区 RadarBench 的参考信息。</p>:<QuotaDetails data={data} onOpenRunning={()=>setTab('running')}/>}</div><footer>演示数据 · 原程序组件</footer></aside>}
      {floating&&<div className="demo-floating" data-dragging={dragging} style={{left:side==='right'&&mode==='detail'?Math.min(pos.x,240):pos.x,top:pos.y}} onPointerDown={startDrag}><FloatingPanelSurface settings={{...DEFAULT_FLOATING_SETTINGS,contentVisibility:{...DEFAULT_FLOATING_SETTINGS.contentVisibility,showRadar:false,showCrowdRadar:false,showTodayModelShare:false,showTodayModelCost:false}}} snapshot={snapshot} runningThreads={data.runningThreads} previewMode onClose={()=>setFloating(false)}/><span className="demo-float-hint">悬浮窗 · 可拖动，近边缘吸附</span></div>}
      <div className="demo-tray">◒ 76.4 t/s <span>5h 76%　7d 58%</span></div>
      <span className="demo-disclosure">原程序 React 组件 · 模拟账号与用量 · 拖动范围仅限演示画布</span>
      {notice&&<button className="demo-toast" onClick={()=>setNotice('')}>{notice} ×</button>}
    </div>
  </div>;
}
function App(){
  const view=new URLSearchParams(location.search).get('view')||'surfaces';
  return <main className={`demo-root demo-view-${view}`}>{view==='surfaces'?<SurfaceDemo/>:view==='analytics'?<><RecentUsageChart {...recent}/><TokenActivitySection days={days}/><p className="demo-note">原程序图表组件 · 模拟数据，可切换时间范围、图例，悬停和选择区间。</p></>:<><ObservedSpeedDetails data={snapshot} threads={threads}/><p className="demo-note">原程序正文 TPS 组件 · 模拟样本。此页面不会读取本机日志、连接账号或请求原生功能。</p></>}</main>;
}
createRoot(document.getElementById('root')!).render(<App/>);
