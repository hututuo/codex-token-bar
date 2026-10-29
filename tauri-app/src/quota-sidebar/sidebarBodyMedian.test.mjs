import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {withSsrModules} from '../test/ssrHarness.mjs';
const row=(bucketStart,outputTokens,durationSeconds=1,sampleCount=2,model='gpt-6.1-sol')=>({bucketStart,outputTokens,durationSeconds,sampleCount,model,tokensPerSecond:outputTokens/durationSeconds});
const values=[row(16200,100,10),row(16500,30),row(16800,100)];
test('fixed half-hour median uses weighted 5m buckets, not pooled mean; even quantiles interpolate',async()=>withSsrModules(async load=>{
 const {sidebarBodyMedian}=await load('/src/quota-sidebar/sidebarBodyMedian.ts');
 const result=sidebarBodyMedian(values,18060),point=result.series[0].slots[5];
 assert.equal(result.end,18000);assert.deepEqual(point,{start:16200,median:30,lower:20,upper:65,bucketCount:3,sampleCount:6});
 assert.equal(sidebarBodyMedian([...values,row(17100,50)],18000).series[0].slots[5].median,40);
}));
test('boundaries, idle expiry, missing bucket counts and duplicate rows cannot fabricate a trend',async()=>withSsrModules(async load=>{
 const {sidebarBodyMedian}=await load('/src/quota-sidebar/sidebarBodyMedian.ts');
 assert.equal(sidebarBodyMedian(values,17999).series.length,0);
 assert.deepEqual(sidebarBodyMedian([...values,row(18000,999),row(18300,999),row(18600,999)],19000),sidebarBodyMedian(values,18000));
 const aged=sidebarBodyMedian(values,19800).series[0];assert.equal(aged.slots[5],null);assert.equal(aged.slots[4].median,30);
 assert.equal(sidebarBodyMedian(values,28800).series.length,0);
 assert.equal(sidebarBodyMedian(values.slice(0,2),18000).series[0].slots[5],null);
 assert.equal(sidebarBodyMedian([row(16200,10,1,1),row(16500,20,1,1),row(16800,30,1,3)],18000).series[0].slots[5],null);
 assert.equal(sidebarBodyMedian([...values,...values],18000).series[0].slots[5].sampleCount,6);
}));
test('models stay separate and invalid rows cannot distort scale',async()=>withSsrModules(async load=>{
 const {sidebarBodyMedian,medianBounds}=await load('/src/quota-sidebar/sidebarBodyMedian.ts');
 const result=sidebarBodyMedian([...values,...[16200,16500,16800].map((t,i)=>row(t,200+i*100,1,2,'gpt-6-luna')),row(17100,100,NaN),row(17400,100,0),row(17701,999)],18000);
 assert.deepEqual(result.series.map(s=>s.slots[5].median),[300,30]);assert.ok(medianBounds(result.series[1]).high<100);
 assert.equal(sidebarBodyMedian(values,NaN).series.length,0);
}));
test('rail shows latest single reading with independent median trend and explicit gaps',async()=>withSsrModules(async load=>{
 const {sidebarBodyMedian}=await load('/src/quota-sidebar/sidebarBodyMedian.ts');const {SidebarBodyMedianContent}=await load('/src/quota-sidebar/SidebarBodyMedianCard.tsx');
 const html=renderToStaticMarkup(React.createElement(SidebarBodyMedianContent,{snapshot:sidebarBodyMedian(values,19800),latest:[{model:"gpt-6.1-sol",tokensPerSecond:72}],error:null,onOpen(){}}));
 assert.match(html,/class="qs-median-heading"><span class="qs-median-title">正文 TPS<\/span><span class="qs-median-caption">近3小时/);
 assert.match(html,/class="qs-median-reading"><span class="qs-median-name"><i[^>]*><\/i>6\.1-sol<\/span><span class="qs-median-value"><b>72\.0<\/b>/);
 assert.match(html,/title="gpt-6\.1-sol 最新 72\.0 TPS/);
 assert.match(html,/中位 —/);assert.match(html,/采样不足/);assert.equal((html.match(/class="qs-median-band"/g)||[]).length,1);assert.equal((html.match(/class="qs-median-tick"/g)||[]).length,1);assert.equal((html.match(/class="qs-median-gap"/g)||[]).length,5);assert.doesNotMatch(html,/<polyline|<path|<circle/);assert.match(html,/中间50%/);assert.doesNotMatch(html,/15分|30分.*均速|最新一条/);
 const failed=renderToStaticMarkup(React.createElement(SidebarBodyMedianContent,{snapshot:null,latest:[{model:'gpt-6.1-sol',tokensPerSecond:72}],error:'读取失败',onOpen(){}}));assert.match(failed,/role="status"/);assert.match(failed,/读取失败/);assert.match(failed,/<b>72.0<\/b>/,'history read failure cannot hide a trusted latest reading');assert.match(failed,/title="gpt-6\.1-sol 最新 72\.0 TPS/);
}));
