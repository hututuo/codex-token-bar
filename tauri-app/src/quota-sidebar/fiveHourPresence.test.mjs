import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { withSsrModules } from "../test/ssrHarness.mjs";
import { hasFiveHourQuota } from "./model.ts";

function fixture(availability, percent) {
  const fiveHour = { availability, remainingPercent: percent, resetsAt: "明日重置" };
  const sevenDay = { availability: "measured", remainingPercent: 0.73, resetsAt: "周末重置" };
  return { quota: { account: {}, updatedAt: "", quota: { fiveHour, sevenDay } },
    snapshot: { fiveHourAvailability: availability, fiveHourRemainingPercent: percent,
      sevenDayAvailability: "measured", sevenDayRemainingPercent: 0.73,
      unreadSummary: { source: "pending", label: "", detail: "" } },
    runningThreads: { total: 2, status: "ready" } };
}

test("Reserve rings and detail preserve ordinary navigation and remain reachable in the native clip", async () => {
  await withSsrModules(async load => {
    const { SidebarRailContent, QuotaDetails } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const data = fixture("measured", 0);
    data.quota.quota.reserveWindows = [
      { label: "Reserve 5h", availability: "measured", remainingPercent: 0.75, resetsAt: "2h" },
      { label: "Reserve 7d", availability: "measured", remainingPercent: 0.4, resetsAt: "3天" },
    ];
    const hover = renderToStaticMarkup(React.createElement(SidebarRailContent, { data, state: { mode: "hover", tab: "quota", pinned: false }, onOpen() {} }));
    assert.match(hover, /data-scrollable="true"/);
    assert.ok(hover.includes("左侧 Codex 5h"));
    assert.ok(hover.includes("右侧 Codex 7d"));
    assert.ok(hover.includes("储备5h"));
    assert.ok(hover.includes("储备7d"));
    assert.equal((hover.match(/class="integrated-paired-ring"/g) || []).length, 2);
    const detail = renderToStaticMarkup(React.createElement(QuotaDetails, { data }));
    for (const id of ["five", "seven", "Reserve-5h", "Reserve-7d"]) assert.ok(detail.includes(`id="qs-section-${id}"`));
    for (const label of ["Luna 储备 · 5小时", "Luna 储备 · 7天", "75%", "40%"]) assert.ok(detail.includes(label));
    const rest = renderToStaticMarkup(React.createElement(SidebarRailContent, { data, state: { mode: "rest", tab: "quota", pinned: false }, onOpen() {} }));
    assert.equal((rest.match(/class="qs-bar(?: |")/g) || []).length, 6, "speed, four quota windows and task state");
    assert.doesNotMatch(rest, /class="qs-ring"/);
  });
});

test("Unreadable Reserve stays unknown in detail and never creates a zero ring", async () => {
  await withSsrModules(async load => {
    const { SidebarRailContent, QuotaDetails } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const data = fixture("measured", 0.42);
    data.quota.quota.reserveWindows = [{ label: "Reserve 7d", availability: "unavailable", remainingPercent: null, resetsAt: "待读取" }];
    const hover = renderToStaticMarkup(React.createElement(SidebarRailContent, { data, state: { mode: "hover", tab: "quota", pinned: false }, onOpen() {} }));
    assert.match(hover, /data-scrollable="true"/);
    assert.match(hover, /储备7d.*不可用/s);
    const detail = renderToStaticMarkup(React.createElement(QuotaDetails, { data }));
    assert.match(detail, /Luna 储备 · 7天.*不可用/s);
  });
});
test("missing 5h is absent in bars, rings and detail; measured zero remains present", async () => {
  await withSsrModules(async load => {
    const { SidebarRailContent, QuotaDetails } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    for (const [availability, percent, present] of [["absent", null, false], ["unavailable", 0.75, false], ["measured", null, false], ["measured", 0, true], ["measured", 0.38, true]]) {
      const data = fixture(availability, percent);
      assert.equal(hasFiveHourQuota(availability, percent), present);
      const windowPresent = present;
      const rest = renderToStaticMarkup(React.createElement(SidebarRailContent, { data, state: { mode: "rest", tab: "quota", pinned: false }, onOpen() {} }));
      assert.equal((rest.match(/class="qs-bar(?: |")/g) || []).length, windowPresent ? 4 : 3, "speed and task state remain independent of quota presence");
      assert.equal((rest.match(/class="qs-radar-mark"/g) || []).length, 0);
      const hover = renderToStaticMarkup(React.createElement(SidebarRailContent, { data, state: { mode: "hover", tab: "quota", pinned: false }, onOpen() {} }));
      assert.equal(hover.includes("Codex 5h"), windowPresent); assert.ok(hover.includes("Codex 7d"));
      assert.equal((hover.match(/class="qs-ring"/g) || []).length, 1);
      assert.equal((hover.match(/class="integrated-paired-ring"/g) || []).length, 1);
      const detail = renderToStaticMarkup(React.createElement(QuotaDetails, { data }));
      assert.equal(detail.includes("5 小时额度"), windowPresent); assert.ok(detail.includes("7 天额度"));
    }
    assert.equal(hasFiveHourQuota("measured", NaN), false);
    assert.equal(hasFiveHourQuota("measured", Infinity), false);
  });
});

