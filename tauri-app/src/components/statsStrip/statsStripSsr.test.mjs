import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { readFile } from "node:fs/promises";
import { withSsrModules } from "../../test/ssrHarness.mjs";

const breakdown = (model, tokens = 1_000_000) => ({ model, eventStartUnix: Date.parse("2026-08-30T00:00:00Z") / 1000,
  breakdown: { inputTokens:tokens,cachedInputTokens:0,outputTokens:0,totalTokens:tokens,calls:1 } });
const stats = { totalTokens:3_000_000,peakDayTokens:1_000_000,peakThreadTokens:2_000_000,
  currentStreakDays:3,longestStreakDays:8,totalCalls:3,totalThreads:2,
  totalInputTokens:3_000_000,totalCachedInputTokens:0,totalOutputTokens:0,
  firstUsageAt:"2026-07-01T00:00:00Z",modelBreakdowns:[breakdown("gpt-5.6-terra")] };
const source = { canonicalHomeKey:"home-a",physicalHomeKey:"disk-a",transitionGeneration:1 };
const identity = {scopeKey:"account-a",plan:"pro",limit:"codex"};
const cycle = (id, extra={}) => ({id,startLowerUnix:null,startUpperUnix:null,endLowerUnix:1788825600,
  endUpperUnix:1788825600,firstObservedUnix:1788220800,lastObservedUnix:1788307200,
  expectedResetUnix:1788825600,current:true,expired:false,earlyEnd:false,pendingReset:false,incomplete:true,...extra});
const settle = async () => { for(let i=0;i<6;i++) await new Promise(resolve=>setTimeout(resolve,0)); };

const dayResult = (cost, issues = [], availableClients = ["codex", "antigravity"]) => ({
  codexRows: [],
  clientRows: cost === null ? [] : [{client:"antigravity",model:"gemini-4-argon",inputTokens:100,
    outputTokens:20,cacheReadTokens:0,cacheWriteTokens:0,requests:1,apiCostUSD:cost,unpricedRequests:0}],
  issues, availableClients,
});

async function openHistoricalDay(container, day = 15) {
  await React.act(async () => {container.querySelector('.model-day-controls button').click(); await settle();});
  await React.act(async () => {container.querySelector('[aria-label="单日日历上个月"]').click(); await settle();});
  const date = new Date(); date.setDate(1); date.setMonth(date.getMonth() - 1);
  const key = `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,"0")}-${day}`;
  await React.act(async () => {container.querySelector(`[aria-label="${key}的模型金额"]`).click(); await settle();});
  return key;
}

