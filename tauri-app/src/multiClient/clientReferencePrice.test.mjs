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
    const checked = new Date("2026-11-08T02:00:00Z");
    for (const [model, expected] of [
      ["k3.1-pro", "$2.00 / $10.00"], ["k3.1-pro-highspeed", "$4.00 / $20.00"],
      ["mimo-v2.6-flash", "$0.14 / $0.28"], ["mimo-v2.6-pro", "$0.435 / $0.87"],
      ["mimo-v2.6-pro-ultraspeed", "$4.35 / $8.70"],
      ["gemini-4-argon", "$2.00 / $10.00"],
    ]) assert.equal(referencePrice(model, checked), expected, model);
    assert.equal(referencePrice("gemini-4-argon", new Date("2026-12-01T00:00:00Z")), "$4.00 / $20.00");
    assert.equal(referencePrice("kimi-for-coding", checked), "未计价");
    assert.equal(referencePrice("gpt-6.1-sol-ultrafast", checked), "未计价");
    assert.equal(referencePrice("deepseek-flash", new Date(NaN)), "未计价");
  });
});
