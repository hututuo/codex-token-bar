import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";

async function withRoot(run) {
  const dom = new Window();
  const keys = ["window", "document", "navigator", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];
  const previous = keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]);
  for (const key of keys) Object.defineProperty(globalThis, key, {
    value: key === "IS_REACT_ACT_ENVIRONMENT" ? true : dom[key], configurable: true, writable: true,
  });
  let root;
  try {
    const { createRoot } = await import("react-dom/client");
    root = createRoot(dom.document.body);
    await withSsrModules(load => run({ dom, root, load }));
  } finally {
    if (root) await React.act(async () => root.unmount());
    for (const [key, descriptor] of previous) descriptor ? Object.defineProperty(globalThis, key, descriptor) : delete globalThis[key];
    dom.close();
  }
}
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
function endOpacity(dom, target) {
  const event = new dom.Event("transitionend", { bubbles: true });
  Object.defineProperty(event, "propertyName", { value: "opacity" });
  target.dispatchEvent(event);
}

test("hidden summary skips children; opacity completion retires outgoing content, preserving its positioning shell", async () => {
  await withRoot(async ({ dom, root, load }) => {
    const { SidebarSummaryLayer } = await load("/src/quota-sidebar/SidebarSummaryLayer.tsx");
    let builds = 0;
    const render = (visible, value) => React.act(async () => root.render(React.createElement(SidebarSummaryLayer, {
      visible, children: () => { builds++; return React.createElement("button", null, value); },
    })));
    await render(false, 0);
    const shell = dom.document.querySelector(".qs-summary");
    for (let i = 1; i <= 30; i++) await render(false, i);
    assert.equal(builds, 0, "hidden snapshots must not evaluate the child tree");
    assert.equal(shell.children.length, 0);
    await render(true, 31);
    assert.equal(shell.textContent, "31");
    await render(false, 31);
    assert.equal(shell.textContent, "31", "outgoing content remains for the fade");
    assert.equal(shell.getAttribute("aria-hidden"), "true");
    assert.equal(shell.hasAttribute("inert"), true);
    await React.act(async () => endOpacity(dom, shell.querySelector("button")));
    assert.equal(shell.textContent, "31", "a nested opacity event cannot retire the parent");
    await React.act(async () => endOpacity(dom, shell));
    assert.equal(shell.children.length, 0);
    const retiredBuilds = builds;
    for (let i = 32; i <= 60; i++) await render(false, i);
    assert.equal(builds, retiredBuilds);
    assert.equal(dom.document.querySelector(".qs-summary"), shell);
    await render(true, 61);
    assert.equal(shell.textContent, "61");
  });
});

test("missing transitionend retires the tree; reopening cancels a pending retirement", async () => {
  await withRoot(async ({ dom, root, load }) => {
    const { SidebarSummaryLayer, SIDEBAR_SUMMARY_RETIRE_MS } = await load("/src/quota-sidebar/SidebarSummaryLayer.tsx");
    const render = (visible, value) => React.act(async () => root.render(React.createElement(SidebarSummaryLayer, {
      visible, children: () => React.createElement("span", null, value),
    })));
    await render(true, "first");
    await render(false, "first");
    await render(true, "reopened");
    await React.act(async () => pause(SIDEBAR_SUMMARY_RETIRE_MS + 30));
    assert.equal(dom.document.querySelector(".qs-summary").textContent, "reopened");
    await render(false, "reopened");
    await React.act(async () => pause(SIDEBAR_SUMMARY_RETIRE_MS + 30));
    assert.equal(dom.document.querySelector(".qs-summary").children.length, 0);
  });
});

test("real rail reopens with current rate, quota presence and agent count without replaying hidden numeric changes", async () => {
  await withRoot(async ({ dom, root, load }) => {
    const { SidebarRailContent } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const calls = [];
    const render = (mode, rate, total, five = false) => React.act(async () => root.render(React.createElement(SidebarRailContent, {
      data: {
        snapshot: { liveRateAvailable: true, tokensPerSecond: rate, todayModelBreakdowns: [],
          fiveHourAvailability: five ? "measured" : "absent", fiveHourRemainingPercent: five ? 0.6 : null,
          sevenDayAvailability: "measured", sevenDayRemainingPercent: 0.4 },
        runningThreads: { total, mainThreads: 1, subagents: total - 1, status: "ready" },
      }, state: { mode, pinned: false, tab: "quota" }, onOpen: (...args) => calls.push(args),
    })));
    await render("hover", 10, 2);
    const summary = dom.document.querySelector(".qs-summary");
    await render("rest", 10, 2);
    assert.equal(summary.querySelectorAll(".qs-ring").length, 2);
    await React.act(async () => endOpacity(dom, summary));
    for (let i = 1; i <= 10; i++) await render("rest", i * 7.5, i, true);
    assert.equal(summary.children.length, 0);
    assert.equal(dom.document.querySelector(".qs-rate-bar i").style.transform, "scaleY(0.5)");
    await render("hover", 100, 10, true);
    assert.equal(summary.querySelectorAll(".qs-ring").length, 3);
    assert.equal(summary.querySelector(".qs-rate-trigger strong").getAttribute("aria-label"), "100.0");
    assert.equal(summary.querySelector(".qs-task-ring strong").getAttribute("aria-label"), "10");
    assert.equal(summary.querySelectorAll(".qs-digit-old").length, 0);
    await React.act(async () => summary.querySelector(".qs-running-trigger").click());
    assert.deepEqual(calls, [["running", "top"]]);
  });
});
