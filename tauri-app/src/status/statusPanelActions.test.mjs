import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("Status panel can acknowledge the same unread baseline as the main dashboard", async () => {
  const source = await readFile(new URL("./StatusPanelApp.tsx", import.meta.url), "utf8");

  assert.match(source, /acknowledgeUnreadSummary/);
  assert.match(source, /acknowledgeUnreadSummary\(acknowledgedSourceToken\)/);
  assert.match(source, /sameCodexHomeSourceToken\(sourceTokenRef\.current, acknowledgedSourceToken\)/);
  assert.match(source, /publishUnreadSummaryChanged/);
  assert.match(source, /onUnreadSummaryChanged/);
  assert.match(source, /标记已读/);
});

test("Unread acknowledgement publishes to the shared compact panel and dashboard listeners", async () => {
  const desktopEvents = await readFile(new URL("../platform/desktopEvents.ts", import.meta.url), "utf8");
  const desktopPlatform = await readFile(new URL("../platform/desktop.ts", import.meta.url), "utf8");
  const dashboardActions = await readFile(new URL("../state/useDashboardActions.ts", import.meta.url), "utf8");
  const dashboardData = await readFile(new URL("../state/useDashboardData.ts", import.meta.url), "utf8");
  const compactSnapshot = await readFile(new URL("../surfaces/useCompactPanelSnapshot.ts", import.meta.url), "utf8");

  assert.match(desktopEvents, /UNREAD_SUMMARY_CHANGED_EVENT = "unread-summary-changed"/);
  assert.match(desktopEvents, /publishUnreadSummaryChanged/);
  assert.match(desktopEvents, /onUnreadSummaryChanged/);
  assert.match(desktopPlatform, /publishUnreadSummaryChanged/);
  assert.match(desktopPlatform, /onUnreadSummaryChanged/);
  assert.match(dashboardActions, /publishUnreadSummaryChanged\(\{[\s\S]*sourceToken,[\s\S]*summary: unreadSummary/);
  assert.match(dashboardData, /onUnreadSummaryChanged/);
  assert.match(compactSnapshot, /onUnreadSummaryChanged/);
  assert.match(compactSnapshot, /codexHomeSourceTokenKey\(payload\.sourceToken\) === requestSourceKey/);
  assert.match(compactSnapshot, /applyUnreadSummary\(payload\.summary\)/);
});
