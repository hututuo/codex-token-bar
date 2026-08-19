import assert from "node:assert/strict";
import test from "node:test";
import {
  DEFAULT_FLOATING_CONTENT_VISIBILITY,
  editorGroupsForFloatingRow,
  firstPagedFloatingRowCenterY,
  floatingContentGap,
  floatingContentHeight,
  floatingContentRowHeight,
  initialFloatingPageIndex,
  layoutFloatingContentGroups,
  layoutFloatingContentRows,
  mergeFloatingPage,
  moveFloatingContent,
  moveFloatingRow,
  placeFloatingPageAfterTarget,
  replaceFloatingPagePartner,
  sanitizeFloatingContentVisibility,
  setFloatingGroupsVisible,
  splitFloatingPage,
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
  assert.equal(floatingContentHeight(DEFAULT_FLOATING_CONTENT_VISIBILITY), 140);
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
  assert.equal(migrated.showPageNavigationArrows, false);
});

test("page navigation arrow visibility defaults off and preserves explicit choices", () => {
  assert.equal(DEFAULT_FLOATING_CONTENT_VISIBILITY.showPageNavigationArrows, false);
  assert.equal(sanitizeFloatingContentVisibility({ showPageNavigationArrows: false }).showPageNavigationArrows, false);
  assert.equal(sanitizeFloatingContentVisibility({ showPageNavigationArrows: true }).showPageNavigationArrows, true);
});

test("crowd radar defaults to two pages and clamps settings to one through three", () => {
  assert.equal(DEFAULT_FLOATING_CONTENT_VISIBILITY.crowdRadarPageCount, 2);
  assert.equal(sanitizeFloatingContentVisibility({ crowdRadarPageCount: 0 }).crowdRadarPageCount, 1);
  assert.equal(sanitizeFloatingContentVisibility({ crowdRadarPageCount: 3 }).crowdRadarPageCount, 3);
  assert.equal(sanitizeFloatingContentVisibility({ crowdRadarPageCount: 9 }).crowdRadarPageCount, 3);
});

test("paging guide pointer targets the first real paged row", () => {
  assert.equal(firstPagedFloatingRowCenterY(DEFAULT_FLOATING_CONTENT_VISIBILITY), 58.5);
  assert.equal(firstPagedFloatingRowCenterY(sanitizeFloatingContentVisibility({
    showTodayModelShare: false,
    showTodayModelCost: false,
    pagePairs: [],
  })), null);
});

test("paged radar rows reserve the taller page when switching to crowd radar", () => {
  const visibility = sanitizeFloatingContentVisibility({
    ...DEFAULT_FLOATING_CONTENT_VISIBILITY,
    showRateAndBar: false,
    showUsageStatus: false,
    showMetrics: false,
    showRunningThreads: false,
    showTodayModelShare: false,
    showTodayModelCost: false,
    showQuota: false,
    order: ["radar", "crowdRadar"],
    pagePairs: [["radar", "crowdRadar"]],
  });
  const row = layoutFloatingContentRows(visibility)[0];
  assert.deepEqual(row.groups, ["radar", "crowdRadar"]);
  assert.equal(floatingContentRowHeight(row), 24);
  assert.equal(floatingContentHeight(visibility), 88);
});

test("radar and crowd paging initially shows the ordinary radar", () => {
  assert.equal(initialFloatingPageIndex(["crowdRadar", "radar"]), 1);
  assert.equal(initialFloatingPageIndex(["crowdRadar", "crowdRadar", "radar"]), 2);
  assert.equal(initialFloatingPageIndex(["radar", "crowdRadar"]), 0);
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

test("structure editor moves whole paged and inline rows", () => {
  const rows = layoutFloatingContentRows(DEFAULT_FLOATING_CONTENT_VISIBILITY);
  const metrics = rows.find((row) => row.primaryGroup === "metrics");
  const model = rows.find((row) => row.primaryGroup === "todayModelShare");
  assert.ok(metrics);
  assert.ok(model);
  assert.deepEqual(editorGroupsForFloatingRow(DEFAULT_FLOATING_CONTENT_VISIBILITY, metrics), [
    "metrics",
    "runningThreads",
  ]);
  assert.deepEqual(editorGroupsForFloatingRow(DEFAULT_FLOATING_CONTENT_VISIBILITY, model), [
    "todayModelShare",
    "todayModelCost",
  ]);
  assert.deepEqual(moveFloatingRow(
    DEFAULT_FLOATING_CONTENT_VISIBILITY.order,
    ["todayModelShare", "todayModelCost"],
    ["metrics", "runningThreads"],
    "before",
  ), [
    "rateAndBar",
    "usageStatus",
    "todayModelShare",
    "todayModelCost",
    "metrics",
    "runningThreads",
    "radar",
    "crowdRadar",
    "quota",
  ]);
});

test("structure editor merge split and grouped visibility preserve V01 pairs", () => {
  const mergedPairs = mergeFloatingPage(
    DEFAULT_FLOATING_CONTENT_VISIBILITY.pagePairs,
    "radar",
    "crowdRadar",
  );
  assert.deepEqual(mergedPairs, [
    ["todayModelShare", "todayModelCost"],
    ["crowdRadar", "radar"],
  ]);
  assert.deepEqual(placeFloatingPageAfterTarget(
    DEFAULT_FLOATING_CONTENT_VISIBILITY.order,
    "radar",
    "crowdRadar",
  ).slice(-3), ["crowdRadar", "radar", "quota"]);

  const hidden = setFloatingGroupsVisible({
    ...DEFAULT_FLOATING_CONTENT_VISIBILITY,
    pagePairs: mergedPairs,
  }, ["crowdRadar", "radar"], false);
  assert.equal(hidden.showCrowdRadar, false);
  assert.equal(hidden.showRadar, false);
  assert.deepEqual(hidden.pagePairs, mergedPairs);
  assert.deepEqual(splitFloatingPage(hidden.pagePairs, "radar"), [
    ["todayModelShare", "todayModelCost"],
  ]);
});

test("radar crowd spacing tightens without changing the crowd quota gap", () => {
  assert.equal(floatingContentGap("radar", "crowdRadar"), 0);
  assert.equal(floatingContentGap("crowdRadar", "quota"), 2);
  assert.equal(floatingContentGap("metrics", "radar"), 2);
});
