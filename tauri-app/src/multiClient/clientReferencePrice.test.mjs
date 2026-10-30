import assert from "node:assert/strict";
import test from "node:test";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("reference prices use the shared asset including actual UTC periods, holidays and explicit fast prices", async () => {
  await withSsrModules(async (load) => {
    const { referencePrice } = await load("/src/multiClient/clientReferencePrice.ts");
    for (const [time, expected] of [
      ["2026-10-30T01:00:00Z", "$0.30 / $1.20"],
      ["2026-10-30T04:00:00Z", "$0.15 / $0.60"],
      ["2026-10-31T02:00:00Z", "$0.15 / $0.60"],
      ["2026-10-01T02:00:00Z", "$0.15 / $0.60"],
      ["2026-08-10T02:00:00Z", "$0.14 / $0.28"],
      ["2026-08-17T02:00:00Z", "$0.44 / $1.32"],
    ]) assert.equal(referencePrice("deepseek/deepseek-v4-flash", new Date(time)), expected, time);
    assert.equal(referencePrice("claude-opus-5-5"), "$4.00 / $20.00");
    assert.equal(referencePrice("claude-opus-5-5-fast"), "$8.00 / $40.00");
    assert.equal(referencePrice("claude-fable-5-1"), "$10.00 / $50.00");
    assert.equal(referencePrice("made-up-model"), "未计价");
    assert.equal(referencePrice("deepseek-flash", new Date(NaN)), "未计价");
  });
});
