
import React,{useState} from 'react';
import {createRoot} from 'react-dom/client';
import {SidebarRailContent} from '/src/quota-sidebar/QuotaSidebarApp.tsx';
import {SidebarModuleSettings} from '/src/quota-sidebar/SidebarModuleSettings.tsx';
import {SidebarCompactBars} from '/src/quota-sidebar/SidebarCompactBars.tsx';
import {visibleSidebarItems} from '/src/quota-sidebar/sidebarLayoutPresentation.ts';
import {normalizeSidebarLayout} from '/src/quota-sidebar/sidebarLayoutModel.ts';
import {defaultClientPreferences} from '/src/multiClient/MultiClientUsage.tsx';
import {useClientQuotaItems,useClientQuotaSelection} from '/src/multiClient/useClientScope.ts';
import '/src/quota-sidebar/QuotaSidebar.css';
import '/src/multiClient/integratedClients.css';
const now=Date.now()/1000, callbacks=new Map(),events=new Map();let counter=0;
const preferences=defaultClientPreferences.map(p=>({...p,enabled:p.client==='claudeCode',showSidebar:p.client==='claudeCode'}));
const snapshot={preferences,summaries:[],diagnostics:[],updatedAt:new Date().toISOString(),detections:[{client:'claudeCode',evidence:'fixture'}],quotas:[{client:'claudeCode',state:'available',source:'fixture',notice:'模拟额度',windows:[{label:'5h',usedPercent:38,resetsAt:new Date(Date.now()+7200000).toISOString()},{label:'7d',usedPercent:16,resetsAt:new Date(Date.now()+345600000).toISOString()}]}]};
window.__TAURI_EVENT_PLUGIN_INTERNALS__={unregisterListener:()=>{}};
window.__TAURI_INTERNALS__={transformCallback:(cb,once=false)=>{const id=++counter;callbacks.set(id,once?(...args)=>{callbacks.delete(id);cb(...args)}:cb);return id},unregisterCallback:id=>callbacks.delete(id),invoke:async(command,args)=>{
 if(command==='refresh_multi_client_usage')return snapshot;
 if(command==='plugin:event|listen'){const id=++counter;events.set(id,{event:args.event,handler:args.handler});return id}
 if(command==='plugin:event|unlisten'){events.delete(args.eventId);return}
 if(command==='plugin:event|emit'||command==='plugin:event|emit_to'){for(const [id,event]of events)if(event.event===args.event)callbacks.get(event.handler)?.({event:args.event,id,payload:args.payload});return}
 throw Error('Fixture rejects command: '+command);
}};
localStorage.setItem('multiClient.displayScope.v1','all');
const quota={fiveHour:{availability:'absent',remainingPercent:null,label:'5h'},sevenDay:{availability:'measured',remainingPercent:.72,label:'7d',resetsAt:new Date(Date.now()+259200000).toISOString()},reserveWindows:[]};
const data={quota:{updatedAt:new Date().toISOString(),account:{planType:'pro'},quota},snapshot:{modelRates:[],tokensPerSecond:96,maxTokensPerSecond:150,liveRateAvailable:true,latestModelSpeeds30m:[],todayModelBreakdowns:[],fiveHourAvailability:'absent',fiveHourRemainingPercent:null,sevenDayAvailability:'measured',sevenDayRemainingPercent:.72,unreadSummary:{source:'pending',label:'',detail:''},totalTokensLabel:'1.2B'},runningThreads:{status:'ready',total:3,mainThreads:2,subagents:1}};
const state={mode:'detail',tab:'settings',section:'top',pinned:true};
function Fixture(){const[layout,setLayout]=useState(()=>normalizeSidebarLayout(null)),[highlighted,setHighlighted]=useState(null);const{catalog,items,selection}=useClientQuotaItems(quota),{save}=useClientQuotaSelection();const visible=visibleSidebarItems(layout,items,true);return <><div className="fixture-label">Tauri 实际组件 · 模拟数据 · 不连接账户／不修改应用</div><div className="fixture"><aside className="fixture-rail"><main className="qs-rail qs-left qs-mode-detail"><SidebarRailContent layout={layout} highlightedItem={highlighted} data={data} state={state} onOpen={()=>{}}/></main></aside><div className="fixture-detail"><section className="qs-detail qs-left"><header><div><strong>Codex <span className="qs-plan">PRO</span></strong><small>候选组件验证</small></div></header><nav><button>额度概览</button><button>测速</button><button>任务</button><button>雷达</button><button aria-selected="true">侧栏设置</button></nav><div className="qs-detail-content"><SidebarModuleSettings layout={layout} catalog={catalog} selection={selection} onLayout={setLayout} onSelection={save} onHighlight={setHighlighted} compactPreview={<SidebarCompactBars items={visible} quotas={items} selection={selection} ratePercent={64} preview/>}/></div></section></div></div></>}
createRoot(document.getElementById('root')).render(<Fixture/>);
