import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const currentDir = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(currentDir, "CodexRadarStrip.tsx"), "utf8");

test("Codex Radar header keeps the Swift-style source credit", () => {
  assert.match(source, /className="codex-radar-source-credit"/);
  assert.match(source, /感谢/);
  assert.match(source, /Codex 雷达/);
  assert.match(source, /codexradar\.com/);
});

test("Codex Radar detail card keeps the full human-readable feed breakdown", () => {
  for (const title of ["众测雷达", "速蹬窗口与预测", "降智雷达", "预估额度", "环境压力与资讯", "窗口摘要", "预测说明", "信号拆分", "模型对比", "近日日志", "套餐预估", "趋势明细", "RSS 提醒历史", "来源"]) {
    assert.match(source, new RegExp(`title="${title}"`));
  }

  for (const label of ["Codex 雷达详细信息", "codex-radar-detail-layer", "role=\"dialog\"", "RadarLineChart", "IQ 指数", "评测日期", "额度趋势", "codex-radar-window-selector", "窗口状态", "范围", "建议动作", "24h 概率", "通过", "状态", "费用", "耗时", "Tokens", "官方动态 24h", "社区提及 24h", "异常/限额反馈", "暂无 RSS 提醒历史", "feedItems", "感谢 Codex Radar 提供公开雷达数据"]) {
    assert.match(source, new RegExp(label));
  }
});

test("Codex Radar summary and detail share one crowd snapshot", () => {
  const overlayStart = source.indexOf("export function CodexRadarDetailOverlay");
  const overlaySource = source.slice(overlayStart);

  assert.match(source, /const \[crowdRadar, setCrowdRadar\] = useState<CodexCrowdRadarSnapshot \| null>\(null\)/);
  assert.match(source, /crowdRadar=\{crowdRadar\}/);
  assert.match(source, /crowdRadarStatus=\{crowdRadarStatus\}/);
  assert.match(source, /crowdRadarStatus\.startsWith\("众测刷新失败"\)/);
  assert.match(source, /codex-radar-stale-note/);
  assert.doesNotMatch(overlaySource, /readCodexCrowdRadarSnapshot\(/);
});
