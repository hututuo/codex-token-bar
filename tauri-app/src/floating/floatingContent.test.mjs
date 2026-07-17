import assert from "node:assert/strict";
import test from "node:test";
import {
  DEFAULT_FLOATING_CONTENT_VISIBILITY,
  floatingContentGap,
  floatingContentHeight,
  layoutFloatingContentGroups,
  moveFloatingContent,
  sanitizeFloatingContentVisibility,
} from "./floatingContent.ts";
import { floatingTextPaletteForGroup } from "./floatingTextPalette.ts";

test("layoutFloatingContentGroups embeds usage status into adjacent rate row", () => {
  const visibility = sanitizeFloatingContentVisibility({
    ...DEFAULT_FLOATING_CONTENT_VISIBILITY,
    order: ["metrics", "usageStatus", "rateAndBar", "radar", "quota"],
  });

  assert.deepEqual(layoutFloatingContentGroups(visibility), ["metrics", "rateAndBar", "radar", "crowdRadar", "quota"]);
});

test("layoutFloatingContentGroups keeps usage status standalone when it is not adjacent to rate", () => {
  const visibility = sanitizeFloatingContentVisibility({
    ...DEFAULT_FLOATING_CONTENT_VISIBILITY,
    order: ["rateAndBar", "metrics", "usageStatus", "radar", "quota"],
  });

  assert.deepEqual(layoutFloatingContentGroups(visibility), ["rateAndBar", "metrics", "usageStatus", "radar", "crowdRadar", "quota"]);
});

test("moveFloatingContent swaps adjacent groups in both directions", () => {
  const order = ["rateAndBar", "usageStatus", "metrics", "radar", "quota"];

  assert.deepEqual(moveFloatingContent(order, "usageStatus", -1), [
    "usageStatus",
    "rateAndBar",
    "metrics",
    "radar",
    "crowdRadar",
    "quota",
  ]);
  assert.deepEqual(moveFloatingContent(order, "metrics", 1), [
    "rateAndBar",
    "usageStatus",
    "radar",
    "metrics",
    "crowdRadar",
    "quota",
  ]);
});

test("floatingTextPaletteForGroup turns text light on dark saturated gradients", () => {
  const palette = floatingTextPaletteForGroup(
    {
      gradientStart: "#001b3a",
      gradientEnd: "#005cc8",
      gradientDirection: "135deg",
      gradientType: "linear",
      opacity: 0.92,
      scale: 1,
      unreadEffect: "ripple",
      textTone: -1,
      contentVisibility: DEFAULT_FLOATING_CONTENT_VISIBILITY,
    },
    "rateAndBar",
    0,
    4,
  );

  assert.equal(palette.primary.startsWith("rgba(255, 255, 255"), true);
  assert.equal(palette.secondary.startsWith("rgba(238, 244, 255"), true);
});

test("floatingContentHeight uses Swift-style vertical protection pixels", () => {
  assert.equal(floatingContentHeight({
    order: [],
    showMetrics: false,
    showQuota: false,
    showRadar: false,
    showRateAndBar: false,
    showUsageStatus: false,
  }), 88);
  assert.equal(floatingContentHeight(DEFAULT_FLOATING_CONTENT_VISIBILITY), 134);
});

test("radar crowd spacing tightens without changing the crowd quota gap", () => {
  assert.equal(floatingContentGap("radar", "crowdRadar"), 2);
  assert.equal(floatingContentGap("crowdRadar", "quota"), 4);
  assert.equal(floatingContentGap("metrics", "radar"), 4);
});
