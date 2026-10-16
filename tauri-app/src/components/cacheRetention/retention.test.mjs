import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";
import { retentionAxis, retentionDensity } from "./geometry.ts";
import { withSsrModules } from "../../test/ssrHarness.mjs";

test("the complete 0–80 minute axis stays linear before a single tail break", () => {
  const axis = retentionAxis(14_400);
  const step = axis.x(10) - axis.x(0);
  for (let minute = 10; minute <= 80; minute += 10) assert.ok(Math.abs(axis.x(minute) - axis.x(minute - 10) - step) < 1e-10);
  assert.equal(axis.x(80), 0.82);
  assert.ok(axis.x(80.001) > 0.845);
  assert.equal(axis.x(14_400), 1);
  for (let minute = 81; minute < 14_400; minute += 1) assert.ok(axis.x(minute + 1) > axis.x(minute));
  assert.equal(retentionAxis(20).x(40), 0.5);
});

test("density is counted in real time and hit-rate space before tail compression", () => {
  const point = (seconds, rate) => ({ gapMicroseconds: seconds * 1_000_000, input: 10_000, cached: rate * 10_000 });
  const points = [point(1, 0.91), point(8, 0.92), point(11, 0.91), point(1, 0.01)];
  const density = retentionDensity(points);
  assert.equal(density.max, 2);
  assert.equal(density.count(points[0]), 2);
  assert.equal(density.count(points[2]), 1);
  assert.equal(density.count(points[3]), 1);
});

test("home and low-hit actions share a modal; a changed source drops late previous-source data", async () => {
  const dom = new Window({ url: "http://localhost/" });
  const names = ["window", "document", "navigator", "HTMLElement", "Element", "Node", "Event", "KeyboardEvent", "MouseEvent", "localStorage"];
  const previous = new Map(names.map(name => [name, Object.getOwnPropertyDescriptor(globalThis, name)]));
  for (const name of names) Object.defineProperty(globalThis, name, { configurable: true, writable: true, value: name === "window" ? dom.window : dom.window[name] });
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const a = { canonicalHomeKey: "A", physicalHomeKey: "A", transitionGeneration: 1 };
  const b = { canonicalHomeKey: "B", physicalHomeKey: "B", transitionGeneration: 2 };
  const snapshot = (source, own) => ({ points: [], models: [source], ownRoundCount: own, sourceCount: 0, revision: 1, failures: 0, updatedAtMicroseconds: 1 });
  let lateA;
  dom.window.__TAURI_INTERNALS__ = {
    invoke: async (command, args) => {
      if (command.startsWith("plugin:event|")) return 1;
      if (command === "refresh_cache_retention_snapshot" && args.sourceToken.canonicalHomeKey === "A") return new Promise(resolve => { lateA = resolve; });
      if (command.includes("cache_retention_snapshot")) return snapshot(args.sourceToken.canonicalHomeKey, args.sourceToken.canonicalHomeKey === "A" ? 11 : 22);
      throw Error(command);
    },
    transformCallback: () => 1,
    unregisterCallback: () => {},
  };
  dom.window.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener: () => {} };
  try {
    const React = await import("react");
    const { createRoot } = await import("react-dom/client");
    await withSsrModules(async load => {
      const { CacheRetentionProvider, CacheRetentionHomeCard, CacheUsageNotice } = await load("/src/components/cacheRetention/retention.test.fixture.ts");
      const host = dom.document.createElement("div"); dom.document.body.append(host);
      const root = createRoot(host);
      const render = token => React.createElement(CacheRetentionProvider, { sourceToken: token }, React.createElement(CacheRetentionHomeCard), React.createElement(CacheUsageNotice, { advice: { threadId: "turn", threadTitle: "当前会话", hitRate: 0.1, low: true, timestamp: Date.now() / 1000, idleGapSeconds: 900 } }));
      try {
        await React.act(async () => root.render(render(a)));
        assert.ok(lateA);
        const noticeButton = [...host.querySelectorAll("button")].find(button => button.textContent.includes("打开图表，查看续问建议"));
        assert.ok(noticeButton);
        assert.match(host.textContent, /本轮实际间隔：15.0 分钟/);
        await React.act(async () => noticeButton.click());
        assert.equal(host.querySelectorAll('[role="dialog"]').length, 1);
        assert.match(host.querySelector('[role="dialog"]').textContent, /推荐续问线.*最晚参考线/s);
        await React.act(async () => root.render(render(b)));
        assert.equal(host.querySelector('[role="dialog"]'), null);
        await React.act(async () => lateA(snapshot("OLD_A", 999)));
        await React.act(async () => host.querySelector(".retention-home-card button").click());
        const dialog = host.querySelector('[role="dialog"]');
        assert.match(dialog.textContent, /主会话累计 22 轮/);
        assert.doesNotMatch(dialog.textContent, /OLD_A|999/);
        assert.deepEqual([...dialog.querySelectorAll("select")][0].options.length, 2);
        await React.act(async () => dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape" })));
        assert.equal(host.querySelector('[role="dialog"]'), null);
      } finally { await React.act(async () => root.unmount()); }
    });
  } finally {
    delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    for (const name of names) { const descriptor = previous.get(name); if (descriptor) Object.defineProperty(globalThis, name, descriptor); else delete globalThis[name]; }
    dom.close();
  }
});
