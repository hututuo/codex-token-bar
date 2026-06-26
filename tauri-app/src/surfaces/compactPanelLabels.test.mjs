import assert from "node:assert/strict";
import test from "node:test";
import { compactFloatingPaceLabel, compactFloatingUsageStatus, compactResetCreditLabel } from "./compactPanelLabels.ts";

test("compactFloatingPaceLabel mirrors the Swift floating compact status", () => {
  assert.equal(compactFloatingPaceLabel("余量很足，使劲蹬（多 12%）"), "余量足(余量高 12%)");
  assert.equal(compactFloatingPaceLabel("节奏很好，可以冲（多 3%）"), "节奏稳(余量高 3%)");
  assert.equal(compactFloatingPaceLabel("略有余量（多 2%）"), "节奏稳(余量高 2%)");
  assert.equal(compactFloatingPaceLabel("用得偏快，慢一点（低 8%）"), "慢一点(余量低 8%)");
  assert.equal(compactFloatingPaceLabel("用得太快，先省着（低 22%）"), "先省着(余量低 22%)");
  assert.equal(compactFloatingPaceLabel("额度掉太快，先刹一脚（余量低 36%）"), "刹一脚(余量低 36%)");
});

test("compactResetCreditLabel appends only available reset credits like Swift", () => {
  assert.equal(compactResetCreditLabel({ availableCount: 5, status: "5 张重置卡可用", credits: [] }), " · 5卡");
  assert.equal(compactResetCreditLabel({ availableCount: 0, status: "重置卡待读取", credits: [] }), "");
  assert.equal(compactResetCreditLabel({ availableCount: 0, status: "0 张重置卡", credits: [] }), "");
});

test("compactFloatingUsageStatus keeps pace and reset card count in one line", () => {
  assert.equal(
    compactFloatingUsageStatus("用得偏快，慢一点（低 8%）", { availableCount: 5, status: "5 张重置卡可用", credits: [] }),
    "慢一点(余量低 8%) · 5卡",
  );
  assert.equal(
    compactFloatingUsageStatus("用得偏快，慢一点（低 8%）", { availableCount: 0, status: "0 张重置卡", credits: [] }),
    "慢一点(余量低 8%)",
  );
});
