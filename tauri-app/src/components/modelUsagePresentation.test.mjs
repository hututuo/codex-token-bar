import test from "node:test";
import assert from "node:assert/strict";
import {
  dominantModelColor,
  modelUsageCompactText,
  modelUsageLabel,
  modelUsageSlices,
  modelUsageKey,
} from "./modelUsagePresentation.ts";

test("model usage presentation combines aliases and reports token shares", () => {
  const rows = [
    row("gpt-5.6-sol", 600, 2),
    row("gpt_5.6_sol", 100, 1),
    row("gpt-5.6-luna", 300, 1),
  ];

  const slices = modelUsageSlices(rows);

  assert.deepEqual(slices.map(({ label, tokens }) => ({ label, tokens })), [
    { label: "Sol", tokens: 700 },
    { label: "Luna", tokens: 300 },
  ]);
  assert.equal(modelUsageCompactText(rows), "Sol 70% · Luna 30%");
  assert.equal(dominantModelColor(rows), "#2e6bfa");
});

test("unknown and custom models remain visible with stable colors", () => {
  const rows = [row(null, 25, 1), row("custom-model", 75, 1)];
  const first = modelUsageSlices(rows);
  const second = modelUsageSlices(rows);

  assert.deepEqual(first.map((slice) => slice.color), second.map((slice) => slice.color));
  assert.deepEqual(new Set(first.map((slice) => slice.label)), new Set(["未知模型", "custom-model"]));
});

test("bare GPT-5.6 remains an untyped model instead of becoming Sol", () => {
  const slices = modelUsageSlices([row("gpt-5.6", 100, 1)]);

  assert.deepEqual(slices.map((slice) => slice.label), ["gpt-5.6"]);
});

test("floating model labels use compact model names", () => {
  assert.equal(modelUsageLabel("gpt-6-astra"), "Astra");
  assert.equal(modelUsageLabel("gpt_6_astra"), "Astra");
  assert.equal(modelUsageLabel("gpt-5.2-codex"), "5.2");
  assert.equal(modelUsageLabel("gpt-5.4"), "5.4");
  assert.equal(modelUsageLabel("gpt-5.4-mini"), "5.4 m");
});

test("dashboard keeps auto review distinct from normal model usage", () => {
  const slices = modelUsageSlices([
    row("codex-auto-review", 600, 2),
    row("gpt-5.4", 100, 1),
    row("gpt-5.3-codex", 300, 1),
  ]);

  assert.deepEqual(slices.map(({ label, tokens }) => ({ label, tokens })), [
    { label: "Auto Review（Luna）", tokens: 600 },
    { label: "5.3", tokens: 300 },
    { label: "5.4", tokens: 100 },
  ]);
});

test("historical and current auto-review points remain separate by timestamp", () => {
  const slices = modelUsageSlices([
    row("codex-auto-review", 400, 1, Date.parse("2026-07-29T23:59:59Z") / 1000),
    row("codex-auto-review", 600, 1, Date.parse("2026-07-30T00:00:00Z") / 1000),
  ]);

  assert.deepEqual(slices.map(({ label, tokens }) => ({ label, tokens })), [
    { label: "Auto Review（Luna）", tokens: 600 },
    { label: "Auto Review（5.4）", tokens: 400 },
  ]);
});

test("future model names retain source spelling and never become Sol by prefix", () => {
  for (const model of ["gpt-5.6-newlane", "gpt-5.4-next", "GPT-7-Nova", "custom_Model_V2"]) {
    assert.equal(modelUsageKey(model), model);
    assert.equal(modelUsageLabel(model), model);
  }
});

test("explicit supported model aliases share a dashboard item", () => {
  const slices = modelUsageSlices([
    row("gpt56luna", 50, 1), row("gpt-5.6-luna", 100, 1),
    row("gpt5.6-sol", 30, 1), row("gpt-5.6-sol", 20, 1),
  ]);
  assert.deepEqual(slices.map(({ label, tokens }) => ({ label, tokens })), [
    { label: "Luna", tokens: 150 }, { label: "Sol", tokens: 50 },
  ]);
});

function row(model, totalTokens, calls, eventStartUnix) {
  return {
    model,
    eventStartUnix,
    breakdown: { inputTokens: totalTokens, cachedInputTokens: 0, outputTokens: 0, totalTokens, calls },
  };
}
