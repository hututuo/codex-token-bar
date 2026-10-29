import assert from 'node:assert/strict';
import test from 'node:test';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {Window} from 'happy-dom';
import {withSsrModules} from '../../test/ssrHarness.mjs';
const point=(model,bucketStart,speed=40)=>({model,bucketStart,sampleCount:1,tokensPerSecond:speed,outputTokens:speed*2,durationSeconds:2});
test('day curve retains sparse five-minute weighted measurements and separates models',async()=>withSsrModules(async load=>{
 const {trendPlot,trendSegments}=await load('/src/components/liveRate/BodySpeedTrend.tsx');
 const rows=[point('sol',6400,35),point('sol',6700,40),point('sol',8200,45),point('luna',8200,160),point('sol',4000,300),point('sol',10300,80),point('sol',9400,NaN)];
 const plot=trendPlot(rows,10000,3600,'sol');
 assert.deepEqual(plot.rows.map(p=>p.tokensPerSecond),[35,40,45]);
 assert.equal(plot.minimum,30);assert.equal(plot.maximum,50);assert.equal(plot.last.tokensPerSecond,45);
 assert.deepEqual(trendSegments(plot.rows,300).map(s=>s.length),[2,1]);
 assert.equal(trendPlot(rows,10000,3600,'missing').last,undefined);
 assert.equal(trendSegments(trendPlot(rows,10000,3600,null).rows,300).length,3);
}));
test('reset markers still use accepted observations rather than schedules',async()=>withSsrModules(async load=>{
 const {speedTrendResets}=await load('/src/components/liveRate/BodySpeedTrend.tsx');
 assert.deepEqual(speedTrendResets([{startUpperUnix:null,expectedResetUnix:4000},{startUpperUnix:5000,startLowerUnix:4800,expectedResetUnix:9000}]),[{observedAt:5000,previousAt:4800}]);
}));
test('production chart restores detailed clipped lines, measured dots and complete numeric tooltips',async()=>withSsrModules(async load=>{
 const {SpeedTrendPlot}=await load('/src/components/liveRate/BodySpeedTrend.tsx');
 const html=renderToStaticMarkup(React.createElement(SpeedTrendPlot,{points:[point('gpt-6.1-sol',6400),point('gpt-6.1-sol',6700,45),point('gpt-6.1-sol',9000,50)],minimum:30,maximum:60,asOf:11000,windowSeconds:5000,days:1,resets:[{observedAt:8000,previousAt:7800}],clipId:'test'}));
 const w=new Window();w.document.body.innerHTML=html;
 assert.equal(w.document.querySelectorAll('polyline').length,2);
 assert.equal(w.document.querySelectorAll('circle').length,3);
 assert.equal(w.document.querySelectorAll('.bst-band,.bst-median').length,0);
 assert.equal(w.document.querySelectorAll('.bst-reset').length,1);
 assert.equal(w.document.querySelector('g[clip-path]').getAttribute('clip-path'),'url(#test)');
 assert.match(w.document.querySelector('circle title').textContent,/40.0 TPS.*1段正文.*80 token \/ 2.00秒/);
 w.happyDOM.abort();
}));
