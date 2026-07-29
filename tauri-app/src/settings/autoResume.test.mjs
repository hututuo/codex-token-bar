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
    assert.equal(result.tasks.length, 1, "legacy single-task settings must migrate");
    assert.equal(result.taskCollectionVersion, 2);
    assert.match(result.selectedTaskId, /^legacy-/);
    assert.equal(result.tasks[0].threadId, "thread-a");
  });
});

test("a versioned empty task collection cannot resurrect a deleted legacy mirror", async () => {
  await withSsrModules(async (load) => {
    const { sanitizeAutoResumeSettings } = await load("/src/settings/autoResume.ts");
    const result = sanitizeAutoResumeSettings({
      taskCollectionVersion: 2,
      selectedTaskId: "",
      tasks: [],
      enabled: true,
      threadId: "stale-deleted-thread",
      threadTitle: "stale title",
      quotaResumeEnabled: true,
    });
    assert.equal(result.taskCollectionVersion, 2);
    assert.deepEqual(result.tasks, []);
    assert.equal(result.selectedTaskId, "");
    assert.equal(result.threadId, "");
    assert.equal(result.threadTitle, "");
    assert.equal(result.enabled, false);
  });
});

test("auto resume sanitizes task collections, removes duplicates, and fails closed without triggers", async () => {
  await withSsrModules(async (load) => {
    const { sanitizeAutoResumeSettings } = await load("/src/settings/autoResume.ts");
    const result = sanitizeAutoResumeSettings({
      selectedTaskId: "duplicate-id",
      tasks: [
        {
          id: "task-a",
          enabled: true,
          threadId: "thread-a",
          threadTitle: "A",
          quotaResumeEnabled: false,
          capacityRecoveryEnabled: false,
          scheduleMode: "off",
        },
        {
          id: "duplicate-id",
          enabled: true,
          threadId: "thread-a",
          threadTitle: "duplicate thread",
        },
        {
          id: "task-b",
          enabled: true,
          threadId: "thread-b",
          threadTitle: "B",
          quotaResumeEnabled: true,
        },
      ],
    });
    assert.equal(result.tasks.length, 2);
    assert.equal(result.tasks[0].enabled, false, "a task without an automatic trigger must not stay protected");
    assert.equal(result.tasks[1].enabled, true);
    assert.equal(result.selectedTaskId, "task-a", "an invalid selected id falls back to the first task");
  });
});

test("timestamp formatting accepts both seconds and milliseconds", async () => {
  await withSsrModules(async (load) => {
    const { formatAutoResumeTimestamp } = await load("/src/settings/autoResume.ts");
    assert.equal(formatAutoResumeTimestamp(null), "尚无");
    assert.equal(formatAutoResumeTimestamp(1_784_000_000), formatAutoResumeTimestamp(1_784_000_000_000));
  });
});
