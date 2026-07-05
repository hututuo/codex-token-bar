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