test("single-day UI fences delayed dates, Home and clients while retaining a same-day refresh", async () => {
  await withDom(async ({window,container,root,StatsStrip}) => {
    const reads = [];
    window.__TAURI_INTERNALS__ = {invoke: (command,args) => {
      assert.equal(command,"read_model_day_usage");
      return new Promise(resolve => reads.push({args,resolve}));
    }};
    let sourceToken = source, dayClients = ["codex","antigravity"];
    const render = (dayRefreshKey = "1") => root.render(React.createElement(StatsStrip,{
      stats,planLabel:"",clientCosts:{lifetime:[],today:[],sevenDay:[]},sourceToken:{...sourceToken},dayClients,dayRefreshKey,
    }));
    await React.act(async () => {render(); await settle();});
    const firstDay = await openHistoricalDay(container);
    assert.equal(reads.length,1);
    const bounds = reads[0].args;
    assert.equal(new Date(bounds.startUnix*1000).getDate(),15);
    assert.equal(new Date(bounds.endUnix*1000).getDate(),16);
    assert.equal(new Date(bounds.startUnix*1000).getHours(),0);
    await React.act(async () => {container.querySelector(`[aria-label="${firstDay.slice(0,-2)}16的模型金额"]`).click(); await settle();});
    assert.equal(reads.length,2);
    await React.act(async () => {reads[1].resolve(dayResult(1.23)); await settle();});
    assert.match(container.querySelector('.stats-model-cost-total').textContent,/\$1\.23/);
    await React.act(async () => {reads[0].resolve(dayResult(9.99)); await settle();});
    assert.doesNotMatch(container.textContent,/\$9\.99/);
    dayClients = ["antigravity","codex"];
    await React.act(async () => {render(); await settle();});
    assert.equal(reads.length,2,"equivalent source and selected clients do not restart a read");
    await React.act(async () => {render("2"); await settle();});
    assert.match(container.querySelector('.stats-model-cost-total').textContent,/\$1\.23/);
    assert.match(container.textContent,/显示上次可信结果/);
    sourceToken = {...source,canonicalHomeKey:"home-b",transitionGeneration:2};
    await React.act(async () => {render("2"); await settle();});
    assert.equal(container.querySelector('.stats-model-cost-total'),null);
    await React.act(async () => {reads[2].resolve(dayResult(8.88)); reads[3].resolve(dayResult(3.45)); await settle();});
    assert.doesNotMatch(container.textContent,/\$8\.88/);
    assert.match(container.querySelector('.stats-model-cost-total').textContent,/\$3\.45/);
    dayClients = ["antigravity"];
    await React.act(async () => {render("2"); await settle();});
    assert.equal(container.querySelector('.stats-model-cost-total'),null);
    assert.deepEqual(reads[4].args.clients,["antigravity"]);
    await React.act(async () => {reads[4].resolve(dayResult(4.56,[],["antigravity"])); await settle();});
    assert.match(container.querySelector('.stats-model-cost-total').textContent,/\$4\.56/);
    await React.act(async () => {container.querySelectorAll('.model-day-controls button')[1].click(); await settle();});
    assert.ok(container.querySelector('[aria-label="模型费用范围"]'));
    assert.equal(container.querySelector('.model-day-calendar'),null);
  });
});

test("single-day UI distinguishes known partial amounts, unavailable sources and a recorded empty day", async () => {
  await withDom(async ({window,container,root,StatsStrip}) => {
    let result = dayResult(1.23,["Codex 单日记录暂不可读"],["antigravity"]);
    window.__TAURI_INTERNALS__ = {invoke: async () => result};
    const render = dayRefreshKey => root.render(React.createElement(StatsStrip,{
      stats,planLabel:"",clientCosts:{lifetime:[],today:[],sevenDay:[]},dayClients:["codex","antigravity"],dayRefreshKey,
    }));
    await React.act(async () => {render("1"); await settle();});
    await openHistoricalDay(container);
    assert.match(container.querySelector('.stats-model-cost-total').textContent,/已知价格小计.*\$1\.23/);
    assert.match(container.textContent,/Codex 单日记录暂不可读/);
    result = dayResult(null,["来源暂不可读"],[]);
    await React.act(async () => {render("2"); await settle();});
    assert.equal(container.querySelector('.stats-model-cost-total'),null);
    assert.match(container.textContent,/单日金额暂不可用/);
    assert.doesNotMatch(container.querySelector('.stats-model-cost-row').textContent,/\$0\.00/);
    result = dayResult(null);
    await React.act(async () => {render("3"); await settle();});
    assert.match(container.textContent,/该日暂无已记录用量 · \$0\.00/);
    assert.doesNotMatch(container.textContent,/来源暂不可读/);
  });
});

async function withDom(run) {
  const window = new Window(); const restore=installDomGlobals(window);
  globalThis.IS_REACT_ACT_ENVIRONMENT=true;
  try { await withSsrModules(async load => {
    const {createRoot}=await import("react-dom/client");
    const {StatsStrip}=await load("/src/components/StatsStrip.tsx");
    const container=window.document.createElement("div");window.document.body.append(container);
    const root=createRoot(container);
    try { await run({window,container,root,StatsStrip}); } finally { await React.act(async()=>root.unmount()); }
  }); } finally { delete globalThis.IS_REACT_ACT_ENVIRONMENT;restore();window.close(); }
}

