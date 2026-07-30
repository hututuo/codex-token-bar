import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("running thread polling is source-scoped and independent of live-rate enablement", async () => {
  const hook = await readFile(new URL("./useRunningThreadSummary.ts", import.meta.url), "utf8");
  const compact = await readFile(
    new URL("../surfaces/useCompactPanelData.ts", import.meta.url),
    "utf8",
  );
  const dashboard = await readFile(new URL("./useDashboardData.ts", import.meta.url), "utf8");

  assert.match(hook, /const activeSourceToken = sourceToken/);
  assert.match(hook, /readRunningThreadSummary\(activeSourceToken\)/);
  assert.match(hook, /sourceToken\.transitionGeneration/);
  assert.match(hook, /sourceToken\.canonicalHomeKey/);
  assert.match(hook, /sourceToken\.physicalHomeKey/);
  assert.match(hook, /if \(!disposed\)/);
  assert.match(hook, /current\.total === null/);
  assert.match(
    compact,
    /useRunningThreadSummary\(\{\s*active: sourceActive && runningEnabled,\s*sourceToken,/s,
  );
  assert.match(dashboard, /useRunningThreadSummary\(\{\s*active: sourceToken !== null,\s*sourceToken,/s);
  assert.doesNotMatch(
    compact.slice(
      compact.indexOf("const runningThreads = useRunningThreadSummary"),
      compact.indexOf("const quotaLabels"),
    ),
    /liveRateEnabled/,
  );
});
