import assert from 'node:assert/strict';
import test from 'node:test';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {Window} from 'happy-dom';
import {withSsrModules} from '../../test/ssrHarness.mjs';
const point=(model,bucketStart,median=40)=>({model,bucketStart,bucketEnd:bucketStart+1800,lowerQuartile:median-5,median,upperQuartile:median+5,bucketCount:4,sampleCount:8,tokensPerSecond:median+9,outputTokens:100,durationSeconds:2,isPartial:false});
test('distribution projection uses quartiles for tight Y bounds and rejects legacy or malformed points',async()=>{
 await withSsrModules(async load=>{
  const {trendPlot}=await load('/src/components/liveRate/BodySpeedTrend.tsx');
  const rows=[point('sol',6400,35),point('sol',8200,40),point('luna',8200,160),point('sol',4000,300),point('sol',10300,80),{...point('sol',9500),median:undefined},{...point('sol',9400),lowerQuartile:60}];
  const plot=trendPlot(rows,10000,3600,'sol');
  assert.deepEqual(plot.rows.map(p=>p.median),[35,40]);
  assert.equal(plot.minimum,27);assert.equal(plot.maximum,48);
  assert.equal(plot.last.median,40);assert.equal(plot.last.tokensPerSecond,49);
  assert.equal(trendPlot(rows,10000,3600,'missing').last,undefined);
 });
});
test('missing intervals have no nearest-value fallback and reset markers never use schedules or unknown starts',async()=>{
 await withSsrModules(async load=>{
  const {distributionsAt,distributionResets}=await load('/src/components/liveRate/BodySpeedTrend.tsx');
  const rows=[point('sol',1000),point('sol',5000)];
  assert.equal(distributionsAt(rows,3000).length,0);
  assert.equal(distributionsAt(rows,2000).length,1);
  assert.deepEqual(distributionResets([{startUpperUnix:null,expectedResetUnix:4000},{startUpperUnix:5000,startLowerUnix:4800,expectedResetUnix:9000}]),[{observedAt:5000,previousAt:4800}]);
 });
});
test('production SVG renders separate IQR rectangles and median rules, not old connected mean lines',async()=>{
 await withSsrModules(async load=>{
  const {SpeedDistributionPlot}=await load('/src/components/liveRate/BodySpeedTrend.tsx');
  const html=renderToStaticMarkup(React.createElement(SpeedDistributionPlot,{points:[point('gpt-6.1-sol',6400),{...point('gpt-6.1-sol',9000),isPartial:true}],minimum:30,maximum:60,asOf:11000,windowSeconds:5000,days:1,resets:[{observedAt:8000,previousAt:7800}],clipId:'test'}));
  const w=new Window();w.document.body.innerHTML=html;
  assert.equal(w.document.querySelectorAll('.bst-band').length,2);
  assert.equal(w.document.querySelectorAll('.bst-median').length,2);
  assert.equal(w.document.querySelectorAll('polyline,circle').length,0);
  assert.equal(w.document.querySelectorAll('.bst-reset').length,1);
  assert.match(w.document.querySelector('.bst-distribution title').textContent,/中位数 40.0.*加权均速 49.0/);
  assert.equal(w.document.querySelectorAll('.bst-median')[1].getAttribute('stroke-dasharray'),'3 2');
  w.happyDOM.abort();
 });
});
