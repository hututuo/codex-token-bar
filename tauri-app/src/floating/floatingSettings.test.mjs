import test from "node:test";
import assert from "node:assert/strict";
import {
  FLOATING_BASE_WIDTH,
  FLOATING_DEFAULT_HEIGHT,
  FLOATING_MIN_HEIGHT,
  CURRENT_FLOATING_PAGING_GUIDE_REVISION,
  DEFAULT_FLOATING_SETTINGS,
  floatingGradientBackground,
  sanitizeFloatingSettings,
  shouldPresentFloatingPagingGuide,
} from "./floatingSettings.ts";

test("floating dimensions keep compact Swift-style proportions", () => {
  assert.equal(FLOATING_BASE_WIDTH, 308);
  assert.equal(FLOATING_MIN_HEIGHT, 88);
  assert.equal(FLOATING_DEFAULT_HEIGHT, 140);
});

test("sanitizeFloatingSettings keeps valid gradient palette values", () => {
  const settings = sanitizeFloatingSettings({
    opacity: 0.78,
    scale: 1.22,
    tokenRateFullScale: 260,
    unreadEffect: "shimmer",
    gradientStart: "#ABCDEF",
    gradientEnd: "#123456",
    gradientDirection: "90deg",
    gradientType: "conic",
    quotaColorMode: "fixed",
    quotaFixedColor: "#ABCDEF",
    pagingGuideRevision: 3.8,
  });

  assert.equal(settings.gradientStart, "#abcdef");
  assert.equal(settings.gradientEnd, "#123456");
  assert.equal(settings.gradientDirection, "90deg");
  assert.equal(settings.gradientType, "conic");
  assert.equal(settings.quotaColorMode, "fixed");
  assert.equal(settings.quotaFixedColor, "#abcdef");
  assert.equal(settings.tokenRateFullScale, 260);
  assert.equal(settings.pagingGuideRevision, 3);
});

test("sanitizeFloatingSettings falls back for invalid gradient palette values", () => {
  const settings = sanitizeFloatingSettings({
    opacity: 2,
    scale: 3,
    tokenRateFullScale: 900,
    unreadEffect: "sparkle",
    gradientStart: "blue",
    gradientEnd: "#12",
    gradientDirection: "270deg",
    gradientType: "mesh",
    quotaColorMode: "rainbow",
    quotaFixedColor: "navy",
  });

  assert.equal(settings.opacity, 1);
  assert.equal(settings.scale, 1.38);
  assert.equal(settings.unreadEffect, DEFAULT_FLOATING_SETTINGS.unreadEffect);
  assert.equal(settings.gradientStart, DEFAULT_FLOATING_SETTINGS.gradientStart);
  assert.equal(settings.gradientEnd, DEFAULT_FLOATING_SETTINGS.gradientEnd);
  assert.equal(settings.gradientDirection, DEFAULT_FLOATING_SETTINGS.gradientDirection);
  assert.equal(settings.gradientType, DEFAULT_FLOATING_SETTINGS.gradientType);
  assert.equal(settings.quotaColorMode, DEFAULT_FLOATING_SETTINGS.quotaColorMode);
  assert.equal(settings.quotaFixedColor, DEFAULT_FLOATING_SETTINGS.quotaFixedColor);
  assert.equal(settings.tokenRateFullScale, 400);
});

test("floatingGradientBackground reuses the configured panel gradient", () => {
  assert.equal(floatingGradientBackground({
    gradientStart: "#102040",
    gradientEnd: "#40a0ff",
    gradientDirection: "90deg",
    gradientType: "linear",
  }), "linear-gradient(90deg, #102040, #40a0ff)");
  assert.equal(floatingGradientBackground({
    gradientStart: "#102040",
    gradientEnd: "#40a0ff",
    gradientDirection: "135deg",
    gradientType: "radial",
  }), "radial-gradient(circle at 18% 10%, #102040, #40a0ff)");
});

test("sanitizeFloatingSettings defaults missing token rate full scale to Swift-style 200 tok/s", () => {
  const settings = sanitizeFloatingSettings({});

  assert.equal(DEFAULT_FLOATING_SETTINGS.tokenRateFullScale, 200);
  assert.equal(settings.tokenRateFullScale, 200);
  assert.equal(DEFAULT_FLOATING_SETTINGS.pagingGuideRevision, 0);
  assert.equal(settings.pagingGuideRevision, 0);
  assert.equal(CURRENT_FLOATING_PAGING_GUIDE_REVISION, 4);
});

test("sanitizeFloatingSettings clamps invalid paging guide revisions without replaying future guides", () => {
  assert.equal(sanitizeFloatingSettings({ pagingGuideRevision: -3 }).pagingGuideRevision, 0);
  assert.equal(sanitizeFloatingSettings({ pagingGuideRevision: Number.NaN }).pagingGuideRevision, 0);
  assert.equal(sanitizeFloatingSettings({ pagingGuideRevision: 4.9 }).pagingGuideRevision, 4);
});

test("floating paging guide shows once per revision and reappears only after a revision upgrade", () => {
  const base = {
    settingsLoaded: true,
    setupGuideCompleted: true,
    pagingGuideDismissed: false,
    hasPagedRows: true,
  };

  assert.equal(
    shouldPresentFloatingPagingGuide({ ...base, pagingGuideRevision: 0 }),
    true,
    "a completed setup with an unseen revision shows the guide",
  );
  assert.equal(
    shouldPresentFloatingPagingGuide({
      ...base,
      pagingGuideRevision: CURRENT_FLOATING_PAGING_GUIDE_REVISION,
    }),
    false,
    "completion at the current revision hides the guide on later launches",
  );
  assert.equal(
    shouldPresentFloatingPagingGuide({ ...base, pagingGuideRevision: 2 }),
    true,
    "a code revision upgrade reopens the guide for an older completion",
  );
  assert.equal(
    shouldPresentFloatingPagingGuide({ ...base, pagingGuideRevision: 4 }),
    false,
    "a completion from a newer revision never replays an older guide",
  );
  assert.equal(
    shouldPresentFloatingPagingGuide({ ...base, pagingGuideRevision: 0, pagingGuideDismissed: true }),
    false,
    "an in-flight completion dismissal prevents a stale settings event from reviving the guide",
  );
  assert.equal(
    shouldPresentFloatingPagingGuide({ ...base, pagingGuideRevision: 0, settingsLoaded: false }),
    false,
    "startup does not present before the authoritative settings read or event",
  );
});

test("sanitizeFloatingSettings migrates legacy content order with running threads visible after metrics", () => {
  const settings = sanitizeFloatingSettings({
    contentVisibility: {
      showMetrics: true,
      order: ["quota", "metrics", "radar"],
    },
  });

  assert.equal(settings.contentVisibility.showRunningThreads, true);
  assert.deepEqual(settings.contentVisibility.order, [
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
  assert.deepEqual(settings.contentVisibility.pagePairs, [["todayModelShare", "todayModelCost"]]);
});
