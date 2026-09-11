import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";

const data = {
  snapshot: { fiveHourAvailability: "absent", fiveHourRemainingPercent: null,
    sevenDayAvailability: "measured", sevenDayRemainingPercent: 0.70, quotaDataStale: true },
  runningThreads: { total: 2, status: "ready" },
};
test("primary rows retain large targets while the intrinsic summary is vertically centered", async () => {
  await withSsrModules(async load => {
    const { SidebarRailContent } = await load("/src/quota-sidebar/QuotaSidebarApp.tsx");
    const window = new Window();
    try {
      const css = await readFile(new URL("./QuotaSidebar.css", import.meta.url), "utf8");
      window.document.documentElement.className = "quota-sidebar-document";
      window.document.body.innerHTML = `<style>${css}</style>${renderToStaticMarkup(React.createElement(SidebarRailContent, { data, state: { mode: "hover", pinned: false, tab: "quota" }, error: "test", onOpen() {} }))}`;
      const edge = window.document.querySelector(".qs-radar-edge");
      const edgeStyle = window.getComputedStyle(edge);
      assert.equal(edgeStyle.position, "absolute"); assert.match(css, /\.qs-radar-edge\{[^}]*inset:0[;}]/);
      assert.equal(edgeStyle.pointerEvents, "none"); assert.equal(edgeStyle.display, "none");
      assert.ok(css.includes("@media(prefers-reduced-motion:reduce){.qs-radar-edge[data-active=true]{animation:none;opacity:1}}"));
      const buttons = [...window.document.querySelectorAll(".qs-summary>button")];
      assert.equal(buttons.length, 5);
      for (const button of buttons.filter(button => button.matches(".qs-quota-trigger,.qs-running-trigger"))) {
        const style = window.getComputedStyle(button);
        assert.equal(style.width, "80px"); assert.ok(parseFloat(style.minHeight) >= 44);
        assert.equal(style.flexShrink, "0");
      }
      const summaryStyle = window.getComputedStyle(window.document.querySelector(".qs-summary"));
      assert.equal(summaryStyle.top, "50%");
      assert.equal(summaryStyle.transform, "translateY(-50%)");
      assert.equal(summaryStyle.height, "auto");
      assert.equal(window.getComputedStyle(window.document.querySelector(".qs-recommendations")).fontSize, "9px");
      window.document.documentElement.classList.add("quota-sidebar-fixed-canvas");
      // Startup sets this class before mounting; recreate the DOM in that order.
      window.document.body.innerHTML = window.document.body.innerHTML;
      for (const height of [134, 220, 470, 560]) {
        window.happyDOM.setWindowSize({ width: 16, height });
        const rootStyle = window.getComputedStyle(window.document.documentElement);
        assert.equal(rootStyle.width, "88px"); assert.equal(rootStyle.height, "560px");
        assert.equal(window.getComputedStyle(window.document.querySelector(".qs-summary")).top, "280px");
      }
    } finally { window.close(); }
  });
});
