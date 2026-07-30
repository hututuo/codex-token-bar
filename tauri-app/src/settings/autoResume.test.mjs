import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("auto resume defaults off and sanitizes quota hysteresis and limits", async () => {
  await withSsrModules(async (load) => {
    const { DEFAULT_AUTO_RESUME_SETTINGS, sanitizeAutoResumeSettings } = await load("/src/settings/autoResume.ts");
    assert.equal(DEFAULT_AUTO_RESUME_SETTINGS.enabled, false);
    assert.equal(DEFAULT_AUTO_RESUME_SETTINGS.invisibleResumeEnabled, true);
    assert.equal(DEFAULT_AUTO_RESUME_SETTINGS.autoApprovalEnabled, false);

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
    assert.equal(result.invisibleResumeEnabled, false, "legacy custom prompts remain visible");
    assert.equal(result.autoApprovalEnabled, false, "legacy settings must fail closed");
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

test("auto approval is an explicit per-task opt-in", async () => {
  await withSsrModules(async (load) => {
    const { sanitizeAutoResumeTaskSettings } = await load("/src/settings/autoResume.ts");
    const disabled = sanitizeAutoResumeTaskSettings({
      threadId: "thread-a",
    });
    const enabled = sanitizeAutoResumeTaskSettings({
      threadId: "thread-b",
      autoApprovalEnabled: true,
    });
    assert.equal(disabled.autoApprovalEnabled, false);
    assert.equal(enabled.autoApprovalEnabled, true);
  });
});

test("explicit invisible resume mode is independent from the stored prompt", async () => {
  await withSsrModules(async (load) => {
    const { sanitizeAutoResumeTaskSettings } = await load("/src/settings/autoResume.ts");
    const invisibleCustom = sanitizeAutoResumeTaskSettings({
      threadId: "thread-a",
      prompt: "保留但暂不发送",
      invisibleResumeEnabled: true,
    });
    assert.equal(invisibleCustom.prompt, "保留但暂不发送");
    assert.equal(invisibleCustom.invisibleResumeEnabled, true);

    const visibleContinue = sanitizeAutoResumeTaskSettings({
      threadId: "thread-b",
      prompt: "继续",
      invisibleResumeEnabled: false,
    });
    assert.equal(visibleContinue.invisibleResumeEnabled, false);
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

test("legacy capacity recovery migrates to a versioned capacity-only reason policy", async () => {
  await withSsrModules(async (load) => {
    const { sanitizeAutoResumeTaskSettings } = await load("/src/settings/autoResume.ts");
    const legacy = sanitizeAutoResumeTaskSettings({
      threadId: "legacy-thread",
      capacityRecoveryEnabled: true,
      quotaResumeEnabled: false,
    });
    assert.equal(legacy.failureRecoveryPolicyVersion, 2);
    assert.deepEqual(legacy.failureRecoveryReasons, ["serverOverloaded"]);
    assert.equal(legacy.capacityRecoveryEnabled, true);

    const intentionallyEmpty = sanitizeAutoResumeTaskSettings({
      threadId: "new-thread",
      failureRecoveryPolicyVersion: 1,
      failureRecoveryReasons: [],
      capacityRecoveryEnabled: true,
      quotaResumeEnabled: false,
    });
    assert.deepEqual(intentionallyEmpty.failureRecoveryReasons, []);
    assert.equal(intentionallyEmpty.capacityRecoveryEnabled, false);
  });
});

test("failure recovery reasons are canonical, deduplicated, and independently selectable", async () => {
  await withSsrModules(async (load) => {
    const { AUTO_RESUME_FAILURE_REASONS, sanitizeAutoResumeTaskSettings } =
      await load("/src/settings/autoResume.ts");
    const result = sanitizeAutoResumeTaskSettings({
      threadId: "thread-a",
      failureRecoveryPolicyVersion: 1,
      failureRecoveryReasons: [
        "interrupted",
        "network",
        "network",
        "rateLimit",
        "timeout",
        "serverError",
        "unknown",
      ],
      quotaResumeEnabled: false,
    });
    assert.deepEqual(result.failureRecoveryReasons, [
      "internalServerError",
      "interrupted",
    ]);
    assert.equal(result.capacityRecoveryEnabled, true);
    assert.deepEqual(
      AUTO_RESUME_FAILURE_REASONS.map(({ id }) => id),
      [
        "serverOverloaded",
        "httpConnectionFailed",
        "responseStreamConnectionFailed",
        "responseStreamDisconnected",
        "responseTooManyFailedAttempts",
        "internalServerError",
        "interrupted",
        "contextWindowExceeded",
        "sessionBudgetExceeded",
        "unauthorized",
        "badRequest",
        "sandboxError",
        "cyberPolicy",
        "other",
      ],
    );
  });
});

test("timestamp formatting accepts both seconds and milliseconds", async () => {
  await withSsrModules(async (load) => {
    const { formatAutoResumeTimestamp } = await load("/src/settings/autoResume.ts");
    assert.equal(formatAutoResumeTimestamp(null), "尚无");
    assert.equal(formatAutoResumeTimestamp(1_784_000_000), formatAutoResumeTimestamp(1_784_000_000_000));
  });
});
