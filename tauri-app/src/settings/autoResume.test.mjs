import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("auto resume defaults off and sanitizes quota hysteresis and limits", async () => {
  await withSsrModules(async (load) => {
    const { DEFAULT_AUTO_RESUME_SETTINGS, sanitizeAutoResumeSettings } = await load("/src/settings/autoResume.ts");
    assert.equal(DEFAULT_AUTO_RESUME_SETTINGS.enabled, false);

    const result = sanitizeAutoResumeSettings({
      enabled: true,
      threadId: " thread-a ",
      prompt: " 继续工作 ",
      scheduleMode: "invalid",
      quotaLowThresholdPercent: 20,
      quotaRecoveryThresholdPercent: 10,
      cooldownMinutes: 0,
      maxRunsPerDay: 99,
    });
    assert.equal(result.enabled, true);
    assert.equal(result.threadId, "thread-a");
    assert.equal(result.prompt, "继续工作");
    assert.equal(result.scheduleMode, "off");
    assert.equal(result.quotaLowThresholdPercent, 20);
    assert.equal(result.quotaRecoveryThresholdPercent, 21);
    assert.equal(result.cooldownMinutes, 1);
    assert.equal(result.maxRunsPerDay, 24);
  });
});

test("timestamp formatting accepts both seconds and milliseconds", async () => {
  await withSsrModules(async (load) => {
    const { formatAutoResumeTimestamp } = await load("/src/settings/autoResume.ts");
    assert.equal(formatAutoResumeTimestamp(null), "尚无");
    assert.equal(formatAutoResumeTimestamp(1_784_000_000), formatAutoResumeTimestamp(1_784_000_000_000));
  });
});
