import './capture-clock';
import React,{useEffect,useReducer,useRef,useState} from 'react';
import {createRoot} from 'react-dom/client';
import {initialSidebarState,sidebarReducer,isSidebarAction,hasFiveHourQuota,type SidebarState} from '../src/quota-sidebar/model';
import {floatingContentHeight} from '../src/floating/floatingContent';
import {DEFAULT_FLOATING_SETTINGS,FLOATING_BASE_WIDTH} from '../src/floating/floatingSettings';
import geometry from 'virtual:showcase-geometry';
import {sidebarRadarSnapshot} from '../src/quota-sidebar/radarModel';
const demoRadar=sidebarRadarSnapshot(officialRadar,crowdRadar,now*1000);
import {RecentUsageChart} from '../src/components/RecentUsageChart';
import {TokenActivitySection} from '../src/components/TokenActivitySection';
import {ObservedSpeedDetails} from '../src/components/liveRate/ObservedSpeedDetails';
import {data,days,recent,snapshot,threads,officialRadar,crowdRadar,now,capturedAtLabel} from './fixture';
import '../src/styles/global.css';
import './demo.css';
function SurfaceDemo(){
  const [state,dispatch]=useReducer(sidebarReducer,initialSidebarState);
  const [side,setSide]=useState<'left'|'right'>('left');
  const [floating,setFloating]=useState(true);
  const [auto,setAuto]=useState(!matchMedia('(prefers-reduced-motion: reduce)').matches);
  const [notice,setNotice]=useState('');
  const [scale,setScale]=useState(1);
  const viewport=useRef<HTMLDivElement>(null);
  const rail=useRef<HTMLIFrameElement>(null),detail=useRef<HTMLIFrameElement>(null),float=useRef<HTMLIFrameElement>(null);
  const current=useRef({data,radar:demoRadar,state,side,error:null});current.current={data,radar:demoRadar,state,side,error:null};
  const send=()=>[rail,detail].forEach(frame=>frame.current?.contentWindow?.postMessage({type:'showcase-product-event',event:'quota-sidebar-presentation',payload:current.current},location.origin));
  useEffect(send,[state,side]);
  useEffect(()=>{const resize=new ResizeObserver(entries=>setScale(Math.min(1,entries[0].contentRect.width/1000)));if(viewport.current)resize.observe(viewport.current);return()=>resize.disconnect();},[]);
  useEffect(()=>{
    const receive=(event:MessageEvent)=>{
      if(event.origin!==location.origin||![rail,detail,float].some(frame=>frame.current?.contentWindow===event.source)||event.data?.type!=='showcase-product-event')return;
      const {event:name,payload}=event.data;
      if(name==='quota-sidebar-action'&&isSidebarAction(payload)){setAuto(false);dispatch(payload);}
      if(name==='quota-sidebar-detail-ready'||name==='showcase-ready')send();
      if(name==='showcase-floating-close'){setFloating(false);setAuto(false);}
      if(name==='showcase-dashboard')window.parent.postMessage({type:'tokenbar-demo-navigate',anchor:'usage'},location.origin);
      if(name==='showcase-refresh')setNotice('本机数据快照 · ' + capturedAtLabel);
    };
    window.addEventListener('message',receive);return()=>window.removeEventListener('message',receive);
  },[]);
  useEffect(()=>{if(!auto)return;let step=0;const apply=()=>{setSide(step===3?'right':'left');dispatch(step===0?{type:'dismiss'}:step===2?{type:'open',tab:'quota'}:{type:'close'});if(step!==0&&step!==2)dispatch({type:'enter'});step=(step+1)%4;};apply();const timer=setInterval(apply,3000);return()=>clearInterval(timer);},[auto]);
  const manual=(mode:SidebarState['mode'])=>{setAuto(false);dispatch(mode==='rest'?{type:'dismiss'}:mode==='detail'?{type:'open',tab:'quota'}:{type:'close'});if(mode==='hover')dispatch({type:'enter'});};
  const expanded=state.mode!=='rest';
  const showsFiveHour=hasFiveHourQuota(snapshot.fiveHourAvailability,snapshot.fiveHourRemainingPercent);
  const expandedHeight=showsFiveHour?geometry.height:geometry.weeklyHeight,restHeight=showsFiveHour?geometry.restHeight:geometry.weeklyRestHeight;
  const width=expanded?geometry.width:geometry.restWidth,height=expanded?expandedHeight:restHeight;
  const floatingHeight=floatingContentHeight(DEFAULT_FLOATING_SETTINGS.contentVisibility)*DEFAULT_FLOATING_SETTINGS.scale+12;
  // Reserve space for the widest sidebar state, even while its detail is
  // closed. The floating window stays in the opposite clear area throughout.
  const occupiedEdge=geometry.width+geometry.gap+geometry.detailWidth;
  const floatingX=side==='left'?occupiedEdge+48:1000-occupiedEdge-48-FLOATING_BASE_WIDTH;
  const floatingY=(740-floatingHeight)/2;
  return <div className="surface-demo">
    <div className="demo-toolbar"><div className="demo-tabs">{(['rest','hover','detail'] as const).map((mode,i)=><button key={mode} aria-pressed={state.mode===mode} onClick={()=>manual(mode)}>{['贴边色条','悬停速览','点击详情'][i]}</button>)}</div><div><button onClick={()=>{setAuto(false);setSide(value=>value==='left'?'right':'left');}}>左右停靠 ⇄</button><button aria-pressed={floating} onClick={()=>setFloating(value=>!value)}>悬浮窗</button><button aria-pressed={auto} onClick={()=>setAuto(value=>!value)}>{auto?'暂停演示':'自动演示'}</button></div></div>
    <div ref={viewport} className="demo-viewport" style={{height:740*scale}}>
      <div className="demo-desktop" data-side={side} style={{transform:`scale(${scale})`}}>
        <div className="demo-work"><div className="demo-work-bar"><i/><i/><i/><span>工作区示意</span></div><div className="demo-editor-main"><small>界面直接来自程序源码</small><h2>额度和任务，<br/>放在余光看得到的地方。</h2><p>原组件 · 原样式 · 原尺寸</p></div></div>
        <div className="product-rail-clip" style={{[side]:0,top:(740-height)/2,width,height,borderRadius:side==='left'?`0 ${expanded?22:8}px ${expanded?22:8}px 0`:`${expanded?22:8}px 0 0 ${expanded?22:8}px`}}>
          <iframe ref={rail} src="surface.html?surface=quota-sidebar" title="原程序额度侧栏" onLoad={send} style={{width:geometry.width,height:geometry.height,top:(height-geometry.height)/2,[side]:0}}/>
        </div>
        <iframe ref={detail} className="product-detail-frame" src="surface.html?surface=quota-sidebar-detail" title="原程序完整侧栏详情" onLoad={send} style={{visibility:state.mode==='detail'?'visible':'hidden',width:geometry.detailWidth,height:geometry.detailHeight,top:(740-geometry.detailHeight)/2,[side]:geometry.width+geometry.gap}}/>
        {floating&&<><span className="product-floating-caption" style={{left:floatingX,top:floatingY-24}}>悬浮窗</span><iframe ref={float} className="product-floating-frame" src="surface.html?surface=floating" title="原程序默认悬浮窗" style={{width:FLOATING_BASE_WIDTH,height:floatingHeight,left:floatingX,top:floatingY}}/>{!snapshot.liveRateAvailable&&<span className="product-floating-caption" style={{left:floatingX,top:floatingY+floatingHeight+8}}>活动速率未采集 · 0.0 为占位</span>}</>}
        <span className="demo-disclosure">跨平台原程序界面 · 本机真实快照 {capturedAtLabel}</span>
        {notice&&<button className="demo-toast" onClick={()=>setNotice('')}>{notice} ×</button>}
      </div>
    </div>
    <p className="demo-note">侧栏 {geometry.restWidth} × {restHeight} / {geometry.width} × {expandedHeight} · 详情 {geometry.detailWidth} × {geometry.detailHeight} · 窄屏仅等比缩放整幅画布</p>
  </div>;
}
function App(){
  const view=new URLSearchParams(location.search).get('view')||'surfaces';
  return <main className={`demo-root demo-view-${view}`}>{view==='surfaces'?<SurfaceDemo/>:view==='analytics'?<><RecentUsageChart {...recent} fiveHourQuotaPresent={hasFiveHourQuota(snapshot.fiveHourAvailability,snapshot.fiveHourRemainingPercent)} sevenDayQuotaPresent={snapshot.sevenDayAvailability==='measured'}/><TokenActivitySection days={days}/><p className="demo-note">本机真实用量快照 {capturedAtLabel} · 可切换时间范围、图例，悬停和选择区间。</p></>:<><ObservedSpeedDetails data={snapshot} threads={threads}/><p className="demo-note">本机真实正文样本 · {capturedAtLabel} · 统计截至采集时刻。</p></>}</main>;
}
createRoot(document.getElementById('root')!).render(<App/>);
