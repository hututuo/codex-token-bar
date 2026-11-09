import { runningThreadFixture } from "../test/runningThreadFixture.mjs";
import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";

const row = model => ({ model, breakdown: {
  inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1_000_000, calls: 1,
} });

function data(rows) {
  const limit = { availability: "measured", remainingPercent: 0.5, resetsAt: "待读取" };
  return {
    quota: { quota: { fiveHour: limit, sevenDay: limit } },
    snapshot: {
      todayModelBreakdowns: rows, unreadSummary: { source: "local", label: "0 未读", detail: "" },
      sevenDayAvailability: "measured", sevenDayRemainingPercent: 0.5,
      todayTokensLabel: "200万", totalTokensLabel: "300万", requestsLabel: "2",
      liveRateAvailable: false, quotaDataStale: false, trendLabel: "用量趋势",
    },
    runningThreads: runningThreadFixture({ total: 0, mainThreads: 0, subagents: 0, status: "ready" }),
  };
}

test("sidebar uses homepage unknown reference grouping and preserves known API costs", async () => {
  await withSsrModules(async load => {
    const { QuotaDetails } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const window = new Window();
    try {
      for (const model of [null, "  ", "future-model"]) {
        for (const mixed of [false, true]) {
          const rows = mixed ? [row("gpt-6-astra"), row(model)] : [row(model)];
          window.document.body.innerHTML = renderToStaticMarkup(React.createElement(QuotaDetails, { data: data(rows) }));
          const metrics = window.document.querySelector(".qs-metrics");
          assert.match(metrics.textContent, /今日 API 等值/);
          assert.doesNotMatch(metrics.textContent, /已知小计/);
          assert.doesNotMatch(metrics.textContent, /价格未知|价格待定/);
          if (mixed) assert.match(metrics.textContent, /\$10\.00/);
          else assert.doesNotMatch(metrics.textContent, /\$/);
          const modelRows = [...window.document.querySelectorAll(".qs-model-row")];
          assert.equal(modelRows.length, rows.length);
          assert.equal(modelRows.filter(item => item.textContent.includes("未知模型")).length, 1);
          assert.equal(modelRows.filter(item => item.textContent.includes("价格未知")).length, 0);
          assert.match(modelRows.find(item => item.textContent.includes("未知模型")).textContent, /参考/);
          if (mixed) assert.match(modelRows.find(item => item.textContent.includes("Astra")).textContent, /\$10\.0/);
        }
      }
    } finally { window.close(); }
  });
});

test("mixed-client sidebar retains ledger fees and never invents unknown cache hits", async () => {
  const dom = new Window({url:"http://localhost/"});
  const previous = new Map();
  for (const [key,value] of Object.entries({window:dom,document:dom.document,navigator:dom.navigator,
    localStorage:dom.localStorage,HTMLElement:dom.HTMLElement,Event:dom.Event,IS_REACT_ACT_ENVIRONMENT:true})) {
    previous.set(key,Object.getOwnPropertyDescriptor(globalThis,key));
    Object.defineProperty(globalThis,key,{configurable:true,writable:true,value});
  }
  dom.localStorage.setItem("multiClient.displayScope.v1","all");
  const today = [
    {client:"claudeCode",model:"claude-opus-5",inputTokens:1_000_000,outputTokens:20,cacheReadTokens:0,cacheWriteTokens:800_000,
      requests:200,apiCostUSD:24.37,unpricedRequests:0,cacheReadComplete:true},
    {client:"antigravity",model:"gemini-pro-default",inputTokens:90,outputTokens:10,cacheReadTokens:null,
      requests:1,apiCostUSD:null,unpricedRequests:1,cacheReadComplete:false},
  ];
  dom.__TAURI_EVENT_PLUGIN_INTERNALS__={unregisterListener(){}};
  dom.__TAURI_INTERNALS__={transformCallback(){return 1;},async invoke(command){
    if(command.startsWith("plugin:event|"))return 1;
    assert.equal(command,"refresh_multi_client_usage");
    return {preferences:[{client:"claudeCode",enabled:true},{client:"antigravity",enabled:true}],summaries:today,
      todaySummaries:today,sevenDaySummaries:today,diagnostics:[],updatedAt:new Date().toISOString()};
  }};
  try {
    const {createRoot}=await import("react-dom/client");
    await withSsrModules(async load=>{
      const {QuotaDetails}=await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
      const container=dom.document.createElement("div");dom.document.body.append(container);
      const root=createRoot(container);
      const input=data([row("gpt-6-astra"),row("unknown")]);
      Object.assign(input.snapshot,{todayTokensValue:2_000_000,todayRequestsValue:2,totalTokensValue:3_000_000});
      try {
        await React.act(async()=>root.render(React.createElement(QuotaDetails,{data:input})));
        const models=[...container.querySelectorAll(".qs-model-row")];
        assert.equal(models.length,3);
        assert.match(models.find(x=>x.textContent.includes("Opus5")).textContent,/\$24\.4/);
        assert.match(container.querySelector(".qs-metrics").textContent,/\$34\.37/);
        assert.equal(models.filter(x=>x.textContent.includes("未知模型")).length,1);
        assert.doesNotMatch(container.textContent,/价格未知/);
        const hit=[...container.querySelectorAll(".qs-metrics > div")].find(x=>x.textContent.includes("今日缓存命中"));
        assert.ok(hit);assert.match(hit.textContent,/—/);
        assert.match(container.querySelector(".qs-token-legend").textContent,/输入（缓存未知）/);
        await React.act(async()=>{
          dom.localStorage.setItem("multiClient.displayScope.v1","antigravity");dom.dispatchEvent(new dom.Event("multiClient.displayScope.v1"));
        });
        assert.equal(container.querySelectorAll(".qs-model-row").length,1);
        assert.doesNotMatch(container.querySelector(".qs-model-usage").textContent,/Opus|Astra/);
      } finally {await React.act(async()=>root.unmount());}
    });
  } finally {
    for(const [key,descriptor] of previous){if(descriptor)Object.defineProperty(globalThis,key,descriptor);else delete globalThis[key];}
    dom.close();
  }
});
