import assert from "node:assert/strict";
import test from "node:test";
import { compactFloatingPaceLabel, compactResetCreditLabel } from "./compactPanelLabels.ts";

test("compactFloatingPaceLabel shortens quota jokes before the floating panel truncates them", () => {
  assert.equal(compactFloatingPaceLabel("余量很足，使劲蹬（多 12%）"), "余量足");
  assert.equal(compactFloatingPaceLabel("节奏很好，可以冲（多 3%）"), "节奏好");
  assert.equal(compactFloatingPaceLabel("略有余量（多 2%）"), "略有余量");
  assert.equal(compactFloatingPaceLabel("用得偏快，慢一点（低 8%）"), "慢一点");
  assert.equal(compactFloatingPaceLabel("用得太快，先省着"), "慢一点");
});

test("compactResetCreditLabel keeps a fixed short card count", () => {
  assert.equal(compactResetCreditLabel({ availableCount: 5, status: "5 张重置卡可用", credits: [] }), "5卡");
  assert.equal(compactResetCreditLabel({ availableCount: 0, status: "重置卡待读取", credits: [] }), "卡--");
  assert.equal(compactResetCreditLabel({ availableCount: 0, status: "0 张重置卡", credits: [] }), "0卡");
});
