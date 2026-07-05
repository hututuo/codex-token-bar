import assert from "node:assert/strict";
import test from "node:test";

import { mergeQuotaDiagnostics } from "./dashboardWarnings.ts";

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
