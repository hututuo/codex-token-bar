import assert from "node:assert/strict";
import test from "node:test";
import {
  compactFloatingPaceLabel,
  compactFloatingUsageStatus,
  compactResetCreditCountSuffix,
  compactResetCreditRateBarSuffix,
  compactResetCreditStandaloneSuffix,
} from "./compactPanelLabels.ts";

test("compactFloatingPaceLabel mirrors the Swift floating compact status", () => {
  assert.equal(compactFloatingPaceLabel("余量很足，使劲蹬（多 12%）"), "余量足(余量高12%)");
  assert.equal(compactFloatingPaceLabel("节奏很好，可以冲（多 3%）"), "节奏稳(余量高3%)");
  assert.equal(compactFloatingPaceLabel("略有余量（多 2%）"), "节奏稳(余量高2%)");
  assert.equal(compactFloatingPaceLabel("正好贴着均速线"), "节奏稳（正好贴线）");
  assert.equal(compactFloatingPaceLabel("用得偏快，慢一点（低 8%）"), "慢一点(余量低8%)");
  assert.equal(compactFloatingPaceLabel("用得太快，先省着（低 22%）"), "先省着(余量低22%)");
  assert.equal(compactFloatingPaceLabel("额度掉太快，先刹一脚（余量低 36%）"), "刹一脚(余量低36%)");
});

test("compact reset credit count suffix appends only available reset credits like Swift", () => {
  assert.equal(compactResetCreditCountSuffix({ availableCount: 5, status: "5 张重置卡可用", credits: [] }), " · 5卡");
  assert.equal(
    compactResetCreditCountSuffix({
      availableCount: 0,
      status: "重置卡详情可用",
      credits: [resetCredit({ expiresAtUnix: Date.parse("2026-06-28T09:00:00Z") / 1000 })],
    }, new Date("2026-06-26T10:00:00Z")),
    " · 1卡",
  );
  assert.equal(
    compactResetCreditCountSuffix({
      availableCount: 0,
      status: "重置卡详情可用",
      credits: [resetCredit({ expiresAtUnix: null })],
    }, new Date("2026-06-26T10:00:00Z")),
    " · 1卡",
  );
  assert.equal(
    compactResetCreditCountSuffix({
      availableCount: 0,
      status: "重置卡详情可用",
      credits: [resetCredit({ expiresAtUnix: Date.parse("2026-06-26T09:00:00Z") / 1000 })],
    }, new Date("2026-06-26T10:00:00Z")),
    " · 1卡",
  );
  assert.equal(compactResetCreditCountSuffix({ availableCount: 0, status: "重置卡待读取", credits: [] }), "");
  assert.equal(compactResetCreditCountSuffix({ availableCount: 0, status: "0 张重置卡", credits: [] }), "");
});

test("compactFloatingUsageStatus keeps pace and standalone reset card suffix in one line", () => {
  const now = new Date("2026-06-26T10:00:00Z");
  assert.equal(
    compactFloatingUsageStatus("用得偏快，慢一点（低 8%）", {
      availableCount: 5,
      status: "5 张重置卡可用",
      credits: [resetCredit({ expiresAtUnix: Date.parse("2026-06-28T09:00:00Z") / 1000 })],
    }, now),
    "慢一点(余量低8%) · 5卡 · 近2天到期",
  );
  assert.equal(
    compactFloatingUsageStatus("用得偏快，慢一点（低 8%）", { availableCount: 0, status: "0 张重置卡", credits: [] }),
    "慢一点(余量低8%)",
  );
});

function resetCredit(overrides) {
  return {
    cardId: "card",
    title: "",
    status: "可用",
    summary: "",
    resetType: "",
    issuedAt: "",
    grantedAtUnix: null,
    expiresAt: "",
    expiresAtUnix: null,
    redeemStartedAt: "",
    redeemedAt: "未使用",
    source: "",
    detailNote: "",
    associatedUser: "",
    profileImageUrl: "",
    shortId: "",
    ...overrides,
  };
}

test("compact reset credit suffixes describe the nearest available card expiry", () => {
  const now = new Date("2026-06-26T10:00:00Z");
  const day = 24 * 60 * 60;

  assert.equal(
    compactResetCreditRateBarSuffix({
      availableCount: 2,
      status: "2 张重置卡可用",
      credits: [
        resetCredit({ cardId: "late", expiresAtUnix: Date.parse("2026-06-30T10:00:00Z") / 1000 }),
        resetCredit({ cardId: "soon", expiresAtUnix: Date.parse("2026-06-28T09:00:00Z") / 1000 }),
      ],
    }, now),
    " · 2卡 · 2天",
  );

  assert.equal(
    compactResetCreditRateBarSuffix({
      availableCount: 1,
      status: "1 张重置卡可用",
      credits: [
        resetCredit({ expiresAtUnix: Date.parse("2026-06-26T15:10:00Z") / 1000 }),
      ],
    }, now),
    " · 1卡 · 6h",
  );

  assert.equal(
    compactResetCreditStandaloneSuffix({
      availableCount: 1,
      status: "1 张重置卡可用",
      credits: [
        resetCredit({ expiresAtUnix: Date.parse("2026-06-26T10:45:00Z") / 1000 }),
      ],
    }, now),
    " · 1卡 · 近45m到期",
  );

  assert.equal(
    compactResetCreditRateBarSuffix({
      availableCount: 1,
      status: "1 张重置卡可用",
      credits: [
        resetCredit({ status: "已使用", expiresAtUnix: Math.floor(now.getTime() / 1000) + day }),
      ],
    }, now),
    " · 1卡",
  );

  assert.equal(
    compactResetCreditRateBarSuffix({
      availableCount: 0,
      status: "重置卡详情可用",
      credits: [
        resetCredit({ expiresAtUnix: Date.parse("2026-06-26T15:10:00Z") / 1000 }),
      ],
    }, now),
    " · 1卡 · 6h",
  );

  assert.equal(
    compactResetCreditRateBarSuffix({
      availableCount: 0,
      status: "重置卡详情可用",
      credits: [resetCredit({ expiresAtUnix: null })],
    }, now),
    " · 1卡",
  );

  assert.equal(
    compactResetCreditRateBarSuffix({
      availableCount: 0,
      status: "重置卡详情可用",
      credits: [resetCredit({ expiresAtUnix: Date.parse("2026-06-26T09:00:00Z") / 1000 })],
    }, now),
    " · 1卡",
  );

  assert.equal(
    compactResetCreditStandaloneSuffix({
      availableCount: 0,
      status: "重置卡详情可用",
      credits: [resetCredit({ expiresAtUnix: Date.parse("2026-06-26T09:00:00Z") / 1000 })],
    }, now),
    " · 1卡",
  );
});

test("compact reset credit suffixes do not invent expiry details for empty failed or expired states", () => {
  const now = new Date("2026-06-26T10:00:00Z");
  const expired = resetCredit({ status: "已过期", expiresAtUnix: Date.parse("2026-06-26T09:00:00Z") / 1000 });
  const used = resetCredit({ redeemedAt: "2026-06-26T09:00:00Z", expiresAtUnix: Date.parse("2026-06-27T10:00:00Z") / 1000 });

  for (const summary of [
    { availableCount: 0, status: "重置卡待读取", credits: [] },
    { availableCount: 0, status: "获取失败", credits: [] },
    { availableCount: 0, status: "0 张重置卡", credits: [expired, used] },
  ]) {
    assert.equal(compactResetCreditRateBarSuffix(summary, now), "");
    assert.equal(compactResetCreditStandaloneSuffix(summary, now), "");
  }
});