test("rich quota detail renders actual model shares, four metrics and a working task-tab action", async () => {
  await withSsrModules(async load => {
    const { QuotaDetails } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const data = fixture("measured", 0.12);
    Object.assign(data.snapshot, { todayTokensLabel: "今 100", totalTokensLabel: "总 500", requestsLabel: "次 8", liveRateAvailable: true, tokensPerSecond: 3.2,
      todayModelBreakdowns: [ ["gpt-6-astra", 60], ["gpt-5.6-sol", 20], ["gpt-5.6-luna", 10], [null, 5], ["other", 5] ].map(([model, totalTokens]) => ({ model, breakdown: { totalTokens } })) });
    Object.assign(data.runningThreads, { mainThreads: 1, subagents: 1 });
    let opened = 0; const onOpenRunning = () => opened++;
    const html = renderToStaticMarkup(React.createElement(QuotaDetails, { data, onOpenRunning }));
    for (const text of ["今日模型用量", "全部模型为分母", "gpt-6-astra", "60.0%", "今日 Tokens", "累计 Tokens", "今日请求", "3.2 t/s", "主会话 1", "子代理 1"]) assert.ok(html.includes(text), text);
    assert.ok(!html.includes("暂无可信"));
    const dom = new (await import("happy-dom")).Window();
    const names = ["window", "document", "navigator", "HTMLElement", "Element", "Node", "Event", "IS_REACT_ACT_ENVIRONMENT"];
    const previous = names.map(name => [name, Object.getOwnPropertyDescriptor(globalThis,name)]);
    for (const name of names) Object.defineProperty(globalThis,name,{configurable:true,writable:true,value:name === "window" ? dom : name === "IS_REACT_ACT_ENVIRONMENT" ? true : dom[name]});
    const {createRoot} = await import("react-dom/client");
    const root=createRoot(dom.document.body);
    try {
      await React.act(async()=>root.render(React.createElement(QuotaDetails,{data,onOpenRunning})));
      await React.act(async()=>dom.document.querySelector(".qs-activity").click());
      assert.equal(opened,1);
    } finally {
      await React.act(async()=>root.unmount());
      for (const [name,descriptor] of previous) descriptor ? Object.defineProperty(globalThis,name,descriptor) : delete globalThis[name];
      dom.close();
    }
  });
});

test("weekly even-pace reference appears only for a measured nonstale snapshot", async () => {
  await withSsrModules(async load => {
    const { QuotaDetails } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const data = fixture("absent", null);
    data.snapshot.sevenDayExpectedRemainingPercent = 42;
    let html = renderToStaticMarkup(React.createElement(QuotaDetails, { data }));
    assert.ok(html.includes("余量应为 42%"));
    data.snapshot.quotaDataStale = true;
    html = renderToStaticMarkup(React.createElement(QuotaDetails, { data }));
    assert.ok(!html.includes("余量应为"));
    data.snapshot.quotaDataStale = false; data.snapshot.sevenDayAvailability = "unavailable";
    data.quota.quota.sevenDay.availability = "unavailable"; data.quota.quota.sevenDay.remainingPercent = null;
    html = renderToStaticMarkup(React.createElement(QuotaDetails, { data }));
    assert.ok(!html.includes("余量应为"));
  });
});
