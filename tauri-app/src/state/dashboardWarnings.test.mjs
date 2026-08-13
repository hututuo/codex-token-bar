import assert from "node:assert/strict";
import test from "node:test";

import {
  hasStaleAccountQuotaData,
  mergeQuotaDiagnostics,
  replaceAccountQuotaDiagnostics,
  replaceResetCreditDiagnostics,
} from "./dashboardWarnings.ts";

test("mergeQuotaDiagnostics dedupes structured quota diagnostics without hiding categories", () => {
  const authMissing = diagnostic({
    source: "account_quota",
    category: "auth_missing",
    message: "登录凭证缺失",
    rawCause: "未找到 access token",
    retryable: false,
  });
  const resetFailure = diagnostic({
    source: "reset_credit",
    category: "reset_credit_failure",
    message: "重置卡读取失败：网络连接失败",
    rawCause: "error sending request for url",
    underlyingCategory: "network_send_fetch",
  });

  assert.deepEqual(
    mergeQuotaDiagnostics([authMissing], [authMissing, resetFailure]).map((item) => item.category),
    ["auth_missing", "reset_credit_failure"],
  );
});

test("channel replacement cannot clear or inject the other quota channel", () => {
  const account = diagnostic({ source: "account_quota", message: "主额度失败" });
  const reset = diagnostic({ source: "reset_credit", message: "重置卡失败" });
  const incomingReset = diagnostic({ source: "reset_credit", message: "不应由主额度写入" });

  assert.deepEqual(
    replaceAccountQuotaDiagnostics([account, reset], [incomingReset]).map((item) => item.message),
    ["重置卡失败"],
  );
  assert.deepEqual(
    replaceResetCreditDiagnostics([account, reset], []).map((item) => item.message),
    ["主额度失败"],
  );
});

test("reset-credit stale data never marks the main account quota stale", () => {
  assert.equal(hasStaleAccountQuotaData([diagnostic({
    source: "reset_credit",
    category: "stale_cached_data",
    staleDataDisplayed: true,
  })]), false);
  assert.equal(hasStaleAccountQuotaData([diagnostic({
    source: "account_quota",
    category: "stale_cached_data",
    staleDataDisplayed: true,
  })]), true);
});

function diagnostic(overrides = {}) {
  return {
    source: "account_quota",
    category: "unknown",
    severity: "warning",
    message: "未知诊断",
    rawCause: "raw",
    underlyingCategory: null,
    attempts: null,
    httpStatus: null,
    retryable: true,
    occurredAt: "2026-07-06T00:00:00Z",
    staleDataDisplayed: false,
    ...overrides,
  };
}
