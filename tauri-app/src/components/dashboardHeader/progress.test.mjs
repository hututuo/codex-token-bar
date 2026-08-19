import assert from "node:assert/strict";
import test from "node:test";

import {
  PRECISE_PROGRESS_REASSURANCE,
  dashboardHeaderProgressStage,
  presentDashboardHeaderProgress,
} from "./progress.ts";

function progress(overrides = {}) {
  return {
    phase: "idle",
    message: "等待精确统计",
    completed: 0,
    total: null,
    fraction: null,
    startedAt: "2026-08-19T08:00:00.000Z",
    updatedAt: "2026-08-19T08:00:00.000Z",
    ...overrides,
  };
}

test("header progress keeps structure upgrade and exact counts visible", () => {
  const value = presentDashboardHeaderProgress(progress({
    phase: "migrating",
    message: "正在升级索引字段",
    completed: 2,
    total: 4,
    fraction: 0.5,
  }));

  assert.equal(value?.stage, "structureUpgrade");
  assert.equal(value?.countLabel, "2/4");
  assert.equal(value?.fraction, 0.5);
  assert.equal(value?.showsProgress, true);
  assert.equal(value?.showsReassurance, true);
  assert.match(value?.text ?? "", /正在升级索引字段/);
});

test("Tauri model and reasoning details map to historical model backfill", () => {
  assert.equal(dashboardHeaderProgressStage(progress({
    phase: "migrating",
    message: "正在回填归因账本",
  })), "structureUpgrade");
  assert.equal(dashboardHeaderProgressStage(progress({
    phase: "migrating",
    message: "backfill historical model metadata",
  })), "historyModelBackfill");
  assert.equal(dashboardHeaderProgressStage(progress({
    phase: "scanning",
    message: "补齐 reasoning 字段",
  })), "historyModelBackfill");
  assert.equal(dashboardHeaderProgressStage(progress({
    phase: "backfillingModel",
    message: "正在补齐历史模型",
  })), "historyModelBackfill");
  assert.equal(dashboardHeaderProgressStage(progress({
    phase: "scanning",
    message: "正在扫描精确历史",
  })), "scanning");
  assert.doesNotMatch(
    presentDashboardHeaderProgress(progress({
      phase: "scanning",
      message: "正在扫描精确历史",
    }))?.text ?? "",
    /索引升级|历史模型补全/
  );
});

test("single-file reconciliation and waiting remain distinct from migration", () => {
  assert.equal(dashboardHeaderProgressStage(progress({
    phase: "waiting",
    message: "等待其他精确统计实例完成",
  })), "waiting");
  assert.equal(dashboardHeaderProgressStage(progress({
    phase: "waiting",
    message: "等待单文件 reconciliation",
  })), "reconciliation");
  assert.equal(dashboardHeaderProgressStage(progress({
    phase: "scanning",
    message: "正在对账单文件",
  })), "reconciliation");
});

test("publishing exposes a determinate bar and completion is the only ready state", () => {
  const publishing = presentDashboardHeaderProgress(progress({
    phase: "publishing",
    message: "正在发布精确统计结果",
    completed: 1,
    total: 2,
    fraction: 0.5,
  }));
  assert.equal(publishing?.stage, "publishing");
  assert.equal(publishing?.countLabel, "1/2");
  assert.equal(publishing?.showsProgress, true);

  const idle = presentDashboardHeaderProgress(progress());
  assert.equal(idle?.isVisible, false);
  assert.notEqual(idle?.text, "已就绪");

  const complete = presentDashboardHeaderProgress(progress({
    phase: "complete",
    message: "精确统计已更新",
    completed: 1,
    total: 1,
    fraction: 1,
  }));
  assert.equal(complete?.text, "已就绪");
  assert.equal(complete?.isVisible, true);
  assert.equal(complete?.showsProgress, false);
  assert.equal(complete?.showsReassurance, false);
  assert.equal(complete?.isReady, true);
});

test("failed progress stays explicit and retains the backend count", () => {
  const failed = presentDashboardHeaderProgress(progress({
    phase: "failed",
    message: "保留上次可信数据",
    completed: 1,
    total: 4,
  }));
  assert.equal(failed?.stage, "failed");
  assert.match(failed?.text ?? "", /失败/);
  assert.equal(failed?.countLabel, "1/4");
  assert.equal(failed?.needsAttention, true);
  assert.equal(failed?.showsProgress, false);
  assert.equal(failed?.showsReassurance, true);
  assert.equal(failed?.isReady, false);
  assert.equal(
    PRECISE_PROGRESS_REASSURANCE,
    "首次升级可能需要几分钟，可能短暂占用 CPU 和磁盘，原始数据不会丢失",
  );
});
