import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const currentDir = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(currentDir, "CodexRadarStrip.tsx"), "utf8");

test("Codex Radar detail card keeps the full human-readable feed breakdown", () => {
  for (const title of ["速蹬窗口与预测", "降智雷达", "预估额度", "环境压力与资讯", "窗口摘要", "预测说明", "信号拆分", "模型对比", "近日日志", "套餐预估", "趋势明细", "来源"]) {
    assert.match(source, new RegExp(`title="${title}"`));
  }

  for (const label of ["Codex 雷达详细信息", "codex-radar-detail-layer", "role=\"dialog\"", "RadarLineChart", "IQ 指数", "评测日期", "额度趋势", "codex-radar-window-selector", "窗口状态", "范围", "建议动作", "24h 概率", "有效", "无效", "官方动态 24h", "社区提及 24h", "异常/限额反馈", "感谢 Codex Radar 提供公开雷达数据"]) {
    assert.match(source, new RegExp(label));
  }
});
