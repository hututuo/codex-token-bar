import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("activity modes expose the current choice with aria-pressed", async () => {
  await withSsrModules(async (load) => {
    const { ActivityModeSelector } = await load("/src/components/tokenActivity/ActivityModeSelector.tsx");
    const html = renderToStaticMarkup(React.createElement(ActivityModeSelector, {
      mode: "weekly",
      onModeChange: () => {},
    }));

    assertButtonPressed(html, "每日", false);
    assertButtonPressed(html, "每周", true);
    assertButtonPressed(html, "累计", false);
    assertButtonPressed(html, "模型", false);
    assertButtonPressed(html, "费用", false);
    assertButtonPressed(html, "命中率", false);
    assertButtonPressed(html, "额度", false);
  });
});

test("recent usage range and line toggles expose selected state with aria-pressed", async () => {
  const window = new Window({ url: "http://localhost/" });
  const previousWindow = globalThis.window;
  globalThis.window = window;
  try {
    window.localStorage.setItem("recentChartRange", "7d");
    window.localStorage.setItem("recentChartVisibility", JSON.stringify({
      tokens: true,
      calls: false,
      cacheHitRate: true,
      fiveHourQuota: false,
      sevenDayQuota: true,
    }));
    await withSsrModules(async (load) => {
      const { RecentUsageChart } = await load("/src/components/RecentUsageChart.tsx");
      const html = renderToStaticMarkup(React.createElement(RecentUsageChart, {
        recentUsage24h: [],
        recentUsage7d: [],
        recentUsage30d: [],
        fiveHourQuotaPresent: false,
        sevenDayQuotaPresent: true,
      }));

      assertButtonPressed(html, "24h", false);
      assertButtonPressed(html, "7d", true);
      assertButtonPressed(html, "30d", false);
      assertButtonPressed(html, "Token", true);
      assertButtonPressed(html, "调用", false);
      assertButtonPressed(html, "命中率", true);
      assert.equal(html.includes(">5h<"), false);
      assertButtonPressed(html, "7d", true);
    });
  } finally {
    if (previousWindow === undefined) delete globalThis.window;
    else globalThis.window = previousWindow;
    window.close();
  }
});

function assertButtonPressed(html, name, pressed) {
  const button = [...html.matchAll(/<button(?<attrs>[^>]*)>(?<body>[\s\S]*?)<\/button>/g)]
    .find((match) => stripTags(match.groups.body).trim() === name);
  assert.ok(button, `Expected button "${name}" in ${html}`);
  assert.match(button.groups.attrs, new RegExp(`aria-pressed="${pressed}"`));
}

function stripTags(value) {
  return value.replace(/<[^>]+>/g, "").replace(/[●○]/g, "");
}
