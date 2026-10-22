import React,{useEffect,useState,type CSSProperties} from 'react';
import {createRoot} from 'react-dom/client';
// @ts-expect-error The showcase-only Vite plugin exposes the existing private view.
import {ShowcaseDetailSurface,SidebarRailContent} from '../src/quota-sidebar/QuotaSidebarApp';
import {sidebarRailClassName,initialSidebarState} from '../src/quota-sidebar/model';
import {sidebarRadarSnapshot} from '../src/quota-sidebar/radarModel';
import {sidebarCanvasClasses} from '../src/quota-sidebar/canvas';
import {FloatingPanelSurface} from '../src/floating/FloatingPanelPreview';
import {DEFAULT_FLOATING_SETTINGS} from '../src/floating/floatingSettings';
import {floatingPanelAppearance} from '../src/floating/floatingPresentation';
import {data,snapshot} from './fixture';
import geometry from 'virtual:showcase-geometry';
import {emitTo,listen} from './offline-events';
// These are the original styles, isolated in their own document. No showcase
// stylesheet is imported here, so the marketing page cannot restyle the app.
import '../src/styles/global.css';
import '../src/quota-sidebar/QuotaSidebar.css';

const surface=new URLSearchParams(location.search).get('surface')||'quota-sidebar';
if(surface==='floating')document.documentElement.classList.add('floating-document');
else document.documentElement.classList.add('quota-sidebar-document',...sidebarCanvasClasses(surface,'Win32'));

function ProductSurface(){
  const [value,setValue]=useState({state:initialSidebarState,side:'left' as 'left'|'right',radar:sidebarRadarSnapshot(null,null)});
  useEffect(()=>{
    const listener=listen<typeof value>('quota-sidebar-presentation',event=>setValue(event.payload));
    void emitTo('host','showcase-ready',surface);
    return ()=>{void listener.then(fn=>fn());};
  },[]);
  const action=(payload:unknown)=>void emitTo('quota-sidebar','quota-sidebar-action',payload);
  if(surface==='quota-sidebar-detail')return <ShowcaseDetailSurface/>;
  if(surface==='floating'){
    const settings=DEFAULT_FLOATING_SETTINGS;
    const style={...floatingPanelAppearance(settings).style,'--floating-shell-padding-y':`${6*settings.scale}px`} as CSSProperties;
    return <main className="floating-window-shell" style={style}>
      <FloatingPanelSurface settings={settings} snapshot={snapshot} runningThreads={data.runningThreads}
        unreadEffect={settings.unreadEffect} onClose={()=>void emitTo('host','showcase-floating-close')}
        onOpenDashboard={()=>void emitTo('host','showcase-dashboard')}/>
    </main>;
  }
  document.documentElement.style.setProperty('--qs-native-width',`${value.state.mode==='rest'?geometry.restWidth:geometry.width}px`);
  document.documentElement.style.setProperty('--qs-native-height',`${value.state.mode==='rest'?geometry.restHeight:geometry.height}px`);
  // Same root element/class and full rendering subtree as RailSurface. Only
  // native pointer/window operations are supplied by this offline host.
  return <main className={sidebarRailClassName(value.side,value.state.mode)}
    onPointerEnter={()=>action({type:'enter'})} aria-label="额度侧栏">
    <SidebarRailContent data={data} radar={value.radar} state={value.state} onPin={()=>action({type:'pin'})}
      onRefresh={()=>void emitTo('host','showcase-refresh')}
      onOpen={(tab,section)=>action({type:'open',tab,section})}/>
  </main>;
}
document.addEventListener('click',event=>{
  const button=(event.target as Element)?.closest('button');
  if(button?.getAttribute('aria-label')?.match(/^打开主[页界]面$/)){
    event.preventDefault();event.stopImmediatePropagation();void emitTo('host','showcase-dashboard');
  }
},true);
createRoot(document.getElementById('root')!).render(<ProductSurface/>);
