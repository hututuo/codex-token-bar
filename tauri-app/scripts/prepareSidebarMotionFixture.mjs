import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {withSsrModules} from '../src/test/ssrHarness.mjs';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const output=resolve(process.argv[2] ?? '../runs/sidebar-motion');
await mkdir(output,{recursive:true});
await withSsrModules(async load => {
 const {SidebarRailContent}=await load('/src/quota-sidebar/QuotaSidebarApp.tsx');
 const data={snapshot:{fiveHourAvailability:'absent',fiveHourRemainingPercent:null,sevenDayAvailability:'measured',sevenDayRemainingPercent:.42,tokensPerSecond:123,liveRateAvailable:true,sevenDayExpectedRemainingPercent:70,todayModelBreakdowns:[{model:'gpt-6-astra',breakdown:{totalTokens:80}},{model:'gpt-5.6-sol',breakdown:{totalTokens:20}}],quotaDataStale:false},runningThreads:{total:4,mainThreads:1,subagents:3,status:'ready'}};
 const css=(await readFile(root+'src/styles/global.css','utf8'))+(await readFile(root+'src/quota-sidebar/QuotaSidebar.css','utf8'));
 for(const mode of ['rest','hover']) await writeFile(`${output}/${mode}.html`,`<!doctype html><html class="quota-sidebar-document quota-sidebar-fixed-canvas"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><style>${css}</style></head><body><div id="root"><main class="qs-rail qs-right qs-mode-${mode}">${renderToStaticMarkup(React.createElement(SidebarRailContent,{data,state:{mode},onOpen(){}}))}</main></div></body></html>`);
 const windowsHtml=(await readFile(`${output}/hover.html`,'utf8')).replace('quota-sidebar-document quota-sidebar-fixed-canvas','quota-sidebar-document quota-sidebar-fixed-canvas quota-sidebar-windows-canvas');
 await writeFile(`${output}/hover-windows.html`,windowsHtml);
});
