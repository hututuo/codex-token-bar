import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import {renderToStaticMarkup} from "react-dom/server";
import {withSsrModules} from "../test/ssrHarness.mjs";

test("one ranking sorts Codex turns together with labeled local sessions without inventing turns",async()=>withSsrModules(async load=>{
 const {aggregateClientCacheRows}=await load("/src/multiClient/aggregateCacheRanking.ts");
 const {CacheHitRanking}=await load("/src/components/CacheHitRanking.tsx");
 const rows=[{sessionID:"same-id",inputTokens:2000,outputTokens:20,cacheReadTokens:1500,requests:2,lowHitRequests:1,zeroHitRequests:0,lastSeen:1800000000}];
 const extra=[...aggregateClientCacheRows("claudeCode",rows),...aggregateClientCacheRows("opencode",rows)];
 assert.notEqual(extra[0].id,extra[1].id);assert.equal(extra[0].breakdown.cachedInputTokens,1500);
 assert.equal(extra[0].turn,undefined);assert.match(extra[0].title,/Claude CLI.*会话/);
 assert.equal(aggregateClientCacheRows("claudeCode",[{...rows[0],cacheReadTokens:null}]).length,0);
 const cacheUsage={sessions:[],turns:[{id:"turn",sessionId:"session",sessionTitle:"real-codex",timestamp:"2026-10-29T12:00:00Z",turnIndexInSession:2,userPrompt:"question",assistantResponse:"answer",breakdown:{inputTokens:2000,cachedInputTokens:1000,outputTokens:20,totalTokens:2020,calls:2}}]};
 const original=JSON.stringify(cacheUsage);
 const html=renderToStaticMarkup(React.createElement(CacheHitRanking,{cacheUsage,aggregate:true,additionalItems:extra}));
 assert.equal((html.match(/class="ranking-section"/g)??[]).length,1);
 assert.equal((html.match(/class="ranking-row"/g)??[]).length,3);
 assert.match(html,/Codex · 问/);assert.match(html,/Claude CLI · 会话/);assert.match(html,/OpenCode · 会话/);
 assert.equal(JSON.stringify(cacheUsage),original);
}));
