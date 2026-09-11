import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {withSsrModules} from '../src/test/ssrHarness.mjs';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
const output=new URL('../../runs/20260910-sidebar-density/',import.meta.url);
await mkdir(output,{recursive:true});
await withSsrModules(async load=>{
 const {QuotaDetails,SidebarRailContent}=await load('/src/quota-sidebar/QuotaSidebarApp.tsx');
 const rows=['gpt-6-astra','gpt-5.6-sol','gpt-5.6-luna','gpt-5.6-terra','gpt-5.5'].map((model,i)=>({model,breakdown:{inputTokens:800000/(i+1),cachedInputTokens:600000/(i+1),outputTokens:100000/(i+1),totalTokens:900000/(i+1),calls:100}}));
 const data={snapshot:{todayModelBreakdowns:rows,fiveHourAvailability:'absent',sevenDayAvailability:'measured',sevenDayRemainingPercent:.42,sevenDayExpectedRemainingPercent:70,tokensPerSecond:123,liveRateAvailable:true,todayTokensLabel:'205.5万',totalTokensLabel:'697亿',requestsLabel:'500',trendLabel:'额度使用平稳',resetCreditStandaloneLabel:'重置卡 1',unreadSummary:{source:'local',label:'2 个任务待查看'}},runningThreads:{status:'ready',total:12,mainThreads:3,subagents:9},quota:{quota:{fiveHour:{availability:'absent'},sevenDay:{availability:'measured',remainingPercent:.42,resetsAt:'2026-09-14T03:00:00Z'}}}};
 const css=(await readFile(new URL('../src/styles/global.css',import.meta.url),'utf8'))+(await readFile(new URL('../src/quota-sidebar/QuotaSidebar.css',import.meta.url),'utf8'));
 const body=renderToStaticMarkup(React.createElement(QuotaDetails,{data}));
 const rail=renderToStaticMarkup(React.createElement(SidebarRailContent,{data,state:{mode:'hover'},onOpen(){}}));
 await writeFile(new URL('preview.html',output),`<!doctype html><html><meta charset="utf-8"><style>${css}body{margin:0;padding:30px;display:flex;gap:30px;background:#273c42;font-family:system-ui;color:#edf1e9}*{box-sizing:border-box}button{font:inherit}.qs-detail{width:430px;height:600px;flex:none}.qs-rail{width:88px;height:470px;flex:none}.qs-summary{top:50%}h1{font-size:18px}</style><body class="quota-sidebar-document"><main class="qs-detail"><header><strong>Codex · 额度概览</strong></header><div class="qs-detail-content">${body}</div></main><aside class="qs-rail qs-mode-hover">${rail}</aside></body></html>`);
});
