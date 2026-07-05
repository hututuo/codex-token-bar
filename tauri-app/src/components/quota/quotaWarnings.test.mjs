import assert from "node:assert/strict";
import test from "node:test";
import { quotaReadWarnings } from "./quotaWarnings.ts";

test("quotaReadWarnings filters quota sources dedupes messages and caps visible reasons", () => {
  const warnings = [
    { source: "usage_cache", message: "缓存还在初始化" },
    { source: "account_quota", message: "账户额度读取失败" },
    { source: "reset_credit", message: "重置卡读取失败" },
    { source: "account_quota", message: "账户额度读取失败" },
    { source: "reset_credit", message: "重置卡备用失败" },
  ];

  assert.deepEqual(quotaReadWarnings(warnings), ["账户额度读取失败", "重置卡读取失败"]);
});

test("quotaReadWarnings ignores empty messages and keeps order", () => {
  const warnings = [
    { source: "account_quota", message: "" },
    { source: "reset_credit", message: "重置卡失败" },
    { source: "account_quota", message: "账户额度失败" },
  ];

  assert.deepEqual(quotaReadWarnings(warnings), ["重置卡失败", "账户额度失败"]);
});

test("quotaReadWarnings prefers structured diagnostics and keeps all quota categories visible", () => {
  const warnings = [
    { source: "account_quota", message: "旧账户额度读取失败" },
    { source: "reset_credit", message: "旧重置卡读取失败" },
  ];
  const diagnostics = [
    diagnostic({
      source: "reset_credit",
      category: "reset_credit_failure",
      message: "重置卡读取失败：网络连接失败",
      rawCause: "error sending request for url",
      underlyingCategory: "network_send_fetch",
      retryable: true,
    }),
    diagnostic({
      source: "source_integrity",
      category: "source_mismatch",
      message: "Codex Home 与额度登录来源不一致",
      rawCause: "/tmp/source-a != /tmp/source-b",
      retryable: false,
    }),
    diagnostic({
      source: "account_quota",
      category: "auth_missing",
      message: "登录凭证缺失",
      rawCause: "未找到 access token",
      retryable: false,
    }),
    diagnostic({
      source: "frontend_command",
      category: "stale_cached_data",
      message: "正在显示上次缓存的额度",
      rawCause: "quota cache older than source",
      retryable: true,
      staleDataDisplayed: true,
    }),
  ];

  assert.deepEqual(quotaReadWarnings(warnings, diagnostics), [
    "登录凭证缺失",
    "Codex Home 与额度登录来源不一致",
    "正在显示上次缓存的额度",
    "重置卡读取失败：网络连接失败",
  ]);
});

function diagnostic(overrides) {
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
