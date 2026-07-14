import assert from "node:assert/strict";
import test from "node:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { withSsrModules } from "../test/ssrHarness.mjs";

test("floating quota projection distinguishes unavailable compatibility zero from measured endpoints", async () => {
  await withSsrModules(async (load) => {
    const { FloatingPanelSurface } = await load("/src/floating/FloatingPanelPreview.tsx");

    for (const fixture of quotaFixtures()) {
      const html = renderToStaticMarkup(React.createElement(FloatingPanelSurface, {
        settings: floatingSettingsFixture(),
        snapshot: floatingSnapshotFixture(fixture.availability, fixture.remainingPercent),
      }));

      if (fixture.availability === "unavailable") {
        assert.match(html, /role="status"/);
        assert.doesNotMatch(html, /role="meter"/);
        assert.doesNotMatch(html, /aria-valuenow=/);
        assert.doesNotMatch(html, /剩余 0%/);
      } else {
        assert.match(html, /role="meter"/);
        assert.match(html, new RegExp(`aria-valuenow="${fixture.remainingPercent * 100}"`));
        assert.match(html, /--quota-fill-background:linear-gradient\(90deg, color-mix\(in srgb, white 18%, rgb\(/);
      }
    }
  });
});

test("floating quota colors support percentage, fixed, and existing panel gradients", async () => {
  await withSsrModules(async (load) => {
    const { floatingQuotaFillBackground } = await load("/src/floating/FloatingPanelPreview.tsx");
    const adaptiveLow = floatingQuotaFillBackground({
      ...floatingSettingsFixture(),
      quotaColorMode: "adaptive",
    }, 10);
    const adaptiveHigh = floatingQuotaFillBackground({
      ...floatingSettingsFixture(),
      quotaColorMode: "adaptive",
    }, 90);
    const fixed = floatingQuotaFillBackground({
      ...floatingSettingsFixture(),
      quotaColorMode: "fixed",
      quotaFixedColor: "#123456",
    }, 10);
    const panelGradient = floatingQuotaFillBackground({
      ...floatingSettingsFixture(),
      gradientStart: "#102040",
      gradientEnd: "#40a0ff",
      gradientDirection: "90deg",
      gradientType: "linear",
      quotaColorMode: "panelGradient",
    }, 10);

    assert.notEqual(adaptiveLow, adaptiveHigh);
    assert.match(adaptiveLow, /rgb\(/);
    assert.match(adaptiveHigh, /rgb\(/);
    assert.equal(fixed, "#123456");
    assert.equal(panelGradient, "linear-gradient(90deg, #102040, #40a0ff)");
  });
});

test("floating quota projection hides an absent five-hour window and expands seven-day", async () => {
  await withSsrModules(async (load) => {
    const { FloatingPanelSurface } = await load("/src/floating/FloatingPanelPreview.tsx");
    const snapshot = floatingSnapshotFixture("measured", 1);
    snapshot.fiveHourAvailability = "absent";
    snapshot.fiveHourRemainingPercent = null;

    const html = renderToStaticMarkup(React.createElement(FloatingPanelSurface, {
      settings: floatingSettingsFixture(),
      snapshot,
    }));

    assert.doesNotMatch(html, />5h</);
    assert.match(html, />7d</);
    assert.equal((html.match(/role="meter"/g) ?? []).length, 1);
    assert.match(html, /floating-quota floating-quota--single-window/);
  });
});

function quotaFixtures() {
  return [
    { availability: "unavailable", remainingPercent: 0 },
    { availability: "unavailable", remainingPercent: null },
    { availability: "measured", remainingPercent: 0 },
    { availability: "measured", remainingPercent: 1 },
  ];
}

function floatingSnapshotFixture(availability, remainingPercent) {
  return {
    tokensPerSecond: 0,
    maxTokensPerSecond: 200,
    trendLabel: "",
    resetCreditLabel: "",
    totalTokensLabel: "总 0",
    todayTokensLabel: "今 0",
    requestsLabel: "次 0",
    fiveHourLabel: "5h",
    fiveHourAvailability: availability,
    fiveHourRemainingPercent: remainingPercent,
    sevenDayLabel: "7d",
    sevenDayAvailability: availability,
    sevenDayRemainingPercent: remainingPercent,
    unread: false,
    unreadSummary: { active: false, count: 0, label: "无未读", detail: "", source: "test" },
  };
}

function floatingSettingsFixture() {
  return {
    opacity: 0.92,
    scale: 1,
    tokenRateFullScale: 200,
    unreadEffect: "off",
    gradientStart: "#ffffff",
    gradientEnd: "#daefff",
    gradientDirection: "135deg",
    gradientType: "linear",
    quotaColorMode: "adaptive",
    quotaFixedColor: "#1469cc",
    textTone: -1,
    contentVisibility: {
      showRateAndBar: false,
      showUsageStatus: false,
      showMetrics: false,
      showQuota: true,
      showRadar: false,
      order: ["quota"],
    },
  };
}
