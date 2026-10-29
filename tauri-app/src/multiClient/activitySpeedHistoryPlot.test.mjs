import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {Window} from 'happy-dom';
import {withSsrModules} from '../test/ssrHarness.mjs';
const point=(bucketStart,rate=40)=>({bucketStart,value:{weightedOutput:rate*10,coveredSeconds:10}});
test('activity-only day plot retains minute detail, model isolation, gaps and plot clipping',async()=>withSsrModules(async load=>{
 const {ActivitySpeedHistoryPlot}=await load('/src/multiClient/ActivitySpeedHistoryPlot.tsx');
 const rows=[{dimensions:{client:'codex',model:'gpt-6.1-sol',displayMode:'agentSpeed'},halfMinuteTrend:[point(14000),point(14030),point(16000)]},{dimensions:{client:'codex',model:'gpt-6-luna',displayMode:'agentSpeed'},halfMinuteTrend:[point(16000,140)]}];
 const html=renderToStaticMarkup(React.createElement(ActivitySpeedHistoryPlot,{rows,asOf:100000,windowSeconds:86400}));
 const w=new Window();w.document.body.innerHTML=html;
 assert.match(html,/全天活动速率，每30秒一个点/);
 assert.equal(w.document.querySelectorAll('[data-activity-model]').length,2);
 assert.equal(w.document.querySelectorAll('circle').length,4);
 assert.equal((w.document.querySelector('[data-activity-model="gpt-6.1-sol"] path').getAttribute('d').match(/M/g)||[]).length,2);
 assert.ok(w.document.querySelector('g[clip-path]'));
 assert.match(w.document.querySelector('circle title').textContent,/40.0 tok\/s/);
 assert.doesNotMatch(html,/TPS|中位数/);
 w.happyDOM.abort();
}));
test('unknown output price remains unavailable rather than fabricating yuan rates',async()=>withSsrModules(async load=>{
 const {ActivitySpeedHistoryPlot}=await load('/src/multiClient/ActivitySpeedHistoryPlot.tsx');
 const html=renderToStaticMarkup(React.createElement(ActivitySpeedHistoryPlot,{rows:[{dimensions:{client:'codex',model:'missing-price',displayMode:'agentSpeed'},halfMinuteTrend:[point(14000)]}],asOf:100000,windowSeconds:86400,unit:'CN 元/s',fx:7.2}));
 assert.doesNotMatch(html,/<circle/);
}));

test('Bar history cannot enter the fixed Agent Speed plot',async()=>withSsrModules(async load=>{
 const {ActivitySpeedHistoryPlot}=await load('/src/multiClient/ActivitySpeedHistoryPlot.tsx');
 const html=renderToStaticMarkup(React.createElement(ActivitySpeedHistoryPlot,{rows:[{dimensions:{client:'codex',model:'bar-only',displayMode:'bar'},halfMinuteTrend:[point(14000)]}],asOf:100000}));
 assert.doesNotMatch(html,/data-activity-model=|<circle/);
 assert.match(html,/暂无 Agent Speed/);
}));

test('default activity viewport is twelve hours and excludes older day samples',async()=>withSsrModules(async load=>{
 const {ActivitySpeedHistoryPlot}=await load('/src/multiClient/ActivitySpeedHistoryPlot.tsx');
 const html=renderToStaticMarkup(React.createElement(ActivitySpeedHistoryPlot,{rows:[{dimensions:{client:'codex',model:'gpt-6.1-sol',displayMode:'agentSpeed'},halfMinuteTrend:[point(14000),point(58000)]}],asOf:100000}));
 const w=new Window();w.document.body.innerHTML=html;
 assert.match(html,/近12小时活动速率，每30秒一个点/);
 assert.equal(w.document.querySelectorAll('circle').length,1);
 w.happyDOM.abort();
}));
