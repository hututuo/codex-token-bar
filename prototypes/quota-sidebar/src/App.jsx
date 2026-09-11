import React, { useEffect, useRef, useState } from 'react';
import { ArrowLeft, ArrowRight, Play, Pause, Cursor, Lightning, TerminalWindow, CheckCircle, X, PushPin, ArrowsOutSimple } from '@phosphor-icons/react';

function Ring({value, label, color}) {
  return <div className="ring"><svg viewBox="0 0 56 56" aria-hidden="true"><circle cx="28" cy="28" r="24" className="track"/><circle cx="28" cy="28" r="24" fill="none" stroke={color} strokeWidth="3" strokeLinecap="round" strokeDasharray={`${value*1.508} 150.8`} transform="rotate(-90 28 28)"/></svg><span>{label}</span></div>;
}
const quota = [{label:'5 小时额度',short:'5h',value:73,color:'#b6ef75',reset:'1 小时 42 分后重置'}, {label:'周额度',short:'7d',value:42,color:'#b4acff',reset:'周五 08:30 重置'}];
export function App() {
 const [enabled,setEnabled]=useState(true), [edge,setEdge]=useState('right'), [expanded,setExpanded]=useState(false), [hovered,setHovered]=useState(false), [pinned,setPinned]=useState(false), [demo,setDemo]=useState(false), [step,setStep]=useState(0), [tab,setTab]=useState('overview');
 const closeTimer=useRef(), demoTimers=useRef([]);
 const clearDemo=()=>{demoTimers.current.forEach(clearTimeout);demoTimers.current=[];setDemo(false);setStep(0)};
 const open=()=>{clearTimeout(closeTimer.current);setHovered(true);setExpanded(true)};
 const leave=()=>{clearTimeout(closeTimer.current);closeTimer.current=setTimeout(()=>{setExpanded(false);setHovered(false)},300)};
 const reset=()=>{clearDemo();clearTimeout(closeTimer.current);setExpanded(false);setHovered(false);setPinned(false)};
 const play=()=>{reset();setEnabled(true);setDemo(true);setStep(1);[[950,()=>{setStep(2);setHovered(true)}],[2900,()=>{setStep(3);setExpanded(true)}],[4700,()=>{setStep(4);setExpanded(false);setHovered(false)}],[5900,()=>{setStep(0);setDemo(false)}]].forEach(([ms,fn])=>demoTimers.current.push(setTimeout(fn,ms)))};
 useEffect(()=>()=>{clearTimeout(closeTimer.current);demoTimers.current.forEach(clearTimeout)},[]);
 useEffect(()=>{const key=e=>{if(e.key==='Escape')reset()};window.addEventListener('keydown',key);return()=>window.removeEventListener('keydown',key)},[]);
 const isOpen=enabled&&(expanded||pinned);
 const isPeek=enabled&&(hovered||expanded||pinned);
 const peek=()=>{clearTimeout(closeTimer.current);setHovered(true)};
 return <main>
  <header className="page-header"><div className="brand"><TerminalWindow size={23} weight="duotone"/><span>CODEX TOKEN BAR</span></div><span className="edition">交互概念 / 01</span></header>
  <section className="intro"><div><div className="eyebrow">始终在边缘，需要时展开</div><h1>额度侧栏<span>Quota Sidebar</span></h1><p>色条常驻，悬停速览，点击查看详情。</p></div><div className="controls"><button className="play" onClick={demo?reset:play}>{demo?<Pause size={16}/>:<Play size={16} weight="fill"/>}{demo?'停止演示':'播放演示'}</button><label className="switch-label">启用侧栏<button aria-label="启用额度侧栏" role="switch" aria-checked={enabled} className={`switch ${enabled?'on':''}`} onClick={()=>{reset();setEnabled(!enabled)}}><span/></button></label></div></section>
  <section className={`desktop ${edge} ${isOpen?'expanded':''} ${!enabled?'disabled':''}`} aria-label="桌面交互预览">
   <div className="menubar"><span>Codex Token Bar</span><span>演示桌面 <span className="menudate">周二 09:41</span></span></div>
   <div className="ambient"><span className="ambient-label">LESS DISTRACTION.</span><h2>专注当下。<br/>额度，留在边上。</h2><p>移向边缘，展开简略信息。<br/>再点一下，查看完整详情。</p><div className="edge-control" aria-label="吸附位置"><button aria-pressed={edge==='left'} onClick={()=>{reset();setEdge('left')}}><ArrowLeft size={14}/>左侧</button><button aria-pressed={edge==='right'} onClick={()=>{reset();setEdge('right')}}>右侧<ArrowRight size={14}/></button></div></div>
   {!enabled&&<div className="off-note">额度侧栏已关闭<button onClick={()=>setEnabled(true)}>重新开启</button></div>}
   <div className={`edge-group ${isPeek?'peek':''} ${enabled?'':'hidden'}`} onMouseEnter={()=>!demo&&peek()} onMouseLeave={()=>!demo&&leave()} onFocus={peek} onBlur={e=>{if(!e.currentTarget.contains(e.relatedTarget))leave()}}>
    <div className="compact-rail" aria-hidden={isPeek}>{quota.map(q=><button tabIndex={isPeek?-1:0} key={q.short} aria-label={`${q.label}剩余 ${q.value}%，展开简略信息`} onClick={peek}><span className="vertical-track"><span style={{height:`${q.value}%`,background:q.color}}/></span><span className="compact-value"><small>{q.short}</small>{q.value}</span></button>)}<button tabIndex={isPeek?-1:0} aria-label="2 个运行任务，展开简略信息" onClick={peek}><span className="vertical-track activity-bar"><span/></span><span className="compact-value"><small>运行</small>2</span></button></div>
    <aside className="rail" inert={!isPeek} aria-hidden={!isPeek} aria-label="额度侧栏">
     <div className="rail-title">剩余额度</div>
     {quota.map(q=><button key={q.short} className="quota-trigger" onClick={()=>{setTab('overview');open()}} aria-label={`${q.label}剩余 ${q.value}%，展开详情`} aria-expanded={isOpen}><Ring value={q.value} label={q.short} color={q.color}/><strong>{q.value}<small>%</small></strong></button>)}
     <div className="rail-divider"/><button className="activity-trigger" aria-label="查看运行中的任务" onClick={()=>{setTab('sessions');open()}}><Lightning weight="fill" size={20}/><span>2 运行</span></button>
    </aside>
    <article className={`detail ${isOpen?'visible':''}`} inert={!isOpen} aria-label="额度详情" aria-hidden={!isOpen}>
     <div className="detail-header"><div><div className="detail-brand"><TerminalWindow size={21}/><strong>Codex</strong><span className="plan">PRO</span></div><span className="updated">个人账户 · 刚刚更新</span></div><div className="card-actions"><button title={pinned?'取消固定':'固定详情'} aria-label={pinned?'取消固定详情':'固定详情'} aria-pressed={pinned} onClick={()=>setPinned(!pinned)}><PushPin size={17} weight={pinned?'fill':'regular'}/></button><button aria-label="收起详情" onClick={reset}><X size={17}/></button></div></div>
     <div className="tabs" role="tablist" aria-label="详情内容"><button role="tab" aria-selected={tab==='overview'} onClick={()=>setTab('overview')}>额度概览</button><button role="tab" aria-selected={tab==='sessions'} onClick={()=>setTab('sessions')}>任务 <span>2</span></button><span className="sample">演示数据</span></div>
     {tab==='overview'?<div role="tabpanel" aria-label="额度概览">
      <div className="quota-list">{quota.map(q=><section className="quota-row" key={q.short}><div className="quota-top"><span>{q.label}</span><strong style={{color:q.color}}>{q.value}<small>% 剩余</small></strong></div><progress aria-label={`${q.label}剩余`} value={q.value} max="100" style={{'--accent':q.color}}/><div className="quota-foot"><span>{q.reset}</span><span>已用 {100-q.value}%</span></div></section>)}</div>
      <section className="today"><div className="section-title">今日用量 <span>本地统计</span></div><div className="metrics"><div><strong>128.6<small>万</small></strong><span>Tokens</span></div><div><strong>186</strong><span>请求次数</span></div><div><strong>42.8<small>/s</small></strong><span>实时 Tokens</span></div></div></section>
      <div className="activity-summary"><Lightning size={15} weight="fill"/><span>2 个任务运行中</span><span className="done"><CheckCircle size={14}/>1 个待查看</span></div>
     </div>:<div role="tabpanel" aria-label="任务列表" className="sessions"><div className="section-title">正在运行 <span>2 个任务</span></div>{['额度侧栏交互设计','跨平台兼容性复核'].map((t,i)=><div className="session" key={t}><Lightning size={18} weight="fill"/><div><strong>{t}</strong><span>{i?'Luna · 12.6':'Codex · 30.2'} Tokens/s</span></div><span className="status">运行中</span></div>)}<div className="session completed"><CheckCircle size={18}/><div><strong>雷达额度接口检查</strong><span>已完成 · 2 分钟前</span></div><span className="status">待查看</span></div><p className="session-note">这里承载悬浮窗的任务状态与完成提醒。</p></div>}
     <footer className="detail-footer"><span>额度环显示剩余比例</span><span>{pinned?'已固定 · Esc 收起':'移出收起 · 点击图钉固定'}</span></footer>
    </article>
   </div>
   {demo&&<div className={`demo-cursor step-${step}`}><Cursor size={27} weight="fill"/><span>{step===1?'移向侧栏':step===2?'悬停 · 简略信息':step===3?'点击 · 打开详情': '移出后收起'}</span></div>}
   <div className="desktop-caption" aria-live="polite">{!enabled?'侧栏已关闭':demo?'正在演示 · 鼠标移入与移出':pinned?'详情已固定，按 Esc 收起':isOpen?'第三层 · 详细信息':isPeek?'第二层 · 点击额度环查看详情':'第一层 · 紧凑色条，悬停展开'}</div>
  </section>
  <footer className="page-footer"><span>竖向色条 · 悬停速览 · 点击详情</span><span>交互原型，使用示例数据，尚未接入系统窗口</span></footer>
 </main>
}
