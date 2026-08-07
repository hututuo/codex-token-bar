import assert from "node:assert/strict";
import test from "node:test";
import {
  DEFAULT_FLOATING_CONTENT_VISIBILITY,
  floatingContentGap,
  floatingContentHeight,
  layoutFloatingContentGroups,
  layoutFloatingContentRows,
  moveFloatingContent,
  replaceFloatingPagePartner,
  sanitizeFloatingContentVisibility,
  swapFloatingDefaultPage,
} from "./floatingContent.ts";
import { floatingTextPaletteForGroup } from "./floatingTextPalette.ts";

test("layoutFloatingContentGroups embeds usage status into adjacent rate row", () => {
  const visibility = sanitizeFloatingContentVisibility({
    ...DEFAULT_FLOATING_CONTENT_VISIBILITY,
    order: ["metrics", "usageStatus", "rateAndBar", "radar", "quota"],
  });

  assert.deepEqual(layoutFloatingContentGroups(visibility), [
    "metrics",
    "todayModelShare",
    "todayModelCost",
    "rateAndBar",
    "radar",
    "crowdRadar",
    "quota",
  ]);
});

test("layoutFloatingContentGroups keeps usage status standalone when it is not adjacent to rate", () => {
  const visibility = sanitizeFloatingContentVisibility({
    ...DEFAULT_FLOATING_CONTENT_VISIBILITY,
    order: ["rateAndBar", "metrics", "usageStatus", "radar", "quota"],
  });

  assert.deepEqual(layoutFloatingContentGroups(visibility), [
    "rateAndBar",
    "metrics",
    "todayModelShare",
    "todayModelCost",
    "usageStatus",
    "radar",
    "crowdRadar",
    "quota",
  ]);
});

test("moveFloatingContent swaps adjacent groups in both directions", () => {
  const order = ["rateAndBar", "usageStatus", "metrics", "radar", "quota"];

  assert.deepEqual(moveFloatingContent(order, "usageStatus", -1), [
    "usageStatus",
    "rateAndBar",
    "metrics",
    "runningThreads",
    "todayModelShare",
    "todayModelCost",
    "radar",
    "crowdRadar",
    "quota",
  ]);
  assert.deepEqual(moveFloatingContent(order, "metrics", 1), [
    "rateAndBar",
    "usageStatus",
    "runningThreads",
    "metrics",
    "todayModelShare",
    "todayModelCost",
    "radar",
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
    showRunningThreads: false,
    showQuota: false,
    showRadar: false,
    showRateAndBar: false,
    showUsageStatus: false,
  }), 88);
  assert.equal(floatingContentHeight(DEFAULT_FLOATING_CONTENT_VISIBILITY), 158);
});

test("adjacent running thread counts attach to the right of metrics", () => {
  assert.deepEqual(layoutFloatingContentGroups(DEFAULT_FLOATING_CONTENT_VISIBILITY), [
    "rateAndBar",
    "metrics",
    "todayModelShare",
    "todayModelCost",
    "radar",
    "crowdRadar",
    "quota",
  ]);

  const separated = sanitizeFloatingContentVisibility({
    ...DEFAULT_FLOATING_CONTENT_VISIBILITY,
    order: ["metrics", "radar", "runningThreads", "quota"],
  });
  assert.deepEqual(layoutFloatingContentGroups(separated), [
    "metrics",
    "radar",
    "crowdRadar",
    "runningThreads",
    "todayModelShare",
    "todayModelCost",
    "quota",
    "rateAndBar",
  ]);
});

test("legacy floating order inserts running threads after metrics and enables it", () => {
  const migrated = sanitizeFloatingContentVisibility({
    showMetrics: true,
    order: ["quota", "metrics", "radar"],
  });

  assert.equal(migrated.showRunningThreads, true);
  assert.deepEqual(migrated.order, [
    "quota",
    "metrics",
    "runningThreads",
    "todayModelShare",
    "todayModelCost",
    "radar",
    "crowdRadar",
    "rateAndBar",
    "usageStatus",
  ]);
  assert.deepEqual(migrated.pagePairs, [["todayModelShare", "todayModelCost"]]);
});

test("paged rows combine model share and cost without losing their configured default page", () => {
  const rows = layoutFloatingContentRows(DEFAULT_FLOATING_CONTENT_VISIBILITY);
  assert.deepEqual(rows.map((row) => row.groups), [
    ["rateAndBar"],
    ["metrics"],
    ["todayModelShare", "todayModelCost"],
    ["radar"],
    ["crowdRadar"],
    ["quota"],
  ]);
  const pairedRadar = replaceFloatingPagePartner(
    DEFAULT_FLOATING_CONTENT_VISIBILITY.pagePairs,
    "radar",
    "crowdRadar",
  );
  assert.deepEqual(pairedRadar, [
    ["todayModelShare", "todayModelCost"],
    ["radar", "crowdRadar"],
  ]);
  assert.deepEqual(swapFloatingDefaultPage(pairedRadar, "crowdRadar"), [
    ["todayModelShare", "todayModelCost"],
    ["crowdRadar", "radar"],
  ]);
});

test("radar crowd spacing tightens without changing the crowd quota gap", () => {
  assert.equal(floatingContentGap("radar", "crowdRadar"), 2);
  assert.equal(floatingContentGap("crowdRadar", "quota"), 4);
  assert.equal(floatingContentGap("metrics", "radar"), 4);
});
