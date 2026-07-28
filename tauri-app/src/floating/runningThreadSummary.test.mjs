import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("floating running thread labels expose total, main, and child counts", async () => {
  await withSsrModules(async (load) => {
    const { floatingRunningThreadLabels } = await load("/src/floating/FloatingPanelPreview.tsx");
    assert.deepEqual(floatingRunningThreadLabels({
      total: 7,
      mainThreads: 3,
      subagents: 4,
      status: "ready",
      updatedAt: 1,
      detail: "ready",
      livenessLeaseHours: 24,
    }), ["总 7", "主 3", "子 4"]);
  });
});

test("loading and unavailable running summaries never render fake zero", async () => {
  await withSsrModules(async (load) => {
    const { floatingRunningThreadLabels } = await load("/src/floating/FloatingPanelPreview.tsx");
    const loading = floatingRunningThreadLabels({
      total: null,
      mainThreads: null,
      subagents: null,
      status: "scanning",
      updatedAt: null,
      detail: "loading",
      livenessLeaseHours: 24,
    });
    const unavailable = floatingRunningThreadLabels({
      total: null,
      mainThreads: null,
      subagents: null,
      status: "unavailable",
      updatedAt: null,
      detail: "failed",
      livenessLeaseHours: 24,
    });

    assert.deepEqual(loading, ["运行线程读取中…"]);
    assert.deepEqual(unavailable, ["运行线程暂不可用"]);
    assert.doesNotMatch([...loading, ...unavailable].join(" "), /\b0\b/);
  });
});

test("stale summary retains last-good values and labels them as previous", async () => {
  await withSsrModules(async (load) => {
    const { floatingRunningThreadLabels } = await load("/src/floating/FloatingPanelPreview.tsx");
    assert.deepEqual(floatingRunningThreadLabels({
      total: 2,
      mainThreads: 1,
      subagents: 1,
      status: "stale",
      updatedAt: 1,
      detail: "stale",
      livenessLeaseHours: 24,
    }), ["上次总 2", "主 1", "子 1"]);
  });
});
