import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("speed trend separates models and leaves unmeasured buckets disconnected", async () => {
    await withSsrModules(async load => {
        const { trendSegments } = await load("/src/components/liveRate/BodySpeedTrend.tsx");
        const p = (model, bucketStart, tokensPerSecond = 50) => ({ model, bucketStart, tokensPerSecond, outputTokens: 100, durationSeconds: 2, sampleCount: 1 });
        const result = trendSegments([p("a", 0), p("b", 0), p("a", 300), p("a", 900), p("a", 1200, NaN)], 300);
        assert.deepEqual(result.map(rows => rows.map(p => [p.model, p.bucketStart])), [[["a", 0], ["a", 300]], [["a", 900]], [["b", 0]]]);
    });
});

test("focused recent trend excludes another model, old and future points and reports only measured change", async()=>{
 await withSsrModules(async load=>{
  const {trendPlot}=await load("/src/components/liveRate/BodySpeedTrend.tsx");
  const point=(model,bucketStart,tokensPerSecond)=>({model,bucketStart,tokensPerSecond,outputTokens:100,durationSeconds:2,sampleCount:1});
  const rows=[point("sol",6400,35),point("sol",9700,40),point("luna",9700,160),point("sol",6100,300),point("sol",10300,80)];
  const focused=trendPlot(rows,10000,3600,"sol");
  assert.deepEqual(focused.rows.map(p=>p.tokensPerSecond),[35,40]);
  assert.equal(focused.minimum,30);assert.equal(focused.maximum,45);assert.ok(Math.abs(focused.change-14.285714)<.0001);
  assert.equal(trendPlot(rows,10000,3600,null).change,null);
  assert.equal(trendPlot(rows,10000,3600,"missing").last,undefined);
 });
});
