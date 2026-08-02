import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("attribution leaves the top quota strip and is passed to the 24h selection card", async () => {
  const [quotaStrip, chart, page] = await Promise.all([
    readFile(new URL("../QuotaStrip.tsx", import.meta.url), "utf8"),
    readFile(new URL("../RecentUsageChart.tsx", import.meta.url), "utf8"),
    readFile(new URL("../../pages/DashboardPage.tsx", import.meta.url), "utf8"),
  ]);

  assert.doesNotMatch(quotaStrip, /className="shared-attribution-trigger"/);
  assert.match(quotaStrip, /onAttributionChange/);
  assert.match(page, /sharedAccountAttribution=\{sharedAccountAttribution\}/);
  assert.match(chart, /range === "24h"/);
  assert.match(chart, /fixedSelectionEndIndex !== null/);
  assert.match(chart, /aria-label="选区共享账号归因"/);
  assert.match(chart, /账号实降/);
  assert.match(chart, /本机折算/);
});

test("monitoring settings own the default-on attribution, tier and shared price-model controls", async () => {
  const [dialog, settings] = await Promise.all([
    readFile(new URL("../settings/AppSettingsDialog.tsx", import.meta.url), "utf8"),
    readFile(new URL("../../settings/sharedAccountAttribution.ts", import.meta.url), "utf8"),
  ]);

  assert.match(dialog, /共享账号归因/);
  assert.match(dialog, /共享账号归因雷达套餐/);
  assert.match(dialog, /共享账号归因价格模型/);
  assert.match(settings, /enabled: true/);
  assert.match(settings, /radarTier: "pro20x"/);
});

test("Radar attribution only subscribes to the existing shared client and precise readiness is explicit", async () => {
  const [hook, summary, dashboardData] = await Promise.all([
    readFile(new URL("../../api/useSubscribedCodexRadarSnapshot.ts", import.meta.url), "utf8"),
    readFile(new URL("../../pages/dashboard/DashboardSummarySection.tsx", import.meta.url), "utf8"),
    readFile(new URL("../../state/useDashboardData.ts", import.meta.url), "utf8"),
  ]);

  assert.match(hook, /subscribeCodexRadarState/);
  assert.doesNotMatch(hook, /readCodexRadarState|fetch\(/);
  assert.match(summary, /dashboard\.preciseRecentUsageCoveredAt/);
  assert.match(summary, /dashboard\.preciseRecentUsageFresh === true/);
  assert.doesNotMatch(summary, /usagePrecisionWarnings/);
  assert.match(summary, /dashboard\.attributionIdentity/);
  assert.match(summary, /dashboard\.quotaUpdatedAt/);
  assert.match(dashboardData, /advanceQuotaComparisonObservation/);
  assert.match(dashboardData, /comparison\.shouldRefreshPreciseUsage/);
  assert.doesNotMatch(dashboardData, /quotaTimestampChanged/);
});

test("disabled attribution gates segment, bucket key, storage read and write paths", async () => {
  const source = await readFile(new URL("../QuotaStrip.tsx", import.meta.url), "utf8");
  assert.match(source, /enabled: attributionSettings\.enabled/);
  assert.match(source, /if \(!attributionSettings\.enabled[\s\S]+return null;/);
  assert.match(source, /if \(!attributionSettings\.enabled[\s\S]+return emptyBucketMergeResult\(\);/);
  assert.match(source, /if \(!attributionSettings\.enabled[\s\S]+writeAttributionHighWater/);
  assert.match(source, /if \(!attributionSettings\.enabled[\s\S]+writeAttributionSegment/);
});

test("negative residual uses warning amber rather than failure red", async () => {
  const styles = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");
  const rule = styles.match(/\.shared-attribution-status--negativeResidual\s*\{[^}]+\}/s)?.[0] ?? "";
  assert.match(rule, /#df8020/);
  assert.doesNotMatch(rule, /#d24c58/);
});
