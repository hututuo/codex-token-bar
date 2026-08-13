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

test("quotaReadWarnings ignores usage precision metadata-only warnings", () => {
  const warnings = [
    {
      source: "usage_precision",
      message: "精确 token 仍在读取，当前仅显示会话元数据，请稍后刷新。",
    },
  ];

  assert.deepEqual(quotaReadWarnings(warnings), []);
});

test("quotaReadWarnings prefers the primary cause and one combined cached-data status", () => {
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
    "额度刷新失败，暂时显示上次成功额度。",
  ]);
});

test("quotaReadWarnings collapses the observed timeout/network cascade into two useful lines", () => {
  const diagnostics = [
    diagnostic({
      source: "account_quota",
      category: "stale_cached_data",
      message: "额度刷新失败，暂时显示上次成功额度。请稍后点立即刷新重试。",
      staleDataDisplayed: true,
    }),
    diagnostic({
      source: "account_quota",
      category: "timeout",
      message: "读取超时：本地 Codex 或网络接口在限定时间内没有返回。",
      rawCause: "额度读取超时；error sending request for url",
    }),
    diagnostic({
      source: "reset_credit",
      category: "stale_cached_data",
      message: "重置卡刷新失败，暂时显示上次成功结果。",
      staleDataDisplayed: true,
    }),
    diagnostic({
      source: "reset_credit",
      category: "reset_credit_failure",
      message: "重置卡读取失败：网络连接失败",
      underlyingCategory: "network_send_fetch",
      rawCause: "error sending request for url",
    }),
  ];

  assert.deepEqual(quotaReadWarnings([], diagnostics), [
    "重置卡读取失败：网络连接失败",
    "额度和重置卡刷新失败，暂时显示上次成功结果。",
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
