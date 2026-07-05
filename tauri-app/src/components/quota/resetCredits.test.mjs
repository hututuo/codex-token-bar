import assert from "node:assert/strict";
import test from "node:test";
import {
  compactRemainingTimeText,
  detailedRemainingTimeText,
  nearestResetCreditCompactText,
  prepareResetCreditsForDisplay,
  remainingProgress,
  resetCreditCountText,
  resetCreditDetailKey,
  resetCreditPanelModel,
  resetCreditPanelSubtitle,
} from "./resetCredits.ts";

const now = new Date("2026-06-26T00:00:00Z");
const nowUnix = Math.floor(now.getTime() / 1000);

function credit(overrides = {}) {
  return {
    cardId: "card-a",
    title: "一次免费额度重置",
    status: "可用",
    summary: "",
    resetType: "codex_rate_limits",
    issuedAt: "2026-06-25 00:00",
    grantedAtUnix: nowUnix - 24 * 60 * 60,
    expiresAt: "2026-06-28 03:00",
    expiresAtUnix: nowUnix + 2 * 24 * 60 * 60 + 3 * 60 * 60,
    redeemStartedAt: "未提供",
    redeemedAt: "未使用",
    source: "invite",
    detailNote: "邀请获得",
    associatedUser: "user_1",
    profileImageUrl: "https://example.com/avatar.png",
    shortId: "card-a",
    ...overrides,
  };
}

test("reset credits sort available cards first by nearest expiry", () => {
  const sorted = prepareResetCreditsForDisplay(
    [
      credit({ cardId: "used", status: "已使用", expiresAtUnix: nowUnix + 60 }),
      credit({ cardId: "later", expiresAtUnix: nowUnix + 7 * 24 * 60 * 60 }),
      credit({ cardId: "soon", expiresAtUnix: nowUnix + 2 * 60 * 60 }),
      credit({ cardId: "expired", status: "已过期", expiresAtUnix: nowUnix - 60 }),
    ],
    now,
  );

  assert.deepEqual(sorted.map((item) => item.credit.cardId), ["soon", "later", "expired", "used"]);
  assert.equal(sorted[0].isAvailable, true);
  assert.equal(sorted[2].isAvailable, false);
});

test("reset credit remaining time has compact and detailed variants", () => {
  const days = credit({ expiresAtUnix: nowUnix + 2 * 24 * 60 * 60 + 3 * 60 * 60 });
  const hours = credit({ expiresAtUnix: nowUnix + 4 * 60 * 60 + 20 * 60 });
  const soon = credit({ expiresAtUnix: nowUnix + 30 * 60 });
  const expired = credit({ expiresAtUnix: nowUnix - 1 });

  assert.equal(compactRemainingTimeText(days, now), "剩 2天3h");
  assert.equal(detailedRemainingTimeText(days, now), "约 2 天 3 小时后到期");
  assert.equal(compactRemainingTimeText(hours, now), "剩 4h20m");
  assert.equal(compactRemainingTimeText(soon, now), "剩 <1h");
  assert.equal(compactRemainingTimeText(expired, now), "已到期");
});

test("reset credit progress uses granted and expiry window with safe fallbacks", () => {
  assert.equal(
    remainingProgress(
      credit({
        grantedAtUnix: nowUnix - 24 * 60 * 60,
        expiresAtUnix: nowUnix + 24 * 60 * 60,
      }),
      now,
    ),
    0.5,
  );
  assert.equal(remainingProgress(credit({ grantedAtUnix: null, expiresAtUnix: null }), now), 1);
  assert.equal(remainingProgress(credit({ status: "已使用", grantedAtUnix: null, expiresAtUnix: null }), now), 0);
});

test("reset credit summary keeps count and exposes nearest remaining time", () => {
  const summary = {
    availableCount: 2,
    status: "2 张重置卡可用",
    credits: [
      credit({ cardId: "later", expiresAtUnix: nowUnix + 3 * 24 * 60 * 60 }),
      credit({ cardId: "nearest", expiresAtUnix: nowUnix + 4 * 60 * 60 + 20 * 60 }),
    ],
  };
  const displayItems = prepareResetCreditsForDisplay(summary.credits, now);

  assert.equal(resetCreditCountText(summary), "2 张重置卡");
  assert.equal(nearestResetCreditCompactText(summary, now), "最近 剩 4h20m");
  assert.equal(resetCreditPanelSubtitle(summary, displayItems), "共 2 张；可用 2 张 · 按最近到期排序");
});

