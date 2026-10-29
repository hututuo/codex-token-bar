import test from "node:test";
import assert from "node:assert/strict";
import { withSsrModules } from "../test/ssrHarness.mjs";
test("activity mode defaults to Bar and never adds both Codex algorithms",async()=>{
 await withSsrModules(async load=>{
  const {normalizeActivitySpeedMode,selectedActivityRates}=await load("/src/multiClient/activitySpeedMode.tsx");
  assert.equal(normalizeActivitySpeedMode(undefined),"bar");assert.equal(normalizeActivitySpeedMode("future"),"bar");
  const bar=[{model:"gpt-6-luna",tokensPerSecond:40}];
  const upstream=[{client:"codex",model:"gpt-6-luna",outputTps:90},{client:"claudeCode",model:"claude-sonnet-4",outputTps:30}];
  assert.equal(selectedActivityRates(bar,upstream,["codex","claudeCode"],"bar").reduce((n,r)=>n+r.tokensPerSecond,0),70);
  assert.equal(selectedActivityRates(bar,upstream,["codex","claudeCode"],"agentSpeed").reduce((n,r)=>n+r.tokensPerSecond,0),120);
  assert.deepEqual(selectedActivityRates(bar,[],["codex"],"agentSpeed"),[]);
  assert.equal(selectedActivityRates([], [{client:"claudeCode",model:"",outputTps:12}], ["claudeCode"],"bar")[0].model,"unknown");
  assert.deepEqual(selectedActivityRates([],[],["codex"],"bar",75),[{model:"unknown",tokensPerSecond:75}]);
  assert.equal(selectedActivityRates(bar,[],["codex"],"bar",20)[0].tokensPerSecond,20);
  assert.deepEqual(selectedActivityRates(bar,[],["codex"],"bar",NaN),[]);
 });
});
test("DSH Gemini and OpenCode contribute only when selected and never duplicate Codex mode", async()=>{
 await withSsrModules(async load=>{
  const {selectedActivityRates}=await load("/src/multiClient/activitySpeedMode.tsx");
  const upstream=[{client:"codex",model:"gpt-6-luna",outputTps:90},
   {client:"deepseek",model:"deepseek-v3",outputTps:10},
   {client:"gemini",model:"gemini-2.5-pro",outputTps:20},
   {client:"opencode",model:"gpt-6-luna",outputTps:30},
   {client:"claudeCode",model:"claude-sonnet-4",outputTps:500}];
  const bar=[{model:"gpt-6-luna",tokensPerSecond:40}],allowed=["codex","deepseek","gemini","opencode"];
  assert.equal(selectedActivityRates(bar,upstream,allowed,"bar").reduce((n,r)=>n+r.tokensPerSecond,0),100);
  assert.equal(selectedActivityRates(bar,upstream,allowed,"agentSpeed").reduce((n,r)=>n+r.tokensPerSecond,0),150);
  assert.equal(selectedActivityRates(bar,upstream,["opencode"],"bar").reduce((n,r)=>n+r.tokensPerSecond,0),30);
 });
});

test("numeric output residuals cannot become a zero-looking unknown model",async()=>withSsrModules(async load=>{
 const {selectedActivityRates}=await load("/src/multiClient/activitySpeedMode.tsx");
 assert.deepEqual(selectedActivityRates([],[{client:"codex",model:"real",outputTps:70},{client:"codex",model:"unknown",outputTps:1e-14}],["codex"],"agentSpeed"),[{model:"real",tokensPerSecond:70}]);
}));
