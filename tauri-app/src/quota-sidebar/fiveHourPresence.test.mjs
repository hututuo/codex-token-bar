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
test("missing 5h is absent in bars, rings and detail; measured zero remains present", async () => {
  await withSsrModules(async load => {
    const { SidebarRailContent, QuotaDetails } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    for (const [availability, percent, present] of [["absent", null, false], ["unavailable", 0.75, false], ["measured", null, false], ["measured", 0, true], ["measured", 0.38, true]]) {
      const data = fixture(availability, percent);
      assert.equal(hasFiveHourQuota(availability, percent), present);
      const rest = renderToStaticMarkup(React.createElement(SidebarRailContent, { data, state: { mode: "rest", tab: "quota", pinned: false }, onOpen() {} }));
      assert.equal((rest.match(/class="qs-bar(?: |")/g) || []).length, present ? 3 : 2);
      assert.equal((rest.match(/class="qs-radar-mark"/g) || []).length, 0);
      const hover = renderToStaticMarkup(React.createElement(SidebarRailContent, { data, state: { mode: "hover", tab: "quota", pinned: false }, onOpen() {} }));
      assert.equal(hover.includes("查看五小时额度详情"), present); assert.ok(hover.includes("查看七天额度详情"));
      assert.equal((hover.match(/class="qs-ring"/g) || []).length, present ? 3 : 2);
      const detail = renderToStaticMarkup(React.createElement(QuotaDetails, { data }));
      assert.equal(detail.includes("5 小时额度"), present); assert.ok(detail.includes("7 天额度"));
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
    for (const text of ["今日模型用量", "全部模型为分母", "gpt-6-astra", "60.0%", "模型未知", "今日 Tokens", "累计 Tokens", "今日请求", "3.2 t/s", "主会话 1", "子代理 1"]) assert.ok(html.includes(text), text);
    assert.ok(!html.includes("暂无可信")); assert.ok(!html.includes("other"));
    const queue = [QuotaDetails({ data, onOpenRunning })];
    let activity;
    while (queue.length) {
      const node = queue.shift();
      if (Array.isArray(node)) { queue.push(...node); continue; }
      if (node && typeof node === "object") {
        if (node.type === "button" && node.props.className === "qs-activity") activity = node;
        queue.push(node.props?.children);
      }
    }
    assert.ok(activity); activity.props.onClick(); assert.equal(opened, 1);
  });
});

test("weekly even-pace reference appears only for a measured nonstale snapshot", async () => {
  await withSsrModules(async load => {
    const { QuotaDetails } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const data = fixture("absent", null);
    data.snapshot.sevenDayExpectedRemainingPercent = 0.42;
    let html = renderToStaticMarkup(React.createElement(QuotaDetails, { data }));
    assert.ok(html.includes("此刻参考剩余 42%"));
    data.snapshot.quotaDataStale = true;
    html = renderToStaticMarkup(React.createElement(QuotaDetails, { data }));
    assert.ok(!html.includes("此刻参考剩余"));
    data.snapshot.quotaDataStale = false; data.snapshot.sevenDayAvailability = "unavailable";
    html = renderToStaticMarkup(React.createElement(QuotaDetails, { data }));
    assert.ok(!html.includes("此刻参考剩余"));
  });
});