test("six lifetime metrics remain visible; legacy reset-minus-seven-day input cannot invent a current period",async()=>{
  await withSsrModules(async load=>{
    const {StatsStrip}=await load("/src/components/StatsStrip.tsx");
    const html=renderToStaticMarkup(React.createElement(StatsStrip,{stats,planLabel:"Pro",preciseDataFresh:true,
      sevenDayResetAtUnix:1788825600,recentUsageFiveMinute:[{startUnix:1788220800,tokens:1_000_000,modelBreakdowns:[breakdown("forbidden-legacy-model")]}]}));
    assert.equal((html.match(/class="stats-cell/g)??[]).length,6);
    assert.match(html,/累计净薅到（估）/);assert.match(html,/历史套餐或模型变化未计入/);
    assert.match(html,/本期模型明细待读取/);assert.match(html,/选择周期/);assert.doesNotMatch(html,/周期日历/);
    assert.doesNotMatch(html,/本7d|forbidden-legacy-model/);
    assert.doesNotMatch(html,/账号归属未核验/);
  });
});

test("observed cycle models isolate unknown references and preserve independent review and boundary usage",async()=>{
  await withDom(async({window,container,root,StatsStrip})=>{
    const calls=[];
    window.__TAURI_INTERNALS__={invoke:async(command,args)=>{
      calls.push([command,args]);
      if(command==="read_quota_cycles") return [cycle("a"),cycle("previous",{current:false,earlyEnd:true,startLowerUnix:1787616000,startUpperUnix:1787616100})];
      return {cycleId:args.cycleId,modelBreakdowns:[breakdown("gpt-5.6-luna"),breakdown("codex-auto-review"),breakdown("GPT-5.6-NewLane")],
        boundaryModelBreakdowns:[breakdown("gpt-6-astra",500)],observedStartUnix:1788220800,observedEndUnix:1788307200};
    }};
    await React.act(async()=>{root.render(React.createElement(StatsStrip,{stats,planLabel:"Pro",sourceToken:source,attributionIdentity:identity,preciseDataFresh:true}));await settle();});
    assert.match(container.querySelector('.quota-calendar-selection').title,/开始记录/);
    assert.equal(container.querySelector('.stats-model-cost-header .quota-calendar-disclosure').textContent,"历史周期");
    assert.equal(container.querySelector('.quota-cycle-calendar'),null);
    assert.match(container.textContent,/Auto Review（Luna）/);assert.match(container.textContent,/Luna/);assert.match(container.textContent,/未知模型/);
    assert.ok([...container.querySelectorAll('[title]')].some(n=>n.title.includes('GPT-5.6-NewLane')));
    assert.doesNotMatch(container.textContent,/GPT-5.6-NewLane/);
    assert.doesNotMatch(container.textContent,/价格未知/);assert.match(container.textContent,/已观测部分[^$]*\$0\.20/);
    assert.match(container.textContent,/参考 \$4\.00/);
    assert.equal(container.querySelector(".stats-quota-boundary-detail"),null);
    assert.ok(calls.every(([,args])=>args.expectedScope==="account-a|pro|codex" && args.sourceToken.canonicalHomeKey==="home-a"));
    await React.act(async()=>{container.querySelector('.quota-calendar-disclosure').click();await settle();});
    const previous=container.querySelector('.quota-calendar-bands button[aria-label^="第 1 期"]');
    await React.act(async()=>{previous.click();await settle();});
    assert.equal(calls.at(-1)[1].cycleId,"previous");
    assert.match(container.querySelector('.quota-calendar-selection').title,/额度已重置/);
    assert.ok(container.querySelector('.quota-cycle-calendar'));
    assert.equal(container.querySelector('.quota-calendar-disclosure').getAttribute("aria-expanded"), "true");
    assert.equal(container.querySelector('[aria-label="模型费用范围"] button').textContent,"历史");
    await React.act(async()=>{container.querySelector('.quota-calendar-return').click();await settle();});
    assert.equal(calls.at(-1)[1].cycleId,"a");
    assert.equal(container.querySelector('.quota-calendar-return'),null);
    assert.equal(container.querySelector('[aria-label="模型费用范围"] button').textContent,"本期");
    const scope=container.querySelector('[aria-label="模型费用范围"]');
    await React.act(async()=>{scope.querySelectorAll("button")[2].click();await settle();});
    assert.match(container.textContent,/Terra/);assert.equal(container.querySelector('[aria-label="周期列表"]'),null);
  });
});

test("late old-Home/account range result is discarded immediately after the source changes",async()=>{
  for (const changeHome of [false,true]) await withDom(async({window,container,root,StatsStrip})=>{
    let resolveOld;
    window.__TAURI_INTERNALS__={invoke:async(command,args)=>{
      if(command==="read_quota_cycles") return [cycle(args.expectedScope)];
      if(args.expectedScope.startsWith("account-a|")) return new Promise(resolve=>{resolveOld=resolve;});
      return {cycleId:args.cycleId,modelBreakdowns:[breakdown("gpt-5.6-terra")],boundaryModelBreakdowns:[],observedStartUnix:1788220800,observedEndUnix:1788307200};
    }};
    const render=(sourceToken,attributionIdentity)=>root.render(React.createElement(StatsStrip,{stats,planLabel:"Pro",sourceToken,attributionIdentity,preciseDataFresh:true}));
    await React.act(async()=>{render(source,identity);await settle();});
    assert.equal(typeof resolveOld,"function");
    await React.act(async()=>{render(changeHome ? {...source,canonicalHomeKey:"home-b",transitionGeneration:2} : source,{...identity,scopeKey:"account-b"});await settle();});
    await React.act(async()=>{resolveOld({cycleId:"account-a|pro|codex",modelBreakdowns:[breakdown("old-account-model")],boundaryModelBreakdowns:[]});await settle();});
    assert.doesNotMatch(container.textContent,/old-account-model/);assert.match(container.textContent,/Terra/);
  });
});

// Original model-cost regressions remain explicit. Fixtures now return native
// observed-period rows rather than assuming resetAt minus a fixed seven days.
function mockCycleRows(window, rows, boundaryRows = []) {
  window.__TAURI_INTERNALS__ = { invoke: async (command, args) => command === "read_quota_cycles"
    ? [cycle("a")]
    : { cycleId: args.cycleId, modelBreakdowns: rows, boundaryModelBreakdowns: boundaryRows,
        observedStartUnix: 1788220800, observedEndUnix: 1788307200 } };
}

test("StatsStrip keeps model costs pending while precise usage is unavailable", async () => {
  await withSsrModules(async load => {
    const { StatsStrip } = await load("/src/components/StatsStrip.tsx");
    const html = renderToStaticMarkup(React.createElement(StatsStrip, {
      stats, planLabel: "Pro", preciseDataFresh: false,
      warnings: [{ source: "usage_precision", message: "精确统计准备中" }],
    }));
    assert.match(html, /本期模型明细待读取/);
    assert.doesNotMatch(html, /今日暂无模型用量/);
    assert.match(html, /用量统计暂不完整/);
    assert.match(html, /查看日志/);
  });
});

test("StatsStrip does not render an anonymous canvas fallback before native cycle models arrive", async () => {
  await withDom(async ({ window, container, root, StatsStrip }) => {
    window.__TAURI_INTERNALS__ = { invoke: async command => command === "read_quota_cycles"
      ? [cycle("a")] : new Promise(() => {}) };
    await React.act(async () => {
      root.render(React.createElement(StatsStrip, {
        stats, planLabel: "Pro", sourceToken: source, attributionIdentity: identity, preciseDataFresh: true,
        sevenDayResetAtUnix: 1788825600,
        recentUsageFiveMinute: [{ startUnix: 1788220800, tokens: 1_000_000, inputTokens: 1_000_000, calls: 1 }],
      }));
      await settle();
    });
    assert.match(container.textContent, /本期模型明细待读取/);
    assert.doesNotMatch(container.textContent, /未知模型|5\.6（未分型）/);
    assert.equal(container.querySelector(".stats-model-cost-total"), null);
  });
});

test("StatsStrip shows an anonymous reference without inventing a zero known subtotal", async () => {
  await withDom(async ({ window, container, root, StatsStrip }) => {
    mockCycleRows(window, [breakdown(null)]);
    await React.act(async () => {
      root.render(React.createElement(StatsStrip, {
        stats, planLabel: "Pro", sourceToken: source, attributionIdentity: identity, preciseDataFresh: true,
      }));
      await settle();
    });
    assert.match(container.textContent, /未知模型/);
    assert.match(container.textContent, /100\.0万/);
    assert.doesNotMatch(container.textContent, /价格未知/);assert.match(container.textContent,/参考 \$4\.00/);
    assert.equal(container.querySelector(".stats-model-cost-empty"), null);
    assert.equal(container.querySelector(".stats-model-cost-total").textContent, "已观测部分 —");
    assert.equal(container.querySelectorAll(".stats-model-cost-primary-card").length, 0);
  });
});

test("one anonymous model cannot hide the known cycle prices or total", async () => {
  for (const model of [null, "  ", "future-model"]) {
    await withDom(async ({ window, container, root, StatsStrip }) => {
      const style=window.document.createElement("style");
      style.textContent=await readFile(new URL("../../styles/global.css",import.meta.url),"utf8");
      window.document.head.append(style);
      mockCycleRows(window, [breakdown("gpt-6-astra"), breakdown(model)]);
      await React.act(async () => {
        root.render(React.createElement(StatsStrip, {
          stats, planLabel: "Pro", sourceToken: source, attributionIdentity: identity, preciseDataFresh: true,
        }));
        await settle();
      });
      assert.equal(container.querySelector(".stats-model-cost-empty"), null);
      assert.equal(container.querySelector(".stats-model-cost-total").textContent, "已观测部分 API $10.0");
      const astra = [...container.querySelectorAll(".stats-model-cost-primary-card")].find(card => card.querySelector("em").textContent === "Astra6");
      assert.equal(astra.querySelector("b").textContent, "$10.0");
      for(const card of container.querySelectorAll(".stats-model-cost-primary-card,.stats-model-cost-secondary-chip")) {
        const computed=window.getComputedStyle(card);
        assert.equal(computed.height,"30px");
        assert.equal(computed.paddingTop,"0px");
        assert.equal(computed.paddingBottom,"0px");
        assert.equal(computed.gridTemplateColumns,"auto minmax(0, 1fr) auto auto auto");
        assert.notEqual(computed.gridTemplateRows,"auto auto");
        assert.equal(window.getComputedStyle(card.querySelector("b")).gridColumn,"5");
        for(const element of card.children)assert.notEqual(window.getComputedStyle(element).gridRow,"2");
        assert.ok(card.title.includes("双击修改该模型颜色"));
        assert.equal(window.getComputedStyle(card.querySelector("em")).textOverflow,"clip");
        assert.equal(window.getComputedStyle(card.querySelector("em")).minWidth,"max-content");
      }
      assert.doesNotMatch(container.textContent, /价格未知/);assert.match(container.textContent,/未知模型.*参考/);
      assert.doesNotMatch(container.textContent, /模型身份待补全|本期模型明细待读取/);
    });
  }
});

test("today and seven-day one-model groups fill the original four-slot row without fake accounting", async () => {
  await withDom(async ({window,container,root,StatsStrip}) => {
    const style=window.document.createElement('style');style.textContent=await readFile(new URL('../../styles/global.css',import.meta.url),'utf8');window.document.head.append(style);
    const unknown={key:'unknown-models',label:'未知模型',tokens:13662755,share:1,costUSD:null,referenceCostUSD:18.9,usesIndependentQuota:false,color:'#888888',sourceModels:['unknown','gemini-pro-default']};
    await React.act(async()=>{root.render(React.createElement(StatsStrip,{stats,planLabel:'',clientCosts:{lifetime:[unknown],sevenDay:[unknown],today:[unknown]}}));await settle();});
    const tabs=container.querySelector('[aria-label="模型费用范围"]').querySelectorAll('button');
    for(const index of [0,1]){
      await React.act(async()=>{tabs[index].click();await settle();});
      assert.equal(container.querySelectorAll('.stats-model-cost-secondary-chip').length,1);
      assert.equal(container.querySelectorAll('.stats-model-cost-placeholder').length,3);
      const card=container.querySelector('.stats-model-cost-secondary-chip');
      assert.equal(card.querySelector('em').textContent,'未知模型');
      assert.match(card.title,/gemini-pro-default/);
      assert.equal(window.getComputedStyle(card.parentElement).gridTemplateColumns,'repeat(auto-fill, minmax(204px, 1fr))');
      assert.equal(window.getComputedStyle(card).height,'30px');
      assert.doesNotMatch(container.querySelector('.stats-model-cost-total').textContent,/\$0/);
    }
    await React.act(async()=>{tabs[2].click();await settle();});
    assert.equal(container.querySelectorAll('.stats-model-cost-placeholder').length,0);
    assert.equal(container.querySelectorAll('.stats-model-cost-secondary-chip').length,1);
  });
});

test("unknown boundary model retains its Tokens without a default-model price", async () => {
  await withDom(async ({ window, container, root, StatsStrip }) => {
    mockCycleRows(window, [breakdown("gpt-5.6-luna")], [breakdown(null, 500)]);
    await React.act(async () => {
      root.render(React.createElement(StatsStrip, {
        stats, planLabel: "Pro", sourceToken: source, attributionIdentity: identity, preciseDataFresh: true,
      }));
      await settle();
    });
    assert.equal(container.querySelector(".stats-quota-boundary-detail"), null);
    assert.doesNotMatch(container.textContent, /未确定所属周期|周期切换附近/);
    assert.ok(container.querySelector(".stats-model-cost-total"));
  });
});

test("StatsStrip keeps trusted cycle model rows visible while marking them stale", async () => {
  await withDom(async ({ window, container, root, StatsStrip }) => {
    mockCycleRows(window, [breakdown("gpt-5.6-sol")]);
    await React.act(async () => {
      root.render(React.createElement(StatsStrip, {
        stats, planLabel: "Pro", sourceToken: source, attributionIdentity: identity, preciseDataFresh: false,
      }));
      await settle();
    });
    assert.match(container.textContent, /正在精准计算中… 显示上次可信结果/);
    assert.match(container.textContent, /Sol/);
    assert.doesNotMatch(container.textContent, /本期模型明细待读取/);
    assert.ok(container.querySelector(".stats-model-cost-total"));
  });
});

test("StatsStrip does not treat the initial warning-free placeholder as real zero usage", async () => {
  await withSsrModules(async load => {
    const { StatsStrip } = await load("/src/components/StatsStrip.tsx");
    const html = renderToStaticMarkup(React.createElement(StatsStrip, {
      stats: { totalTokens: 0, peakDayTokens: 0, peakThreadTokens: 0,
        currentStreakDays: 0, longestStreakDays: 0, totalCalls: 0, totalThreads: 0 },
      planLabel: "计划待读取", preciseDataFresh: false, todayTokens: 0, todayModelBreakdowns: [], warnings: [],
    }));
    assert.match(html, /本期模型明细待读取/);
    assert.doesNotMatch(html, /今日暂无模型用量|本期暂无模型用量/);
  });
});

test("StatsStrip defaults to current observed period and can switch to cumulative and fresh today", async () => {
  await withDom(async ({ window, container, root, StatsStrip }) => {
    mockCycleRows(window, [breakdown("gpt-5.6-luna")]);
    await React.act(async () => {
      root.render(React.createElement(StatsStrip, {
        stats: { ...stats, modelBreakdowns: [breakdown("gpt-5.6-terra"), breakdown("gpt-5.3-codex-spark")] },
        planLabel: "Pro", sourceToken: source, attributionIdentity: identity, preciseDataFresh: false,
        todayTokens: 1_000_000, todayModelBreakdowns: [breakdown("gpt-5.6-sol")], usageSummaryFresh: true,
      }));
      await settle();
    });
    const scope = container.querySelector('[aria-label="模型费用范围"]').querySelectorAll("button");
    assert.equal(scope[0].textContent, "本期");
    assert.equal(scope[0].getAttribute("aria-pressed"), "true");
    assert.match(container.textContent, /Luna/);
    await React.act(async () => { scope[2].click(); await settle(); });
    assert.equal(scope[2].getAttribute("aria-pressed"), "true");
    assert.match(container.textContent, /Terra/);
    assert.match(container.textContent, /Spark 参考 \$1\.75/);
    const spark = [...container.querySelectorAll(".stats-model-cost-secondary-chip")].find(card => card.querySelector("em").textContent === "Spark");
    assert.equal(spark.querySelector("b").textContent, "$1.75");
    assert.match(spark.querySelector(".model-cost-tokens").textContent, /100\.0万/);
    assert.match(spark.querySelector(".model-cost-share").textContent, /50%/);
    assert.match(spark.getAttribute("aria-label"), /不计入总计/);
    await React.act(async () => { scope[1].click(); await settle(); });
    assert.equal(scope[1].getAttribute("aria-pressed"), "true");
    assert.match(container.textContent, /Sol/);
    assert.doesNotMatch(container.textContent, /正在精准计算中/);
  });
});

test("cycle controls distinguish unresolved source validation from a running update and preserve error detail", async () => {
  await withSsrModules(async load => {
    const { QuotaCycleControls } = await load("/src/components/statsStrip/QuotaCycleControls.tsx");
    for (const [error, label] of [
      ["来源记录存在未解决的校验异常，暂不能确认周期明细", "来源待核验"],
      ["周期明细资料正在更新，请等待精准统计更新", "资料正在更新"],
      ["无法读取周期历史", "周期明细读取失败"],
    ]) {
      const html = renderToStaticMarkup(React.createElement(QuotaCycleControls, { cycles: [cycle("a")], selected: cycle("a"), onSelect() {}, error, expanded: false, onToggle() {} }));
      assert.match(html, new RegExp(`role="status" title="${error}">${label}`));
      assert.doesNotMatch(html, />周期明细待读取</);
    }
  });
});

function installDomGlobals(window) {
  const values = {
    document: window.document,
    window,
    navigator: window.navigator,
    Node: window.Node,
    Element: window.Element,
    HTMLElement: window.HTMLElement,
    SVGElement: window.SVGElement,
    Event: window.Event,
    MouseEvent: window.MouseEvent,
    MutationObserver: window.MutationObserver,
    ResizeObserver: window.ResizeObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
  };
  const previous = new Map();
  for (const [name, value] of Object.entries(values)) {
    previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { configurable: true, value, writable: true });
  }
  return () => {
    for (const [name, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else delete globalThis[name];
    }
  };
}


test("uncertain cycle dates use one approximate time without changing accounting bounds", async () => {
  await withSsrModules(async load => {
    const { quotaCycleLabel } = await load("/src/components/statsStrip/QuotaCycleControls.tsx");
    const c = cycle("history", {current:false, startLowerUnix:1788220800, startUpperUnix:1788224400,
      endLowerUnix:1788307200,endUpperUnix:1788310800});
    const before = JSON.stringify(c);
    const label = quotaCycleLabel(c);
    assert.equal((label.match(/约 /g) ?? []).length, 2);
    assert.doesNotMatch(label, /～/);
    assert.equal(JSON.stringify(c), before);
    assert.match(quotaCycleLabel(cycle("current")), /至今/);
  });
});

test("same-day cycle changes share one date row and meet at fractional boundaries", async () => {
  await withSsrModules(async load => {
    const { QuotaCycleCalendar } = await load("/src/components/statsStrip/QuotaCycleCalendar.tsx");
    const at = hour => new Date(2026, 7, 13, hour).getTime() / 1000;
    const make = (id, start, end) => cycle(id, {current:false,startLowerUnix:at(start),startUpperUnix:at(start),endLowerUnix:at(end),endUpperUnix:at(end),firstObservedUnix:at(start),lastObservedUnix:at(end)});
    const cycles = [make("c",12,24),make("b",2,12),make("a",0,2)];
    const html = renderToStaticMarkup(React.createElement(QuotaCycleCalendar,{cycles,selected:cycles[1],onSelect(){}}));
    const window = new Window(); const container = window.document.createElement("div"); container.innerHTML = html;
    const buttons = [...container.querySelectorAll(".quota-calendar-bands button")];
    assert.equal(buttons.length,3);
    assert.equal(new Set(buttons.map(b=>b.parentElement)).size,1);
    for(let i=0;i<2;i++) assert.ok(Math.abs(parseFloat(buttons[i].style.left)+parseFloat(buttons[i].style.width)-parseFloat(buttons[i+1].style.left))<0.00001);
    assert.ok(Math.abs(buttons.reduce((sum,b)=>sum+parseFloat(b.style.width),0)-100/7)<0.00001);
    assert.equal(container.querySelectorAll(".quota-calendar-dates").length,6);
    assert.doesNotMatch(html,/grid-row/);
  });
});

test("planned index repair waits and retries after publication", async () => {
  await withDom(async ({window, container, root, StatsStrip}) => {
    let reads = 0;
    window.__TAURI_INTERNALS__ = {invoke: async (command, args) => {
      if (command === "read_quota_cycles") return [cycle("a")];
      reads += 1;
      return reads === 1
        ? {cycleId: args.cycleId, pendingReason: "周期明细资料正在更新，请等待精准统计更新", modelBreakdowns: [], boundaryModelBreakdowns: []}
        : {cycleId: args.cycleId, pendingReason: null, modelBreakdowns: [breakdown("gpt-5.6-sol")], boundaryModelBreakdowns: [], observedStartUnix:1788220800, observedEndUnix:1788307200};
    }};
    await React.act(async () => {
      root.render(React.createElement(StatsStrip, {stats, planLabel:"Pro", sourceToken:source, attributionIdentity:identity, preciseDataFresh:true}));
      await settle();
    });
    assert.match(container.textContent, /资料正在更新/);
    assert.doesNotMatch(container.textContent, /来源待核验|周期明细读取失败/);
    await React.act(async () => { await new Promise(resolve => setTimeout(resolve, 1100)); await settle(); });
    assert.equal(reads, 2);
    assert.doesNotMatch(container.textContent, /资料正在更新|周期明细读取失败/);
    assert.match(container.textContent, /Sol/);
  });
});

test("period refresh keeps committed amounts visible and equivalent source objects do not restart reads", async () => {
  await withDom(async ({window,container,root,StatsStrip}) => {
    let reads = 0;
    let release;
    window.__TAURI_INTERNALS__ = {invoke: async (command,args) => {
      if (command === "read_quota_cycles") return [cycle("a")];
      reads += 1;
      if (reads > 1) return new Promise(resolve => {release = resolve;});
      return {cycleId:args.cycleId,modelBreakdowns:[breakdown("gpt-5.6-sol")],boundaryModelBreakdowns:[]};
    }};
    const render = updated => root.render(React.createElement(StatsStrip, {
      stats, planLabel:"Pro", sourceToken:{...source}, attributionIdentity:{...identity},
      preciseDataFresh:true, quotaUpdatedAt:updated,
    }));
    await React.act(async () => {render("first"); await settle();});
    const amount = container.querySelector('.stats-model-cost-total').textContent;
    assert.equal(reads,1);
    await React.act(async () => {render("first"); await settle();});
    assert.equal(reads,1, "an equivalent source object is not a new data source");
    await React.act(async () => {render("second"); await settle();});
    assert.equal(reads,2);
    assert.equal(container.querySelector('.stats-model-cost-total').textContent,amount);
    assert.match(container.textContent,/显示上次可信结果/);
    assert.doesNotMatch(container.textContent,/本期模型明细待读取/);
    await React.act(async () => {
      release({cycleId:"a",modelBreakdowns:[breakdown("gpt-6-astra")],boundaryModelBreakdowns:[]});
      await settle();
    });
    assert.notEqual(container.querySelector('.stats-model-cost-total').textContent,amount);
    assert.doesNotMatch(container.textContent,/显示上次可信结果/);
  });
});
