import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";
import { sidebarRingResetTime } from "./detailsModel.ts";

test("ring reset times use local dates, Unix precedence, and explicit unknowns", () => {
  const local = new Date(2026, 8, 26, 0, 7);
  const reset = sidebarRingResetTime(local.toISOString());
  assert.equal(reset.date, "9/26");
  assert.equal(reset.time, "00:07");
  assert.equal(reset.dateTime, local.toISOString());
  assert.match(reset.title, /重置时间.*本地时间/);
  assert.deepEqual(sidebarRingResetTime("invalid", local.getTime() / 1000), reset);
  assert.deepEqual(sidebarRingResetTime(local.toISOString(), NaN), reset);
  for (const value of [undefined, "", "重置时间未知", "bad date"]) assert.equal(sidebarRingResetTime(value), null);
  assert.equal(sidebarRingResetTime("", 1e30), null);
});

test("both reset labels stay inside the existing rings and absent 5h stays absent", async () => {
  await withSsrModules(async load => {
    const { SidebarRailContent } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const five = new Date(2026, 8, 26, 13, 30);
    const seven = new Date(2026, 9, 2, 8, 5);
    const data = {
      snapshot: { todayModelBreakdowns: [], fiveHourAvailability: "measured", fiveHourRemainingPercent: 0.6, sevenDayAvailability: "measured", sevenDayRemainingPercent: 0.4 },
      runningThreads: { total: 0, status: "ready" },
      quota: { quota: { fiveHour: { resetsAt: five.toISOString() }, sevenDay: { resetsAt: "ignored", resetsAtUnix: seven.getTime() / 1000 } } },
    };
    const dom = new Window();
    const render = () => { dom.document.body.innerHTML = renderToStaticMarkup(React.createElement(SidebarRailContent, { data, state: { mode: "hover" }, onOpen() {} })); };
    try {
      render();
      assert.deepEqual([...dom.document.querySelectorAll(".qs-ring time")].map(time => time.getAttribute("datetime")), [five.toISOString(), seven.toISOString()]);
      assert.equal(dom.document.querySelector(".qs-rate-trigger time"), null);
      data.snapshot.fiveHourAvailability = "absent";
      render();
      assert.equal(dom.document.querySelectorAll(".qs-ring time").length, 1);
      data.quota.quota.sevenDay = { resetsAt: "unknown" };
      render();
      assert.equal(dom.document.querySelector(".qs-ring time"), null);
      assert.equal(dom.document.querySelector(".qs-ring-reset-unknown").textContent, "重置未知");
    } finally { dom.close(); }
  });
});

test("recommendations page through every rank, pause offscreen/hover/focus, and reset on ranking changes", async t => {
  const dom = new Window();
  const keys = ["window", "document", "navigator", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];
  const previous = keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]);
  for (const key of keys) Object.defineProperty(globalThis, key, { value: key === "IS_REACT_ACT_ENVIRONMENT" ? true : dom[key], configurable: true, writable: true });
  let root;
  try {
    const { createRoot } = await import("react-dom/client");
    root = createRoot(dom.document.body);
    await withSsrModules(async load => {
      const { SidebarRecommendations, SIDEBAR_RECOMMENDATION_INTERVAL_MS } = await load("/src/quota-sidebar/SidebarRecommendations.tsx");
      const timers = new Map();
      let timerId = 0;
      t.mock.method(globalThis, "setInterval", (callback, delay) => { assert.equal(delay, SIDEBAR_RECOMMENDATION_INTERVAL_MS); timers.set(++timerId, callback); return timerId; });
      t.mock.method(globalThis, "clearInterval", id => timers.delete(id));
      const rows = Array.from({ length: 8 }, (_, index) => ({ rank: index + 1, model: `gpt-6-model${index + 1}`, effort: "high", iq: 140 - index }));
      let opened = 0;
      const render = (items = rows, visible = true) => React.act(async () => root.render(React.createElement(SidebarRecommendations, { rows: items, visible, onOpen: () => opened++ })));
      const button = () => dom.document.querySelector("button");
      const ranks = () => [...dom.document.querySelectorAll('.qs-recommendation-page:not([aria-hidden="true"]) b')].map(node => Number(node.textContent));
      const tick = () => React.act(async () => { for (const callback of [...timers.values()]) callback(); });
      await render();
      assert.deepEqual(ranks(), [1, 2, 3]);
      assert.equal(timers.size, 1);
      await tick(); assert.deepEqual(ranks(), [4, 5, 6]);
      assert.equal(dom.document.querySelectorAll('.qs-recommendation-out[aria-hidden="true"] b').length, 3);
      await render(rows.map(row => ({ ...row, iq: row.iq + 1 })));
      assert.deepEqual(ranks(), [4, 5, 6], "ordinary data refresh does not restart paging");
      await tick(); assert.deepEqual(ranks(), [7, 8]);
      await tick(); assert.deepEqual(ranks(), [1, 2, 3]);
      await React.act(async () => button().dispatchEvent(new dom.PointerEvent("pointerover", { bubbles: true })));
      assert.equal(timers.size, 0);
      await React.act(async () => button().focus());
      await React.act(async () => button().dispatchEvent(new dom.PointerEvent("pointerout", { bubbles: true })));
      assert.equal(timers.size, 0, "leaving the mouse must not override keyboard focus");
      await React.act(async () => button().blur());
      assert.equal(timers.size, 1);
      await render(rows, false); assert.equal(timers.size, 0);
      await render(); assert.equal(timers.size, 1);
      Object.defineProperty(dom.document, "hidden", { value: true, configurable: true });
      await React.act(async () => dom.document.dispatchEvent(new dom.Event("visibilitychange")));
      assert.equal(timers.size, 0);
      Object.defineProperty(dom.document, "hidden", { value: false, configurable: true });
      await React.act(async () => dom.document.dispatchEvent(new dom.Event("visibilitychange")));
      assert.equal(timers.size, 1);
      await tick(); assert.deepEqual(ranks(), [4, 5, 6]);
      await render(rows.slice().reverse()); assert.deepEqual(ranks(), [8, 7, 6]);
      assert.equal(dom.document.querySelector(".qs-recommendation-out"), null);
      await render(rows.slice(0, 2)); assert.deepEqual(ranks(), [1, 2]); assert.equal(timers.size, 0);
      await render([]); assert.match(button().textContent, /待读取/); assert.equal(timers.size, 0);
      await React.act(async () => button().click()); assert.equal(opened, 1);
      await render(); assert.equal(timers.size, 1);
      await React.act(async () => root.unmount()); root = null;
      assert.equal(timers.size, 0, "unmount retires the timer");
    });
  } finally {
    if (root) await React.act(async () => root.unmount());
    for (const [key, descriptor] of previous) descriptor ? Object.defineProperty(globalThis, key, descriptor) : delete globalThis[key];
    dom.close();
  }
});