test("reset credit summary falls back to available details when reported count is stale", () => {
  const summary = {
    availableCount: 0,
    status: "重置卡详情可用",
    credits: [
      credit({ cardId: "available", expiresAtUnix: nowUnix + 4 * 60 * 60 }),
      credit({ cardId: "used", redeemedAt: "2026-06-25 20:00", expiresAtUnix: nowUnix + 6 * 60 * 60 }),
      credit({ cardId: "expired", status: "已过期", expiresAtUnix: nowUnix - 60 }),
    ],
  };
  const displayItems = prepareResetCreditsForDisplay(summary.credits, now);

  assert.equal(resetCreditCountText(summary, now), "1 张重置卡");
  assert.equal(resetCreditPanelSubtitle(summary, displayItems), "共 3 张；可用 1 张 · 按最近到期排序");
});

test("reset credit panel model keeps summary count nearest detail and subtitle consistent", () => {
  const summary = {
    availableCount: 0,
    status: "重置卡详情可用",
    credits: [
      credit({ cardId: "available", expiresAtUnix: nowUnix + 4 * 60 * 60 }),
      credit({ cardId: "used", redeemedAt: "2026-06-25 20:00", expiresAtUnix: nowUnix + 6 * 60 * 60 }),
      credit({ cardId: "expired", status: "已过期", expiresAtUnix: nowUnix - 60 }),
    ],
  };

  const model = resetCreditPanelModel(summary, now);

  assert.equal(model.countText, "1 张重置卡");
  assert.equal(model.availableText, "1 张可用");
  assert.equal(model.nearestText, "最近 剩 4h0m");
  assert.equal(model.subtitle, "共 3 张；可用 1 张 · 按最近到期排序");
  assert.equal(model.emptyText.includes("卡--"), false);
  assert.deepEqual(model.displayItems.map((item) => item.credit.cardId), ["available", "expired", "used"]);
});

test("reset credit panel model does not leak entity details for empty failed or used-only states", () => {
  const expired = credit({ status: "已过期", expiresAtUnix: nowUnix - 60 });
  const used = credit({ redeemedAt: "2026-06-25 20:00", expiresAtUnix: nowUnix + 6 * 60 * 60 });

  for (const summary of [
    { availableCount: 0, status: "重置卡待读取", credits: [] },
    { availableCount: 0, status: "获取失败", credits: [] },
    { availableCount: 0, status: "0 张重置卡", credits: [expired, used] },
  ]) {
    const model = resetCreditPanelModel(summary, now);

    assert.equal(model.availableText, "0 张可用");
    assert.equal(model.nearestText, null);
    assert.equal(model.countText.includes("卡--"), false);
    assert.equal(model.emptyText.includes("卡--"), false);
  }
});

test("reset credit panel model counts status-available expired details without nearest expiry", () => {
  const summary = {
    availableCount: 0,
    status: "重置卡详情可用",
    credits: [
      credit({ cardId: "available-expired", expiresAtUnix: nowUnix - 60 }),
    ],
  };

  const model = resetCreditPanelModel(summary, now);

  assert.equal(model.countText, "1 张重置卡");
  assert.equal(model.availableText, "1 张可用");
  assert.equal(model.nearestText, null);
  assert.equal(model.subtitle, "共 1 张；可用 1 张 · 按最近到期排序");
  assert.equal(model.displayItems[0].compactRemainingText, "已到期");
});

test("reset credit panel model counts available unknown-expiry details without fake nearest expiry", () => {
  const summary = {
    availableCount: 0,
    status: "重置卡详情可用",
    credits: [
      credit({ cardId: "available-unknown", expiresAtUnix: null }),
    ],
  };

  const model = resetCreditPanelModel(summary, now);

  assert.equal(model.countText, "1 张重置卡");
  assert.equal(model.availableText, "1 张可用");
  assert.equal(model.nearestText, null);
  assert.equal(model.subtitle, "共 1 张；可用 1 张 · 按最近到期排序");
  assert.equal(model.displayItems[0].compactRemainingText, "到期未知");
});

test("reset credit detail keys use card identifiers with index fallback", () => {
  assert.equal(resetCreditDetailKey(credit({ cardId: "card-main", shortId: "short" }), 2), "card-main-2");
  assert.equal(resetCreditDetailKey(credit({ cardId: "", shortId: "short-only" }), 0), "short-only-0");
  assert.equal(resetCreditDetailKey(credit({ cardId: "", shortId: "" }), 1), "未提供-1");
});
