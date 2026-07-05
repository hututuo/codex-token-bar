import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("live stream start failure creates a degraded warning snapshot", () => {
  return withSsrModules(async (load) => {
    const {
      LIVE_RATE_STREAM_WARNING_SOURCE,
      liveRateStreamFailureSnapshot,
    } = await load("/src/state/liveRateStreamFailure.ts");
    const result = {
      ok: false,
      fallback: false,
      error: "Command timed out after 2000ms",
    };
    const snapshot = liveRateStreamFailureSnapshot("thread-a", result);

    assert.equal(snapshot.threadTitle, "实时速率启动失败");
    assert.equal(snapshot.selectedThreadId, "thread-a");
    assert.equal(snapshot.selectedThreadTitle, "选中会话实时速率启动失败");
    assert.equal(snapshot.tokensPerSecond, 0);
    assert.deepEqual(snapshot.warnings, [
      {
        source: LIVE_RATE_STREAM_WARNING_SOURCE,
        message: "实时速率流启动失败：Command timed out after 2000ms。可点击重试重新连接。",
      },
    ]);
  });
});

test("failure message falls back to a stable retry prompt when no reason is present", () => {
  return withSsrModules(async (load) => {
    const { liveRateStreamFailureMessage } = await load("/src/state/liveRateStreamFailure.ts");

    assert.equal(
      liveRateStreamFailureMessage({ ok: false, fallback: false, error: "   " }),
      "实时速率流启动失败。可点击重试重新连接。",
    );
  });
});

test("disabled live rate remains a clean non-error state", () => {
  return withSsrModules(async (load) => {
    const { disabledLiveRateSnapshot } = await load("/src/state/dashboardDefaults.ts");
    const snapshot = disabledLiveRateSnapshot("thread-a");

    assert.equal(snapshot.threadTitle, "实时速率已关闭");
    assert.deepEqual(snapshot.warnings, []);
  });
});
