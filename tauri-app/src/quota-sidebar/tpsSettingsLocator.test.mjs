import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";
import { runningThreadFixture } from "../test/runningThreadFixture.mjs";

test("empty TPS has a highlighted settings target but no fake reading or compact dot", async () => {
  await withSsrModules(async load => {
    const { SidebarRailContent } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const dom = new Window();
    const css = await readFile(new URL("./QuotaSidebar.css", import.meta.url), "utf8");
    const data = { snapshot: { latestModelSpeeds30m: [], fiveHourAvailability: "absent", sevenDayAvailability: "absent" },
      runningThreads: runningThreadFixture({ total: 0, status: "ready" }) };
    const render = (state, layout) => {
      dom.document.documentElement.className = "quota-sidebar-document";
      dom.document.body.innerHTML = `<style>${css}</style>${renderToStaticMarkup(React.createElement(SidebarRailContent,
        { data, state, layout, highlightedItem: "tps", onOpen() {} }))}`;
      return dom.document.querySelector('[data-sidebar-item="tps"]');
    };
    try {
      const state = { mode: "detail", tab: "settings", pinned: false };
      const target = render(state);
      assert.ok(target, "settings must keep a real target with zero samples");
      assert.equal(target.dataset.highlighted, "true");
      assert.match(target.textContent, /正文 TPS.*等待采样/s);
      assert.equal(target.querySelector(".qs-median-model"), null);
      assert.ok(target.querySelector("button"), "existing speed-details navigation remains reachable");
      const style = dom.getComputedStyle(target);
      assert.equal(style.width, "80px");
      assert.equal(style.outlineWidth, "1px");
      assert.equal(style.outlineStyle, "solid");
      assert.ok(!["", "transparent", "rgba(0, 0, 0, 0)"].includes(style.outlineColor));
      assert.equal(dom.document.querySelector('.qs-bars [data-sidebar-item="tps"]'), null);
      for (const state of [{ mode: "hover", tab: "quota" }, { mode: "detail", tab: "quota" }, { mode: "rest", tab: "settings" }]) {
        assert.equal(render(state), null, "only open settings retains the empty TPS target");
      }
      for (const hidden of ["hidden", "hiddenExpanded"]) {
        assert.equal(render(state, { version: 1, order: ["tps"], hidden: [], [hidden]: ["tps"] }), null,
          "settings respects explicitly hidden TPS");
      }
      assert.deepEqual(data.snapshot.latestModelSpeeds30m, [], "the locator does not invent data");
    } finally { dom.close(); }
  });
});
