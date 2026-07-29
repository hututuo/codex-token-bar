import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("auto resume client uses the exact native command contract", async () => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const calls = [];
  const settings = {
    enabled: false,
    threadId: "thread-a",
    threadTitle: "Thread A",
    threadCwd: "/tmp/a",
    prompt: "继续",
    scheduleMode: "off",
    intervalMinutes: 60,
    dailyHour: 9,
    dailyMinute: 0,
    quotaResumeEnabled: true,
    quotaWindow: "either",
    quotaLowThresholdPercent: 5,
    quotaRecoveryThresholdPercent: 20,
    cooldownMinutes: 30,
    maxRunsPerDay: 6,
    notifyOnResult: true,
  };
  const status = {
    state: "ready",
    message: "已就绪",
    isRunning: false,
    waitingForQuota: false,
    lastTrigger: null,
    lastRunAt: null,
    nextScheduledAt: null,
    runsToday: 0,
    revision: 1,
  };
  const responses = {
    save_auto_resume_settings: { autoResume: settings },
    list_auto_resume_threads: [{ id: "thread-a" }],
    read_auto_resume_status: status,
    run_auto_resume_now: { ...status, state: "running", isRunning: true, revision: 2 },
    cancel_auto_resume_run: { ...status, state: "ready", revision: 3 },
    save_session_enhancement_settings: { sessionEnhancements: { markdownExport: true } },
  };

  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      __TAURI_INTERNALS__: {
        invoke(command, args) {
          calls.push({ command, args });
          return Promise.resolve(responses[command]);
        },
      },
      clearTimeout: globalThis.clearTimeout.bind(globalThis),
      setTimeout: globalThis.setTimeout.bind(globalThis),
    },
    writable: true,
  });

  try {
    await withSsrModules(async (load) => {
      const {
        cancelAutoResumeRun,
        listAutoResumeThreads,
        readAutoResumeStatus,
        runAutoResumeNow,
        saveAutoResumeSettings,
        saveSessionEnhancementSettings,
      } = await load("/src/api/settingsClient.ts");
      await saveAutoResumeSettings(settings);
      await listAutoResumeThreads();
      await readAutoResumeStatus();
      await runAutoResumeNow("task-a");
      await cancelAutoResumeRun();
      await saveSessionEnhancementSettings({ markdownExport: true });
    });

    assert.deepEqual(calls, [
      { command: "save_auto_resume_settings", args: { settings } },
      { command: "list_auto_resume_threads", args: {} },
      { command: "read_auto_resume_status", args: {} },
      { command: "run_auto_resume_now", args: { taskId: "task-a" } },
      { command: "cancel_auto_resume_run", args: {} },
      { command: "save_session_enhancement_settings", args: { settings: { markdownExport: true } } },
    ]);
  } finally {
    if (previousWindow) Object.defineProperty(globalThis, "window", previousWindow);
    else delete globalThis.window;
  }
});
